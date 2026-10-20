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

            let normalizedPackagePath: String
            do {
                normalizedPackagePath = try EPUBArchivePath.normalized(packagePath)
            } catch {
                throw EPUBReaderError.invalidEPUB
            }

            let packageData = try archive.data(for: normalizedPackagePath)
            let packageParser = ReaderPackageParser()
            guard packageParser.parse(packageData, relativeTo: normalizedPackagePath),
                  let firstSpineItem = packageParser.firstReadableSpineItem() else {
                throw EPUBReaderError.noReadableContent
            }

            let firstSpinePath = firstSpineItem.archivePath
            guard (try? archive.data(for: firstSpinePath)) != nil else {
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
                    guard let data = try? archive.data(for: item.archivePath) else {
                        if item.archivePath == firstSpinePath {
                            throw EPUBReaderError.noReadableContent
                        }
                        continue
                    }
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

                let securedDocumentURL = mainDocumentURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(".peekturn-main-\(UUID().uuidString).xhtml")
                let mainDocumentData = try Data(contentsOf: mainDocumentURL)
                try ReaderHTMLSecurity.securedData(from: mainDocumentData)
                    .write(to: securedDocumentURL, options: .atomic)

                return EPUBReadingDocument(
                    mainDocumentURL: securedDocumentURL,
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
    let mediaType: String

    var isReadableDocument: Bool {
        let normalizedMediaType = mediaType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return normalizedMediaType == "application/xhtml+xml" || normalizedMediaType == "text/html"
    }
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
    private var spineItemReferences = [(id: String?, isLinear: Bool)]()
    private var packageDirectory: String?

    func parse(_ data: Data, relativeTo packagePath: String) -> Bool {
        do {
            packageDirectory = try EPUBArchivePath.directory(of: packagePath)
        } catch {
            return false
        }

        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func firstReadableSpineItem() -> ReaderManifestItem? {
        for reference in spineItemReferences {
            guard reference.isLinear,
                  let id = reference.id,
                  !id.isEmpty,
                  let item = manifest[id],
                  item.isReadableDocument else {
                continue
            }
            return item
        }
        return nil
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
                  let mediaType = attributeDict["media-type"],
                  let archivePath = try? EPUBArchivePath.normalized(href, relativeTo: packageDirectory) else {
                return
            }
            manifest[id] = ReaderManifestItem(archivePath: archivePath, mediaType: mediaType)
        case "itemref":
            let idref = attributeDict["idref"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let isLinear = attributeDict["linear"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "no"
            spineItemReferences.append((id: idref, isLinear: isLinear))
        default:
            break
        }
    }
}
