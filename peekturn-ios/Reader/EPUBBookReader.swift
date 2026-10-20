import Foundation

struct EPUBReadingDocument: Sendable {
    let mainDocumentURL: URL
    let readAccessDirectory: URL
    let temporaryDirectory: URL

    func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

enum EPUBReaderError: LocalizedError, Equatable {
    case sourceUnavailable
    case invalidEPUB
    case noReadableContent

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            return "This book file is unavailable."
        case .invalidEPUB:
            return "This EPUB could not be opened."
        case .noReadableContent:
            return "This EPUB has no readable chapters."
        }
    }
}

struct EPUBBookReader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepareReadingDocument(from epubURL: URL) throws -> EPUBReadingDocument {
        guard epubURL.isFileURL,
              fileManager.fileExists(atPath: epubURL.path),
              !isDirectory(epubURL) else {
            throw EPUBReaderError.sourceUnavailable
        }

        do {
            let archive = try EPUBArchive(url: epubURL, fileManager: fileManager)
            let containerData = try archive.data(for: "META-INF/container.xml")
            let containerParser = ReaderContainerParser()
            guard containerParser.parse(containerData),
                  let packagePath = containerParser.packagePath else {
                throw EPUBReaderError.invalidEPUB
            }

            let packageData = try archive.data(for: packagePath)
            let packageParser = ReaderPackageParser()
            guard packageParser.parse(packageData, relativeTo: packagePath),
                  let firstSpineItem = packageParser.spineItemIDs.first,
                  let firstSpinePath = packageParser.manifest[firstSpineItem]?.archivePath else {
                throw EPUBReaderError.noReadableContent
            }

            let temporaryDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("PeekturnReader-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )

            do {
                for item in packageParser.manifest.values {
                    let destinationURL = try destinationURL(
                        for: item.archivePath,
                        in: temporaryDirectory
                    )
                    let data = try archive.data(for: item.archivePath)
                    try fileManager.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: destinationURL, options: .atomic)
                }

                let mainDocumentURL = try destinationURL(
                    for: firstSpinePath,
                    in: temporaryDirectory
                )
                guard fileManager.fileExists(atPath: mainDocumentURL.path) else {
                    throw EPUBReaderError.noReadableContent
                }

                return EPUBReadingDocument(
                    mainDocumentURL: mainDocumentURL,
                    readAccessDirectory: temporaryDirectory,
                    temporaryDirectory: temporaryDirectory
                )
            } catch {
                try? fileManager.removeItem(at: temporaryDirectory)
                throw normalizedError(for: error)
            }
        } catch {
            throw normalizedError(for: error)
        }
    }

    private func destinationURL(for archivePath: String, in directory: URL) throws -> URL {
        guard !archivePath.isEmpty,
              !archivePath.hasPrefix("/"),
              !archivePath.contains("\\") else {
            throw EPUBReaderError.invalidEPUB
        }

        let destinationURL = directory.appendingPathComponent(archivePath, isDirectory: false)
        guard destinationURL.deletingLastPathComponent().standardizedFileURL.path
            .hasPrefix(directory.standardizedFileURL.path + "/") ||
            destinationURL.standardizedFileURL == directory.standardizedFileURL else {
            throw EPUBReaderError.invalidEPUB
        }
        return destinationURL
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    private func normalizedError(for error: Error) -> EPUBReaderError {
        if let readerError = error as? EPUBReaderError {
            return readerError
        }
        return .invalidEPUB
    }
}

private struct ReaderManifestItem {
    let archivePath: String
}

private final class ReaderContainerParser: NSObject, XMLParserDelegate {
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
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if name == "rootfile" {
            packagePath = attributeDict["full-path"]
        }
    }
}

private final class ReaderPackageParser: NSObject, XMLParserDelegate {
    private(set) var manifest = [String: ReaderManifestItem]()
    private(set) var spineItemIDs = [String]()
    private var packageDirectory = [String]()

    func parse(_ data: Data, relativeTo packagePath: String) -> Bool {
        packageDirectory = packagePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .dropLast()
            .map(String.init)

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
        case "item":
            guard let id = attributeDict["id"],
                  let href = attributeDict["href"],
                  let archivePath = Self.archivePath(for: href, relativeTo: packageDirectory) else {
                return
            }
            manifest[id] = ReaderManifestItem(archivePath: archivePath)
        case "itemref":
            if let idref = attributeDict["idref"] {
                spineItemIDs.append(idref)
            }
        default:
            break
        }
    }

    private static func archivePath(for href: String, relativeTo packageDirectory: [String]) -> String? {
        let pathPart = href.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init)
        guard let pathPart,
              !pathPart.isEmpty,
              !pathPart.hasPrefix("/"),
              !pathPart.contains("://") else {
            return nil
        }

        let decodedPath = pathPart.removingPercentEncoding ?? pathPart
        var components = packageDirectory
        for component in decodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }
}
