import Foundation
import Testing
@testable import peekturn_ios

struct peekturn_iosTests {
    @Test func bookProgressIsKeptInsideTheSupportedRange() {
        #expect(Book(title: "A", author: "B", progress: -0.2).progress == 0)
        #expect(Book(title: "A", author: "B", progress: 0.4).progress == 0.4)
        #expect(Book(title: "A", author: "B", progress: 1.4).progress == 1)
    }

    @Test func nonFiniteBookProgressFallsBackToZero() {
        #expect(Book(title: "A", author: "B", progress: .infinity).progress == 0)
        #expect(Book(title: "A", author: "B", progress: .nan).progress == 0)
    }

    @Test func importerCopiesEPUBAndReadsBookMetadata() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let sourceURL = rootDirectory.appendingPathComponent("source.epub")
        let sourceData = makeEPUBData(title: "A Real Book", author: "Jane Doe")
        try sourceData.write(to: sourceURL)

        let storageDirectory = rootDirectory.appendingPathComponent("PrivateBooks", isDirectory: true)
        let importer = BookImporter(storageDirectory: storageDirectory)
        let book = try importer.importBook(from: sourceURL)

        #expect(book.title == "A Real Book")
        #expect(book.author == "Jane Doe")
        #expect(book.progress == 0)
        #expect(book.epubFileName.hasSuffix(".epub"))

        let storedURL = storageDirectory.appendingPathComponent(book.epubFileName)
        #expect(fileManager.fileExists(atPath: storedURL.path))
        #expect(try Data(contentsOf: storedURL) == sourceData)
    }

    @Test func importerRemovesTemporaryFileWhenEPUBIsInvalid() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let sourceURL = rootDirectory.appendingPathComponent("broken.epub")
        try Data("not an EPUB".utf8).write(to: sourceURL)

        let storageDirectory = rootDirectory.appendingPathComponent("PrivateBooks", isDirectory: true)
        let importer = BookImporter(storageDirectory: storageDirectory)

        do {
            _ = try importer.importBook(from: sourceURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? BookImportError == .invalidEPUB)
        }

        let remainingFiles = try fileManager.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(remainingFiles.isEmpty)
    }

    @Test func repositoryPersistsAndDeletesBookAndFile() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let repository = BookRepository(rootDirectory: rootDirectory)
        let book = Book(title: "Book", author: "Author", epubFileName: "book.epub")
        guard let storedURL = try repository.fileURL(for: book) else {
            #expect(Bool(false))
            return
        }
        try fileManager.createDirectory(at: repository.booksDirectory, withIntermediateDirectories: true)
        try Data("epub".utf8).write(to: storedURL)

        try repository.save(book)
        let reopenedRepository = BookRepository(rootDirectory: rootDirectory)
        let savedBooks = try reopenedRepository.fetchAll()
        #expect(savedBooks == [book])

        try reopenedRepository.delete(book)
        #expect(try reopenedRepository.fetchAll().isEmpty)
        #expect(!fileManager.fileExists(atPath: storedURL.path))
    }

    @Test func repositoryReportsCorruptedLibraryData() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try Data("corrupted".utf8).write(to: rootDirectory.appendingPathComponent("library.json"))

        do {
            _ = try BookRepository(rootDirectory: rootDirectory).fetchAll()
            #expect(Bool(false))
        } catch {
            #expect(error as? BookRepositoryError == .invalidLibraryData)
        }
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PeekturnTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeEPUBData(title: String, author: String) -> Data {
    let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
        </rootfiles>
    </container>
    """.data(using: .utf8)!

    let packageXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
        <metadata>
            <dc:title>\(title)</dc:title>
            <dc:creator>\(author)</dc:creator>
        </metadata>
    </package>
    """.data(using: .utf8)!

    return makeStoredZIP(entries: [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", containerXML),
        ("OEBPS/content.opf", packageXML)
    ])
}

private func makeStoredZIP(entries: [(String, Data)]) -> Data {
    var archive = Data()
    var centralDirectory = Data()
    var localOffsets: [Int] = []

    for (name, content) in entries {
        let nameData = Data(name.utf8)
        localOffsets.append(archive.count)

        appendUInt32(0x04034b50, to: &archive)
        appendUInt16(20, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt16(0, to: &archive)
        appendUInt32(0, to: &archive)
        appendUInt32(UInt32(content.count), to: &archive)
        appendUInt32(UInt32(content.count), to: &archive)
        appendUInt16(UInt16(nameData.count), to: &archive)
        appendUInt16(0, to: &archive)
        archive.append(contentsOf: nameData)
        archive.append(contentsOf: content)
    }

    let centralDirectoryOffset = archive.count
    for (index, entry) in entries.enumerated() {
        let nameData = Data(entry.0.utf8)
        let content = entry.1

        appendUInt32(0x02014b50, to: &centralDirectory)
        appendUInt16(20, to: &centralDirectory)
        appendUInt16(20, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt32(0, to: &centralDirectory)
        appendUInt32(UInt32(content.count), to: &centralDirectory)
        appendUInt32(UInt32(content.count), to: &centralDirectory)
        appendUInt16(UInt16(nameData.count), to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt16(0, to: &centralDirectory)
        appendUInt32(0, to: &centralDirectory)
        appendUInt32(UInt32(localOffsets[index]), to: &centralDirectory)
        centralDirectory.append(contentsOf: nameData)
    }

    archive.append(contentsOf: centralDirectory)
    appendUInt32(0x06054b50, to: &archive)
    appendUInt16(0, to: &archive)
    appendUInt16(0, to: &archive)
    appendUInt16(UInt16(entries.count), to: &archive)
    appendUInt16(UInt16(entries.count), to: &archive)
    appendUInt32(UInt32(centralDirectory.count), to: &archive)
    appendUInt32(UInt32(centralDirectoryOffset), to: &archive)
    appendUInt16(0, to: &archive)
    return archive
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}
