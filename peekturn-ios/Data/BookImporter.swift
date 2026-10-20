import Foundation
import UniformTypeIdentifiers
import zlib

private let maxUncompressedZIPEntrySize = 64 * 1024 * 1024

enum BookImportError: LocalizedError, Equatable {
    case unsupportedFileType
    case sourceUnavailable
    case invalidEPUB
    case invalidEPUBMetadata

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Please choose an EPUB file."
        case .sourceUnavailable:
            return "The selected EPUB could not be read."
        case .invalidEPUB:
            return "The selected file is not a valid EPUB."
        case .invalidEPUBMetadata:
            return "The EPUB metadata could not be read."
        }
    }
}

final class BookImporter {
    static let supportedContentType = UTType(filenameExtension: "epub") ?? .data

    let storageDirectory: URL

    private let fileManager: FileManager

    init(storageDirectory: URL, fileManager: FileManager = .default) {
        self.storageDirectory = storageDirectory
        self.fileManager = fileManager
    }

    func importBook(from sourceURL: URL) throws -> Book {
        let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard sourceURL.isFileURL,
              fileManager.fileExists(atPath: sourceURL.path),
              !isDirectory(sourceURL) else {
            throw BookImportError.sourceUnavailable
        }

        guard sourceURL.pathExtension.caseInsensitiveCompare("epub") == .orderedSame else {
            throw BookImportError.unsupportedFileType
        }

        try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        let bookID = UUID()
        let finalFileName = "\(bookID.uuidString).epub"
        let finalURL = storageDirectory.appendingPathComponent(finalFileName, isDirectory: false)
        let temporaryURL = storageDirectory.appendingPathComponent(".import-\(bookID.uuidString).tmp", isDirectory: false)

        do {
            try fileManager.copyItem(at: sourceURL, to: temporaryURL)
            let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent
            let metadata = try EPUBMetadataReader(fileManager: fileManager).read(
                from: temporaryURL,
                fallbackTitle: fallbackTitle
            )
            try fileManager.moveItem(at: temporaryURL, to: finalURL)

            return Book(
                id: bookID,
                title: metadata.title,
                author: metadata.author,
                epubFileName: finalFileName
            )
        } catch {
            removeIfPresent(temporaryURL)
            removeIfPresent(finalURL)
            throw normalizedImportError(for: error)
        }
    }

    func removeImportedFile(for book: Book) throws {
        guard !book.epubFileName.isEmpty else { return }
        guard isSinglePathComponent(book.epubFileName) else {
            throw BookRepositoryError.invalidBookFileName
        }
        let fileURL = storageDirectory.appendingPathComponent(book.epubFileName, isDirectory: false)
        guard fileURL.deletingLastPathComponent().standardizedFileURL == storageDirectory.standardizedFileURL else {
            throw BookRepositoryError.invalidBookFileName
        }
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }

    private func isSinglePathComponent(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\") else {
            return false
        }
        return URL(fileURLWithPath: fileName).lastPathComponent == fileName
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func normalizedImportError(for error: Error) -> Error {
        if let importError = error as? BookImportError {
            return importError
        }
        if let archiveError = error as? EPUBArchiveError {
            switch archiveError {
            case .invalidEPUB:
                return BookImportError.invalidEPUB
            case .invalidMetadata:
                return BookImportError.invalidEPUBMetadata
            }
        }
        return error
    }
}

private struct EPUBMetadata {
    let title: String
    let author: String
}

private struct EPUBMetadataReader {
    let fileManager: FileManager

    func read(from url: URL, fallbackTitle: String) throws -> EPUBMetadata {
        let archive = try EPUBArchive(url: url, fileManager: fileManager)
        let mimetype = try archive.data(for: "mimetype")
        guard String(data: mimetype, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "application/epub+zip" else {
            throw EPUBArchiveError.invalidEPUB
        }

        let containerData = try archive.data(for: "META-INF/container.xml")
        let containerParser = ContainerXMLParser()
        guard containerParser.parse(containerData), let packagePath = containerParser.packagePath else {
            throw EPUBArchiveError.invalidEPUB
        }

        let packageData = try archive.data(for: packagePath)
        let packageParser = PackageXMLParser()
        guard packageParser.parse(packageData) else {
            throw EPUBArchiveError.invalidMetadata
        }

        let title = packageParser.title?.nonEmpty ?? fallbackTitle.nonEmpty ?? "Untitled"
        let author = packageParser.author?.nonEmpty ?? "Unknown author"
        return EPUBMetadata(title: title, author: author)
    }
}

private enum EPUBArchiveError: Error {
    case invalidEPUB
    case invalidMetadata
}

struct EPUBArchive {
    private struct Entry {
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]

    init(url: URL, fileManager: FileManager) throws {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw EPUBArchiveError.invalidEPUB
        }
        self.data = data
        self.entries = try EPUBArchive.makeEntries(from: data)
    }

    func data(for name: String) throws -> Data {
        guard let normalizedName = try? EPUBArchivePath.normalized(name),
              let entry = entries[normalizedName] else {
            throw EPUBArchiveError.invalidEPUB
        }
        guard entry.localHeaderOffset + 30 <= data.count,
              data.uint32(at: entry.localHeaderOffset) == 0x04034b50 else {
            throw EPUBArchiveError.invalidEPUB
        }

        let nameLength = Int(data.uint16(at: entry.localHeaderOffset + 26))
        let extraLength = Int(data.uint16(at: entry.localHeaderOffset + 28))
        let contentOffset = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard contentOffset >= 0,
              contentOffset <= data.count,
              entry.compressedSize <= data.count - contentOffset else {
            throw EPUBArchiveError.invalidEPUB
        }

        let contentEnd = contentOffset + entry.compressedSize
        let compressedData = data.subdata(in: contentOffset..<contentEnd)
        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            guard let inflated = inflate(compressedData, expectedSize: entry.uncompressedSize) else {
                throw EPUBArchiveError.invalidEPUB
            }
            return inflated
        default:
            throw EPUBArchiveError.invalidEPUB
        }
    }

    private static func makeEntries(from data: Data) throws -> [String: Entry] {
        guard let endOfCentralDirectory = data.lastSignature(0x06054b50, maximumDistance: 65_557),
              endOfCentralDirectory + 22 <= data.count else {
            throw EPUBArchiveError.invalidEPUB
        }

        let entryCount = Int(data.uint16(at: endOfCentralDirectory + 10))
        let centralDirectorySize = Int(data.uint32(at: endOfCentralDirectory + 12))
        let centralDirectoryOffset = Int(data.uint32(at: endOfCentralDirectory + 16))
        guard centralDirectoryOffset >= 0,
              centralDirectorySize >= 0,
              centralDirectoryOffset + centralDirectorySize <= data.count else {
            throw EPUBArchiveError.invalidEPUB
        }

        var entries = [String: Entry]()
        var offset = centralDirectoryOffset
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count,
                  data.uint32(at: offset) == 0x02014b50 else {
                throw EPUBArchiveError.invalidEPUB
            }

            let compressionMethod = data.uint16(at: offset + 10)
            let compressedSize = Int(data.uint32(at: offset + 20))
            let declaredUncompressedSize = UInt64(data.uint32(at: offset + 24))
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            let localHeaderOffset = Int(data.uint32(at: offset + 42))
            let nameStart = offset + 46
            let nameEnd = nameStart + nameLength
            guard declaredUncompressedSize <= UInt64(maxUncompressedZIPEntrySize),
                  compressedSize <= maxUncompressedZIPEntrySize,
                  nameEnd <= data.count,
                  let rawName = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8),
                  let name = try? EPUBArchivePath.normalizedArchiveEntry(rawName) else {
                throw EPUBArchiveError.invalidEPUB
            }

            entries[name] = Entry(
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: Int(declaredUncompressedSize),
                localHeaderOffset: localHeaderOffset
            )
            offset = nameEnd + extraLength + commentLength
        }
        return entries
    }
}

private final class ContainerXMLParser: NSObject, XMLParserDelegate {
    private(set) var packagePath: String?

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "rootfile" || qName == "rootfile" {
            packagePath = attributeDict["full-path"]
        }
    }
}

private final class PackageXMLParser: NSObject, XMLParserDelegate {
    private(set) var title: String?
    private(set) var author: String?

    private var currentField: Field?
    private var currentText = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        switch name {
        case "title":
            currentField = .title
            currentText = ""
        case "creator":
            currentField = .author
            currentText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentField != nil else { return }
        currentText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let field = currentField else { return }
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        guard (field == .title && name == "title") || (field == .author && name == "creator") else {
            return
        }

        switch field {
        case .title:
            title = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .author:
            author = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentField = nil
        currentText = ""
    }

    private enum Field {
        case title
        case author
    }
}

private func inflate(_ compressedData: Data, expectedSize: Int) -> Data? {
    guard expectedSize >= 0,
          expectedSize <= maxUncompressedZIPEntrySize,
          !compressedData.isEmpty else {
        return expectedSize == 0 && compressedData.isEmpty ? Data() : nil
    }

    var stream = z_stream()
    let initResult = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard initResult == Z_OK else { return nil }
    defer { inflateEnd(&stream) }

    var output = Data(count: Swift.max(expectedSize, 1))
    let compressedCount = compressedData.count
    let outputCount = output.count
    let result: Int32 = compressedData.withUnsafeBytes { inputBuffer in
        output.withUnsafeMutableBytes { outputBuffer in
            guard let inputBaseAddress = inputBuffer.baseAddress,
                  let outputBaseAddress = outputBuffer.baseAddress else {
                return Z_DATA_ERROR
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBaseAddress.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(compressedCount)
            stream.next_out = outputBaseAddress.assumingMemoryBound(to: Bytef.self)
            stream.avail_out = uInt(outputCount)
            return inflate(&stream, Z_FINISH)
        }
    }

    guard result == Z_STREAM_END else { return nil }
    output.removeSubrange(Int(stream.total_out)..<output.count)
    return output
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) |
            UInt16(self[offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 |
            UInt32(self[offset + 3]) << 24
    }

    func lastSignature(_ signature: UInt32, maximumDistance: Int) -> Int? {
        let start = Swift.max(0, count - maximumDistance)
        guard count >= 4 else { return nil }
        for offset in stride(from: count - 4, through: start, by: -1) {
            if uint32(at: offset) == signature {
                return offset
            }
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
