import Foundation
import Network
import Testing
import UIKit
import WebKit
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

    @Test func importerRejectsEPUBWithUnreasonableUncompressedSize() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let sourceURL = rootDirectory.appendingPathComponent("oversized.epub")
        let oversizedArchive = replacingFirstCentralDirectoryUncompressedSize(
            in: makeEPUBData(title: "Book", author: "Author"),
            with: .max
        )
        try oversizedArchive.write(to: sourceURL)

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

    @Test func importerRejectsCentralDirectoryNameOutsideDeclaredRange() throws {
        try assertImporterRejects(
            replacingFirstCentralDirectoryField(in: makeEPUBData(title: "Book", author: "Author"), fieldOffset: 28, with: .max)
        )
    }

    @Test func importerRejectsCentralDirectoryExtraFieldOutsideDeclaredRange() throws {
        try assertImporterRejects(
            replacingFirstCentralDirectoryField(in: makeEPUBData(title: "Book", author: "Author"), fieldOffset: 30, with: .max)
        )
    }

    @Test func importerRejectsCentralDirectoryCommentOutsideDeclaredRange() throws {
        try assertImporterRejects(
            replacingFirstCentralDirectoryField(in: makeEPUBData(title: "Book", author: "Author"), fieldOffset: 32, with: .max)
        )
    }

    @Test func archiveRejectsCentralDirectoryThatExtendsPastEOCD() throws {
        let archiveData = makeEPUBData(title: "Book", author: "Author")
        let eocdOffset = archiveData.count - 22
        let centralDirectorySize = readUInt32(archiveData, at: eocdOffset + 12)
        let malformedData = replacingEOCDCentralDirectory(
            in: archiveData,
            entryCount: 3,
            centralDirectorySize: centralDirectorySize + 1,
            centralDirectoryOffset: readUInt32(archiveData, at: eocdOffset + 16)
        )

        assertArchiveRejects(malformedData)
    }

    @Test func archiveRejectsCentralDirectoryLocatedAfterEOCD() throws {
        let archiveData = makeEPUBData(title: "Book", author: "Author")
        let malformedData = replacingEOCDCentralDirectory(
            in: archiveData,
            entryCount: 0,
            centralDirectorySize: 0,
            centralDirectoryOffset: UInt32(archiveData.count)
        )

        assertArchiveRejects(malformedData)
    }

    @Test func readerPreparesFirstSpineDocumentFromEPUB() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let epubURL = rootDirectory.appendingPathComponent("reader.epub")
        try makeReadableEPUBData().write(to: epubURL)

        let document = try EPUBBookReader().prepareReadingDocument(from: epubURL)
        defer { document.removeTemporaryFiles() }

        #expect(fileManager.fileExists(atPath: document.mainDocumentURL.path))
        #expect(fileManager.fileExists(atPath: document.readAccessDirectory.path))
        let chapter = try String(contentsOf: document.mainDocumentURL, encoding: .utf8)
        #expect(chapter.contains("The First Chapter"))
        #expect(chapter.contains("Original EPUB content."))
    }

    @Test func readerPreparesLargerEPUBFromDetachedWork() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let epubURL = rootDirectory.appendingPathComponent("larger-reader.epub")
        let largeChapter = String(repeating: "<p>Reading content.</p>", count: 40_000)
        try makeReaderEPUBData(
            packageXML: """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                <manifest><item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
                <spine><itemref idref="chapter"/></spine>
            </package>
            """,
            resources: [("OEBPS/Text/chapter.xhtml", "<html><head></head><body>\(largeChapter)</body></html>")]
        ).write(to: epubURL)

        let document = try await Task.detached(priority: .userInitiated) {
            try EPUBBookReader().prepareReadingDocument(from: epubURL)
        }.value
        defer { document.removeTemporaryFiles() }

        #expect(FileManager.default.fileExists(atPath: document.mainDocumentURL.path))
    }

    @Test func readerReportsInvalidEPUBSource() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let epubURL = rootDirectory.appendingPathComponent("broken.epub")
        try Data("not an EPUB".utf8).write(to: epubURL)

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .invalidEPUB)
        }
    }

    @Test func readerRejectsZIPWithInvalidMimetype() throws {
        let epubURL = try writeReaderEPUB(
            packageXML: "<package><manifest/><spine/></package>",
            mimetype: "application/zip"
        )
        defer { try? FileManager.default.removeItem(at: epubURL.deletingLastPathComponent()) }

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .invalidEPUB)
        }
    }

    @Test func readerRejectsMimetypeThatIsNotTheFirstZIPEntry() throws {
        let archiveData = makeStoredZIP(entries: [
            ("META-INF/container.xml", Data()),
            ("mimetype", Data("application/epub+zip".utf8))
        ])
        assertArchiveRejects(archiveData)
    }

    @Test func readerRejectsCompressedMimetype() throws {
        assertArchiveRejects(
            replacingFirstMimetypeCompressionMethod(
                in: makeEPUBData(title: "Book", author: "Author"),
                with: 8
            )
        )
    }

    @Test func readerRejectsMimetypeWithAnExtraField() throws {
        assertArchiveRejects(
            replacingFirstMimetypeExtraLength(
                in: makeEPUBData(title: "Book", author: "Author"),
                with: 1
            )
        )
    }

    @Test func archiveRejectsIllegalFirstMimetypeFollowedByValidDuplicate() {
        assertArchiveRejects(
            makeStoredZIP(entries: [
                ("mimetype", Data("application/zip".utf8)),
                ("mimetype", Data("application/epub+zip".utf8))
            ])
        )
    }

    @Test func archiveRejectsValidFirstMimetypeFollowedByDuplicateReplacement() {
        assertArchiveRejects(
            makeStoredZIP(entries: [
                ("mimetype", Data("application/epub+zip".utf8)),
                ("mimetype", Data("application/zip".utf8))
            ])
        )
    }

    @Test func archiveRejectsDuplicateOrdinaryEntryNames() {
        assertArchiveRejects(
            makeStoredZIP(entries: [
                ("mimetype", Data("application/epub+zip".utf8)),
                ("chapter.xhtml", Data("first".utf8)),
                ("chapter.xhtml", Data("second".utf8))
            ])
        )
    }

    @Test func readerRejectsEPUBWithDuplicateEntries() throws {
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let packageXML = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <manifest><item id="chapter" href="Text/chapter.xhtml" media-type="text/html"/></manifest>
            <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let archiveData = makeStoredZIP(entries: [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(packageXML.utf8)),
            ("OEBPS/content.opf", Data(packageXML.utf8)),
            ("OEBPS/Text/chapter.xhtml", Data("<h1>Chapter</h1>".utf8))
        ])
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let epubURL = rootDirectory.appendingPathComponent("duplicate.epub")
        try archiveData.write(to: epubURL)

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .invalidEPUB)
        }
    }

    @Test func readerClassifiesMalformedOPFAsInvalidEPUB() throws {
        let epubURL = try writeReaderEPUB(
            packageXML: "<package><manifest>",
            mimetype: "application/epub+zip"
        )
        defer { try? FileManager.default.removeItem(at: epubURL.deletingLastPathComponent()) }

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .invalidEPUB)
        }
    }

    @Test func readerSkipsNonLinearAndInvalidSpineReferences() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let packageXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <manifest>
                <item id="nonlinear" href="Text/nonlinear.xhtml" media-type="application/xhtml+xml"/>
                <item id="style" href="Styles/book.css" media-type="text/css"/>
                <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine>
                <itemref idref="nonlinear" linear="no"/>
                <itemref/>
                <itemref idref="missing"/>
                <itemref idref="style"/>
                <itemref idref="chapter"/>
            </spine>
        </package>
        """
        let epubURL = rootDirectory.appendingPathComponent("spine.epub")
        try makeReaderEPUBData(
            packageXML: packageXML,
            resources: [
                ("OEBPS/Text/nonlinear.xhtml", "<h1>Nonlinear</h1>"),
                ("OEBPS/Text/chapter.xhtml", "<h1>Linear chapter</h1>")
            ]
        ).write(to: epubURL)

        let document = try EPUBBookReader().prepareReadingDocument(from: epubURL)
        defer { document.removeTemporaryFiles() }
        let chapter = try String(contentsOf: document.mainDocumentURL, encoding: .utf8)
        #expect(chapter.contains("Linear chapter"))
        #expect(!chapter.contains("Nonlinear"))
    }

    @Test func readerReportsNoReadableContentWhenManifestItemIsMissing() throws {
        let epubURL = try writeReaderEPUB(
            packageXML: """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                <manifest/>
                <spine><itemref idref="missing"/></spine>
            </package>
            """
        )
        defer { try? FileManager.default.removeItem(at: epubURL.deletingLastPathComponent()) }

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .noReadableContent)
        }
    }

    @Test func readerReportsNoReadableContentWhenSpineIsMissing() throws {
        let epubURL = try writeReaderEPUB(
            packageXML: """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                <manifest>
                    <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
                </manifest>
            </package>
            """,
            resources: [("OEBPS/Text/chapter.xhtml", "<h1>Chapter</h1>")]
        )
        defer { try? FileManager.default.removeItem(at: epubURL.deletingLastPathComponent()) }

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .noReadableContent)
        }
    }

    @Test func readerReportsNoReadableContentWhenChapterFileIsMissing() throws {
        let epubURL = try writeReaderEPUB(
            packageXML: """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                <manifest>
                    <item id="chapter" href="Text/missing.xhtml" media-type="text/html"/>
                </manifest>
                <spine><itemref idref="chapter"/></spine>
            </package>
            """
        )
        defer { try? FileManager.default.removeItem(at: epubURL.deletingLastPathComponent()) }

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .noReadableContent)
        }
    }

    @Test func readerResolvesEncodedOPFAndRelativeChapterPaths() throws {
        let packageXML = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <manifest>
                <item id="chapter" href="../Text%20Files/chapter%20one.xhtml" media-type="application/xhtml+xml"/>
            </manifest>
            <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let epubURL = rootDirectory.appendingPathComponent("encoded.epub")
        try makeReaderEPUBData(
            packagePath: "OEBPS/Book%20Files/content.opf",
            packageXML: packageXML,
            resources: [("OEBPS/Text Files/chapter one.xhtml", "<h1>Encoded chapter</h1>")]
        ).write(to: epubURL)

        let document = try EPUBBookReader().prepareReadingDocument(from: epubURL)
        defer { document.removeTemporaryFiles() }
        #expect(document.mainDocumentURL.deletingLastPathComponent().path.contains("Text Files"))
        let chapter = try String(contentsOf: document.mainDocumentURL, encoding: .utf8)
        #expect(chapter.contains("Encoded chapter"))
        #expect(chapter.contains("Content-Security-Policy"))
    }

    @Test func readerSupportsUTF16ChapterWithBOMAndPreservesCSP() throws {
        let packageXML = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <manifest><item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let utf16Chapter = makeUTF16LEData("""
        <?xml version="1.0" encoding="UTF-16"?>
        <html><head><script>window.bad = true</script></head><body><h1>UTF-16 chapter</h1></body></html>
        """)
        let epubURL = try writeReaderEPUB(
            packageXML: packageXML,
            binaryResources: [("OEBPS/Text/chapter.xhtml", utf16Chapter)]
        )
        defer { try? FileManager.default.removeItem(at: epubURL.deletingLastPathComponent()) }

        let document = try EPUBBookReader().prepareReadingDocument(from: epubURL)
        defer { document.removeTemporaryFiles() }
        let securedChapter = try String(contentsOf: document.mainDocumentURL, encoding: .utf8)
        #expect(securedChapter.contains("UTF-16 chapter"))
        #expect(securedChapter.contains("encoding=\"UTF-8\""))
        #expect(securedChapter.contains("Content-Security-Policy"))
        #expect(securedChapter.range(of: "Content-Security-Policy")!.lowerBound < securedChapter.range(of: "<script")!.lowerBound)
    }

    @Test func readerSupportsUTF8ChapterWithAndWithoutBOM() throws {
        let packageXML = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <manifest><item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let chapter = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html><body><h1>UTF-8</h1></body></html>".utf8)
        let variants = [chapter, Data([0xef, 0xbb, 0xbf]) + chapter]
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        for (index, chapterData) in variants.enumerated() {
            let epubURL = rootDirectory.appendingPathComponent("utf8-\(index).epub")
            try makeReaderEPUBData(
                packageXML: packageXML,
                binaryResources: [("OEBPS/Text/chapter.xhtml", chapterData)]
            ).write(to: epubURL)
            let document = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            defer { document.removeTemporaryFiles() }
            let securedChapter = try String(contentsOf: document.mainDocumentURL, encoding: .utf8)
            #expect(securedChapter.contains("UTF-8"))
            #expect(securedChapter.contains("Content-Security-Policy"))
        }
    }

    @Test func readerSupportsUTF16BigEndianBOMAndNoBOMDeclaredEncoding() throws {
        let packageXML = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <manifest><item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let chapter = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><html><body><h1>UTF-16</h1></body></html>"
        let variants = [makeUTF16BEData(chapter), makeUTF16BEDataWithoutBOM(chapter)]
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        for (index, chapterData) in variants.enumerated() {
            let epubURL = rootDirectory.appendingPathComponent("utf16-be-\(index).epub")
            try makeReaderEPUBData(
                packageXML: packageXML,
                binaryResources: [("OEBPS/Text/chapter.xhtml", chapterData)]
            ).write(to: epubURL)
            let document = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            defer { document.removeTemporaryFiles() }
            let securedChapter = try String(contentsOf: document.mainDocumentURL, encoding: .utf8)
            #expect(securedChapter.contains("UTF-16"))
            #expect(securedChapter.contains("encoding=\"UTF-8\""))
            #expect(securedChapter.contains("Content-Security-Policy"))
        }
    }

    @Test func readerRejectsMismatchedBOMAndXMLDeclarationEncoding() throws {
        let packageXML = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <manifest><item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
            <spine><itemref idref="chapter"/></spine>
        </package>
        """
        let variants = [
            makeUTF16LEData("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html><body>Mismatch</body></html>"),
            Data([0xef, 0xbb, 0xbf]) + Data("<?xml version=\"1.0\" encoding=\"UTF-16\"?><html><body>Mismatch</body></html>".utf8),
            makeUTF16LEDataWithoutBOM("<?xml version=\"1.0\" encoding=\"UTF-16BE\"?><html><body>Mismatch</body></html>")
        ]
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        for (index, chapterData) in variants.enumerated() {
            let epubURL = rootDirectory.appendingPathComponent("mismatch-\(index).epub")
            try makeReaderEPUBData(
                packageXML: packageXML,
                binaryResources: [("OEBPS/Text/chapter.xhtml", chapterData)]
            ).write(to: epubURL)
            do {
                _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
                #expect(Bool(false))
            } catch {
                #expect(error as? EPUBReaderError == .invalidEPUB)
            }
        }
    }

    @Test func readerRejectsChapterWithUnknownEncoding() throws {
        let epubURL = try writeReaderEPUB(
            packageXML: """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                <manifest><item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
                <spine><itemref idref="chapter"/></spine>
            </package>
            """,
            binaryResources: [
                (
                    "OEBPS/Text/chapter.xhtml",
                    Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><html><body>Chapter</body></html>".utf8)
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: epubURL.deletingLastPathComponent()) }

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .invalidEPUB)
        }
    }

    @Test func readerRejectsOPFPathTraversal() throws {
        let epubURL = try writeReaderEPUB(
            packageXML: """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
                <manifest>
                    <item id="chapter" href="../../outside.xhtml" media-type="application/xhtml+xml"/>
                </manifest>
                <spine><itemref idref="chapter"/></spine>
            </package>
            """
        )
        defer { try? FileManager.default.removeItem(at: epubURL.deletingLastPathComponent()) }

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .noReadableContent)
        }
    }

    @Test func readerRejectsIllegalZIPEntryPath() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let epubURL = rootDirectory.appendingPathComponent("illegal-entry.epub")
        let packageXML = """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
            <manifest><item id="chapter" href="Text/chapter.xhtml" media-type="text/html"/></manifest>
            <spine><itemref idref="chapter"/></spine>
        </package>
        """
        try makeReaderEPUBData(
            packageXML: packageXML,
            resources: [
                ("OEBPS/Text/chapter.xhtml", "<h1>Chapter</h1>"),
                ("../outside.txt", "outside")
            ]
        ).write(to: epubURL)

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .invalidEPUB)
        }
    }

    @Test func readerRejectsTruncatedZIP() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let epubURL = rootDirectory.appendingPathComponent("truncated.epub")
        var data = makeReadableEPUBData()
        data.removeLast(10)
        try data.write(to: epubURL)

        do {
            _ = try EPUBBookReader().prepareReadingDocument(from: epubURL)
            #expect(Bool(false))
        } catch {
            #expect(error as? EPUBReaderError == .invalidEPUB)
        }
    }

    @Test func readerNavigationPolicyAllowsLocalFilesInsideReaderDirectory() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let localURL = rootDirectory.appendingPathComponent("chapter.xhtml")
        try Data("chapter".utf8).write(to: localURL)

        #expect(ReaderNavigationPolicy.allowsLocalFile(localURL, inside: rootDirectory))
        #expect(ReaderNavigationPolicy.allowsNavigation(localURL, inside: rootDirectory))
        #expect(ReaderNavigationPolicy.allowsResourceRequest(localURL, inside: rootDirectory))
    }

    @Test func readerNavigationPolicyRejectsExternalURLsAndRedirects() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let externalURL = try #require(URL(string: "https://example.com/book.xhtml"))

        #expect(!ReaderNavigationPolicy.allowsNavigation(externalURL, inside: rootDirectory))
        #expect(!ReaderNavigationPolicy.allowsRedirect(externalURL, inside: rootDirectory))
        #expect(!ReaderNavigationPolicy.allowsResourceRequest(externalURL, inside: rootDirectory))
    }

    @Test func readerNavigationPolicyRejectsFileURLsWithAHost() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let localURL = rootDirectory.appendingPathComponent("chapter.xhtml")
        let hostedFileURL = try #require(URL(string: "file://reader.example\(localURL.path)"))

        #expect(hostedFileURL.isFileURL)
        #expect(!ReaderNavigationPolicy.allowsLocalFile(hostedFileURL, inside: rootDirectory))
    }

    @Test func readerNavigationPolicyRejectsPathTraversalOutsideReaderDirectory() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let outsideURL = rootDirectory
            .appendingPathComponent("chapter.xhtml")
            .appendingPathComponent("../../outside.xhtml")

        #expect(!ReaderNavigationPolicy.allowsNavigation(outsideURL, inside: rootDirectory))
    }

    @Test func readerSecurityPolicyInitializesSuccessfully() throws {
        guard case .success(let policy) = ReaderSecurityPolicy.make() else {
            #expect(Bool(false))
            return
        }

        #expect(policy.contentSecurityPolicy.contains("script-src 'none'"))
        #expect(policy.encodedContentRuleList.contains("\"type\":\"block\""))
    }

    @Test func readerSecurityPolicyFailsClosedWhenRulesAreInvalid() {
        guard case .failure(.invalidContentRuleList) = ReaderSecurityPolicy.make(encodedContentRuleList: "not-json") else {
            #expect(Bool(false))
            return
        }
    }

    @Test func readerHTMLSecurityDisablesExternalNetworkCapabilities() throws {
        let policy = try #require(try? ReaderSecurityPolicy.make().get())
        let securedHTML = try ReaderHTMLSecurity.securedData(
            from: Data("<html><head><script>window.bad = true</script></head><body>Book</body></html>".utf8),
            policy: policy
        )
        let html = String(data: securedHTML, encoding: .utf8) ?? ""

        #expect(html.contains("connect-src 'none'"))
        #expect(html.contains("script-src 'none'"))
        #expect(!html.contains("http://"))
        #expect(!html.contains("https://"))
        #expect(html.range(of: "Content-Security-Policy")!.lowerBound < html.range(of: "<script")!.lowerBound)
    }

    @Test func readerNavigationReturnsToLibrary() {
        var state = ReaderNavigationState()
        let book = Book(title: "Book", author: "Author", epubFileName: "book.epub")

        #expect(!state.isReaderPresented)
        state.open(book: book)
        #expect(state.isReaderPresented)
        #expect(state.selectedBook == book)
        state.returnToLibrary()
        #expect(!state.isReaderPresented)
        #expect(state.selectedBook == nil)
    }

    @Test @MainActor func readerViewModelStartsInLoadingState() throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let book = Book(title: "Book", author: "Author", epubFileName: "missing.epub")
        let viewModel = ReaderViewModel(
            book: book,
            repository: BookRepository(rootDirectory: rootDirectory)
        )

        guard case .loading = viewModel.state else {
            #expect(Bool(false))
            return
        }
        viewModel.stop()
    }

    @Test @MainActor func readerViewModelShowsFailureState() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let book = Book(title: "Book", author: "Author", epubFileName: "missing.epub")
        let viewModel = ReaderViewModel(
            book: book,
            repository: BookRepository(rootDirectory: rootDirectory)
        )

        try await waitForReaderState(viewModel) { state in
            if case .failed = state { return true }
            return false
        }
        if case .failed(let message) = viewModel.state {
            #expect(message == EPUBReaderError.sourceUnavailable.errorDescription)
        } else {
            #expect(Bool(false))
        }
        viewModel.stop()
    }

    @Test @MainActor func readerViewModelRetryReturnsToLoadingAndLoadsDocument() async throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }
        let repository = BookRepository(rootDirectory: rootDirectory)
        let book = Book(title: "Book", author: "Author", epubFileName: "book.epub")
        let bookURL = try #require(try repository.fileURL(for: book))
        try fileManager.createDirectory(at: repository.booksDirectory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: bookURL)
        try repository.save(book)

        let viewModel = ReaderViewModel(book: book, repository: repository)
        try await waitForReaderState(viewModel) { state in
            if case .failed = state { return true }
            return false
        }

        try makeReadableEPUBData().write(to: bookURL, options: .atomic)
        viewModel.load()
        guard case .loading = viewModel.state else {
            #expect(Bool(false))
            return
        }

        try await waitForReaderState(viewModel) { state in
            if case .loaded = state { return true }
            return false
        }
        if case .loaded(let document) = viewModel.state {
            #expect(fileManager.fileExists(atPath: document.mainDocumentURL.path))
        } else {
            #expect(Bool(false))
        }
        viewModel.stop()
    }

    @Test @MainActor func readerViewModelWebKitFailureEntersFailedStateAndRetryRecovers() async throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }
        let repository = BookRepository(rootDirectory: rootDirectory)
        let book = Book(title: "Book", author: "Author", epubFileName: "book.epub")
        let bookURL = try #require(try repository.fileURL(for: book))
        try fileManager.createDirectory(at: repository.booksDirectory, withIntermediateDirectories: true)
        try makeReadableEPUBData().write(to: bookURL)
        try repository.save(book)

        let viewModel = ReaderViewModel(book: book, repository: repository)
        try await waitForReaderState(viewModel) { state in
            if case .loaded = state { return true }
            return false
        }

        let failedLoadID = viewModel.loadID
        viewModel.handleWebKitFailure("WebKit failed to load the chapter.", for: failedLoadID)
        if case .failed(let message) = viewModel.state {
            #expect(message == "WebKit failed to load the chapter.")
        } else {
            #expect(Bool(false))
        }

        viewModel.load()
        guard case .loading = viewModel.state else {
            #expect(Bool(false))
            return
        }
        try await waitForReaderState(viewModel) { state in
            if case .loaded = state { return true }
            return false
        }
        viewModel.stop()
    }

    @Test @MainActor func readerViewModelIgnoresCallbacksFromOlderLoadID() async throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }
        let repository = BookRepository(rootDirectory: rootDirectory)
        let book = Book(title: "Book", author: "Author", epubFileName: "book.epub")
        let bookURL = try #require(try repository.fileURL(for: book))
        try fileManager.createDirectory(at: repository.booksDirectory, withIntermediateDirectories: true)
        try makeReadableEPUBData().write(to: bookURL)
        try repository.save(book)

        let viewModel = ReaderViewModel(book: book, repository: repository)
        let firstLoadID = viewModel.loadID
        guard case .loading = viewModel.state else {
            #expect(Bool(false))
            return
        }

        viewModel.load()
        let secondLoadID = viewModel.loadID
        #expect(firstLoadID != secondLoadID)
        guard case .loading = viewModel.state else {
            #expect(Bool(false))
            return
        }

        viewModel.handleWebKitFailure("The old load failed.", for: firstLoadID)
        viewModel.handleWebKitFailure("The old load redirected.", for: firstLoadID)
        guard case .loading = viewModel.state else {
            #expect(Bool(false))
            return
        }

        try await waitForReaderState(viewModel) { state in
            if case .loaded = state { return true }
            return false
        }
        #expect(viewModel.loadID == secondLoadID)
        guard case .loaded = viewModel.state else {
            #expect(Bool(false))
            return
        }
        viewModel.stop()
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

    @Test func repositoryDeletesPersistedFileWhenCallerHasStaleFileName() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let repository = BookRepository(rootDirectory: rootDirectory)
        let persistedBook = Book(title: "Book", author: "Author", epubFileName: "actual.epub")
        let storedURL = try #require(try repository.fileURL(for: persistedBook))
        try fileManager.createDirectory(at: repository.booksDirectory, withIntermediateDirectories: true)
        try Data("epub".utf8).write(to: storedURL)
        try repository.save(persistedBook)

        let staleCallerBook = Book(
            id: persistedBook.id,
            title: persistedBook.title,
            author: persistedBook.author,
            epubFileName: "stale.epub"
        )

        try repository.delete(staleCallerBook)

        #expect(try repository.fetchAll().isEmpty)
        #expect(!fileManager.fileExists(atPath: storedURL.path))
        #expect(!fileManager.fileExists(
            atPath: repository.booksDirectory.appendingPathComponent("stale.epub").path
        ))
    }

    @Test func repositoryDoesNotDeleteFileForUnknownBookID() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let repository = BookRepository(rootDirectory: rootDirectory)
        let persistedBook = Book(title: "Book", author: "Author", epubFileName: "actual.epub")
        let storedURL = try #require(try repository.fileURL(for: persistedBook))
        let originalData = Data("epub".utf8)
        try fileManager.createDirectory(at: repository.booksDirectory, withIntermediateDirectories: true)
        try originalData.write(to: storedURL)
        try repository.save(persistedBook)

        let unknownBook = Book(
            id: UUID(),
            title: "Unknown",
            author: "Author",
            epubFileName: persistedBook.epubFileName
        )

        try repository.delete(unknownBook)

        #expect(try repository.fetchAll() == [persistedBook])
        #expect(fileManager.fileExists(atPath: storedURL.path))
        #expect(try Data(contentsOf: storedURL) == originalData)
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

    @Test func repositoryKeepsBookAndMetadataWhenBookDeletionFails() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let failingFileSystem = FailingBookRepositoryFileSystem()
        let repository = BookRepository(rootDirectory: rootDirectory, fileSystem: failingFileSystem)
        let book = Book(title: "Book", author: "Author", epubFileName: "book.epub")
        let storedURL = try #require(try repository.fileURL(for: book))
        let originalData = Data("epub".utf8)
        try fileManager.createDirectory(at: repository.booksDirectory, withIntermediateDirectories: true)
        try originalData.write(to: storedURL)
        try repository.save(book)

        failingFileSystem.failingRemovalPaths = [storedURL.standardizedFileURL.path]

        do {
            try repository.delete(book)
            #expect(Bool(false))
        } catch {
            #expect(error is TestFileSystemError)
        }

        #expect(try repository.fetchAll() == [book])
        #expect(fileManager.fileExists(atPath: storedURL.path))
        #expect(try Data(contentsOf: storedURL) == originalData)
    }

    @Test func repositoryKeepsBookAndMetadataWhenTemporaryMetadataWriteFails() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let failingFileSystem = FailingBookRepositoryFileSystem()
        let repository = BookRepository(rootDirectory: rootDirectory, fileSystem: failingFileSystem)
        let book = Book(title: "Book", author: "Author", epubFileName: "book.epub")
        let storedURL = try #require(try repository.fileURL(for: book))
        try fileManager.createDirectory(at: repository.booksDirectory, withIntermediateDirectories: true)
        try Data("epub".utf8).write(to: storedURL)
        try repository.save(book)

        failingFileSystem.failTemporaryLibraryWrite = true

        do {
            try repository.delete(book)
            #expect(Bool(false))
        } catch {
            #expect(error is TestFileSystemError)
        }

        #expect(try repository.fetchAll() == [book])
        #expect(fileManager.fileExists(atPath: storedURL.path))
    }

    @Test func repositoryRestoresStateWhenLibraryReplacementFailsAfterBookRemoval() throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        let failingFileSystem = FailingBookRepositoryFileSystem()
        let repository = BookRepository(rootDirectory: rootDirectory, fileSystem: failingFileSystem)
        let book = Book(title: "Book", author: "Author", epubFileName: "book.epub")
        let storedURL = try #require(try repository.fileURL(for: book))
        let originalData = Data("epub".utf8)
        try fileManager.createDirectory(at: repository.booksDirectory, withIntermediateDirectories: true)
        try originalData.write(to: storedURL)
        try repository.save(book)

        failingFileSystem.failLibraryReplacement = true

        do {
            try repository.delete(book)
            #expect(Bool(false))
        } catch {
            #expect(error is TestFileSystemError)
        }

        #expect(try repository.fetchAll() == [book])
        #expect(fileManager.fileExists(atPath: storedURL.path))
        #expect(try Data(contentsOf: storedURL) == originalData)
    }
}

struct readerWebKitIntegrationTests {
    @Test @MainActor func readerWKWebViewLoadsLocalCSSImageAndFontAndBlocksExternalResource() async throws {
        let fileManager = FileManager.default
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: rootDirectory) }

        try Data("body { color: rgb(10, 20, 30); }".utf8)
            .write(to: rootDirectory.appendingPathComponent("reader.css"))
        try #require(onePixelPNGData()).write(to: rootDirectory.appendingPathComponent("pixel.png"))
        let fontSource = try #require(
            Bundle(for: ReaderWebKitTestBundleMarker.self)
                .url(forResource: "ReaderTestFont", withExtension: "ttf")
        )
        try Data(contentsOf: fontSource)
            .write(to: rootDirectory.appendingPathComponent("reader-font.ttf"))

        let rawHTML = """
        <!doctype html>
        <html><head>
            <link rel="stylesheet" type="text/css" href="reader.css">
            <style>@font-face { font-family: LocalReaderFont; src: url('reader-font.ttf'); }</style>
        </head><body>
            <img id="local-image" src="pixel.png">
            <img id="external-image" src="https://example.com/remote.png">
            <p style="font-family: LocalReaderFont">Local font</p>
        </body></html>
        """
        let policy = try #require(try? ReaderSecurityPolicy.make().get())
        let securedHTML = try ReaderHTMLSecurity.securedData(
            from: Data(rawHTML.utf8),
            policy: policy
        )
        let chapterURL = rootDirectory.appendingPathComponent("chapter.html")
        try securedHTML.write(to: chapterURL)

        let waiter = ReaderWebKitLoadWaiter()
        let coordinator = ReaderWebViewCoordinator(onFinish: { waiter.succeed() })
        let webView = makeReaderWebView(coordinator: coordinator)
        try await waiter.wait(
            coordinator: coordinator,
            webView: webView,
            documentURL: chapterURL,
            readAccessDirectory: rootDirectory
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let result = try await webView.evaluateJavaScript("""
        (function() {
            const body = document.querySelector('body');
            const localImage = document.querySelector('#local-image');
            const externalImage = document.querySelector('#external-image');
            return JSON.stringify({
                css: body != null && getComputedStyle(body).color === 'rgb(10, 20, 30)',
                image: localImage != null && localImage.complete && localImage.naturalWidth > 0,
                font: document.fonts != null && document.fonts.check('16px LocalReaderFont'),
                external: externalImage != null && externalImage.naturalWidth === 0
            });
        })()
        """) as? String
        let resultString = try #require(result)
        let resultData = try #require(resultString.data(using: .utf8))
        let checks = try #require(try JSONSerialization.jsonObject(with: resultData) as? [String: Bool])
        #expect(checks["css"] == true)
        #expect(checks["image"] == true)
        #expect(checks["font"] == true)
        #expect(checks["external"] == true)
    }

    @Test @MainActor func readerWKWebViewBlocksExternalNavigationAndRedirect() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let chapterURL = rootDirectory.appendingPathComponent("chapter.xhtml")
        try Data("<html><body>Local</body></html>".utf8).write(to: chapterURL)

        let waiter = ReaderWebKitLoadWaiter()
        let coordinator = ReaderWebViewCoordinator(onFinish: { waiter.succeed() })
        let webView = makeReaderWebView(coordinator: coordinator)
        try await waiter.wait(
            coordinator: coordinator,
            webView: webView,
            documentURL: chapterURL,
            readAccessDirectory: rootDirectory
        )
        let localURL = try #require(webView.url)

        let externalURL = try #require(URL(string: "https://example.com/reader.xhtml"))
        webView.load(URLRequest(url: externalURL))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(webView.url == localURL)

        let redirectURL = rootDirectory.appendingPathComponent("redirect.xhtml")
        try Data("<meta http-equiv=\"refresh\" content=\"0;url=https://example.com/redirected\"><p>Redirect</p>".utf8)
            .write(to: redirectURL)
        let redirectWaiter = ReaderWebKitLoadWaiter()
        let redirectCoordinator = ReaderWebViewCoordinator(onFinish: { redirectWaiter.succeed() })
        let redirectWebView = makeReaderWebView(coordinator: redirectCoordinator)
        try await redirectWaiter.wait(
            coordinator: redirectCoordinator,
            webView: redirectWebView,
            documentURL: redirectURL,
            readAccessDirectory: rootDirectory
        )
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(redirectWebView.url?.isFileURL == true)
    }

    @Test @MainActor func readerWKWebViewRejectsExternalHTTPServerRedirect() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let chapterURL = rootDirectory.appendingPathComponent("chapter.xhtml")
        try Data("<html><body>Local</body></html>".utf8).write(to: chapterURL)

        let server = try LocalHTTPRedirectServer()
        defer { server.stop() }

        let initialWaiter = ReaderWebKitLoadWaiter()
        let redirectWaiter = ReaderWebKitFailureWaiter()
        var didReceiveServerRedirect = false
        let coordinator = ReaderWebViewCoordinator(
            securityPolicyProvider: {
                .success(
                    ReaderSecurityPolicy(
                        contentSecurityPolicy: "default-src 'self'",
                        encodedContentRuleList: "[{\"trigger\":{\"url-filter\":\"^https?://nonexistent.invalid/\"},\"action\":{\"type\":\"block\"}}]"
                    )
                )
            },
            navigationPolicy: { url, readAccessDirectory in
                if url.scheme == "http",
                   url.host == "127.0.0.1",
                   url.port == Int(server.port) {
                    return true
                }
                return ReaderNavigationPolicy.allowsNavigation(url, inside: readAccessDirectory)
            },
            onFinish: { initialWaiter.succeed() },
            onServerRedirect: { didReceiveServerRedirect = true }
        )
        let webView = makeReaderWebView(coordinator: coordinator)
        try await initialWaiter.wait(
            coordinator: coordinator,
            webView: webView,
            documentURL: chapterURL,
            readAccessDirectory: rootDirectory
        )

        coordinator.prepareToLoad(
            webView: webView,
            documentURL: chapterURL,
            readAccessDirectory: rootDirectory,
            onFailure: { message in
                redirectWaiter.fail(message)
            }
        )
        webView.load(URLRequest(url: server.redirectURL))

        let failureMessage = await redirectWaiter.wait()
        #expect(server.didReceiveRequest)
        #expect(didReceiveServerRedirect)
        #expect(failureMessage == "External redirects are not allowed.")
        #expect(webView.url?.isFileURL == true || webView.url == nil)
    }

    @Test @MainActor func readerWKWebViewFailsClosedWhenContentRuleListCompilationFails() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let chapterURL = rootDirectory.appendingPathComponent("chapter.xhtml")
        try Data("<html><body>Must not load</body></html>".utf8).write(to: chapterURL)

        let invalidPolicy = ReaderSecurityPolicy(
            contentSecurityPolicy: "default-src 'self'",
            encodedContentRuleList: "not-json"
        )
        let waiter = ReaderWebKitLoadWaiter()
        let coordinator = ReaderWebViewCoordinator(
            securityPolicyProvider: { .success(invalidPolicy) },
            onFinish: { waiter.succeed() }
        )
        let webView = makeReaderWebView(coordinator: coordinator)

        do {
            try await waiter.wait(
                coordinator: coordinator,
                webView: webView,
                documentURL: chapterURL,
                readAccessDirectory: rootDirectory
            )
            #expect(Bool(false))
        } catch {
            #expect(error is ReaderWebKitTestError)
        }
        #expect(webView.url == nil)
    }

    @Test @MainActor func readerWKWebViewFailureAndRetryUseRealNavigationCallbacks() async throws {
        let rootDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: rootDirectory) }
        let missingURL = rootDirectory.appendingPathComponent("missing.xhtml")

        let failureWaiter = ReaderWebKitLoadWaiter()
        let failureCoordinator = ReaderWebViewCoordinator(onFinish: { failureWaiter.succeed() })
        let failureWebView = makeReaderWebView(coordinator: failureCoordinator)
        do {
            try await failureWaiter.wait(
                coordinator: failureCoordinator,
                webView: failureWebView,
                documentURL: missingURL,
                readAccessDirectory: rootDirectory
            )
            #expect(Bool(false))
        } catch {
            #expect(error is ReaderWebKitTestError)
        }

        let validURL = rootDirectory.appendingPathComponent("retry.xhtml")
        try Data("<html><body>Recovered</body></html>".utf8).write(to: validURL)
        let retryWaiter = ReaderWebKitLoadWaiter()
        let retryCoordinator = ReaderWebViewCoordinator(onFinish: { retryWaiter.succeed() })
        let retryWebView = makeReaderWebView(coordinator: retryCoordinator)
        try await retryWaiter.wait(
            coordinator: retryCoordinator,
            webView: retryWebView,
            documentURL: validURL,
            readAccessDirectory: rootDirectory
        )
        #expect(retryWebView.url?.isFileURL == true)
        let body = try await retryWebView.evaluateJavaScript("document.documentElement.textContent") as? String
        #expect(body?.contains("Recovered") == true)
    }
}

private enum ReaderWebKitTestError: Error {
    case failed(String)
}

private enum LocalHTTPServerError: Error {
    case failedToStart
}

private final class LocalHTTPRedirectServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "peekturn.reader-tests.http-server")
    private let readySemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedPort: UInt16 = 0
    private var receivedRequest = false

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port?.rawValue {
                    self.lock.lock()
                    self.storedPort = port
                    self.lock.unlock()
                }
                self.readySemaphore.signal()
            case .failed, .cancelled:
                self.readySemaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard readySemaphore.wait(timeout: .now() + 5) == .success,
              port != 0 else {
            listener.cancel()
            throw LocalHTTPServerError.failedToStart
        }
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return storedPort
    }

    var redirectURL: URL {
        URL(string: "http://127.0.0.1:\(port)/redirect")!
    }

    private var externalURL: URL {
        URL(string: "http://127.0.0.1:\(port)/external")!
    }

    var didReceiveRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return receivedRequest
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self, weak connection] _, _, _, _ in
            guard let self, let connection else { return }
            self.lock.lock()
            self.receivedRequest = true
            self.lock.unlock()

            let response = Data(
                "HTTP/1.1 302 Found\r\nLocation: \(externalURL.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8
            )
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}

@MainActor
private final class ReaderWebKitLoadWaiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private var isComplete = false

    func wait(
        coordinator: ReaderWebViewCoordinator,
        webView: WKWebView,
        documentURL: URL,
        readAccessDirectory: URL
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            self.isComplete = false
            coordinator.prepareToLoad(
                webView: webView,
                documentURL: documentURL,
                readAccessDirectory: readAccessDirectory,
                onFailure: { [weak self] message in
                    self?.fail(message)
                }
            )
        }
    }

    func succeed() {
        guard !isComplete else { return }
        isComplete = true
        continuation?.resume()
        continuation = nil
    }

    private func fail(_ message: String) {
        guard !isComplete else { return }
        isComplete = true
        continuation?.resume(throwing: ReaderWebKitTestError.failed(message))
        continuation = nil
    }
}

@MainActor
private final class ReaderWebKitFailureWaiter {
    private var continuation: CheckedContinuation<String, Never>?
    private var message: String?

    func wait() async -> String {
        if let message {
            return message
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func fail(_ message: String) {
        guard self.message == nil else { return }
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: message)
        } else {
            self.message = message
        }
    }
}

private final class ReaderWebKitTestBundleMarker {}

@MainActor
private func makeReaderWebView(coordinator: ReaderWebViewCoordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.userContentController = WKUserContentController()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    return webView
}

private func onePixelPNGData() -> Data? {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
}

private final class FailingBookRepositoryFileSystem: BookRepositoryFileSystem {
    private let fileManager = FileManager.default

    var failingRemovalPaths = Set<String>()
    var failTemporaryLibraryWrite = false
    var failLibraryReplacement = false

    func fileExists(atPath path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: createIntermediates)
    }

    func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        if failTemporaryLibraryWrite,
           url.lastPathComponent.hasPrefix(".library-"),
           url.pathExtension == "tmp" {
            throw TestFileSystemError.writeFailed
        }
        try data.write(to: url, options: options)
    }

    func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try fileManager.copyItem(at: srcURL, to: dstURL)
    }

    func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if failLibraryReplacement,
           srcURL.lastPathComponent.hasPrefix(".library-"),
           srcURL.pathExtension == "tmp",
           dstURL.lastPathComponent == "library.json" {
            throw TestFileSystemError.moveFailed
        }
        try fileManager.moveItem(at: srcURL, to: dstURL)
    }

    func removeItem(at url: URL) throws {
        if failingRemovalPaths.contains(url.standardizedFileURL.path) {
            throw TestFileSystemError.removeFailed
        }
        try fileManager.removeItem(at: url)
    }
}

private enum TestFileSystemError: Error {
    case removeFailed
    case writeFailed
    case moveFailed
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

private func makeReadableEPUBData() -> Data {
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
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <manifest>
            <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="style" href="Styles/book.css" media-type="text/css"/>
        </manifest>
        <spine>
            <itemref idref="chapter"/>
        </spine>
    </package>
    """.data(using: .utf8)!

    let chapter = """
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
            <title>The First Chapter</title>
            <link rel="stylesheet" type="text/css" href="../Styles/book.css"/>
        </head>
        <body>
            <h1>The First Chapter</h1>
            <p>Original EPUB content.</p>
        </body>
    </html>
    """.data(using: .utf8)!

    return makeStoredZIP(entries: [
        ("mimetype", Data("application/epub+zip".utf8)),
        ("META-INF/container.xml", containerXML),
        ("OEBPS/content.opf", packageXML),
        ("OEBPS/Text/chapter.xhtml", chapter),
        ("OEBPS/Styles/book.css", Data("body { color: black; }".utf8))
    ])
}

private func writeReaderEPUB(
    packagePath: String = "OEBPS/content.opf",
    packageXML: String,
    resources: [(String, String)] = [],
    binaryResources: [(String, Data)] = [],
    mimetype: String = "application/epub+zip"
) throws -> URL {
    let rootDirectory = try makeTemporaryDirectory()
    let epubURL = rootDirectory.appendingPathComponent("reader.epub")
    try makeReaderEPUBData(
        packagePath: packagePath,
        packageXML: packageXML,
        resources: resources,
        binaryResources: binaryResources,
        mimetype: mimetype
    ).write(to: epubURL)
    return epubURL
}

private func makeReaderEPUBData(
    packagePath: String = "OEBPS/content.opf",
    packageXML: String,
    resources: [(String, String)] = [],
    binaryResources: [(String, Data)] = [],
    mimetype: String = "application/epub+zip"
) -> Data {
    let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles>
            <rootfile full-path="\(packagePath)" media-type="application/oebps-package+xml"/>
        </rootfiles>
    </container>
    """.data(using: .utf8)!

    let packageEntryPath = packagePath.removingPercentEncoding ?? packagePath
    var entries: [(String, Data)] = [
        ("mimetype", Data(mimetype.utf8)),
        ("META-INF/container.xml", containerXML),
        (packageEntryPath, Data(packageXML.utf8))
    ]
    entries.append(contentsOf: resources.map { ($0.0, Data($0.1.utf8)) })
    entries.append(contentsOf: binaryResources)
    return makeStoredZIP(entries: entries)
}

@MainActor
private func waitForReaderState(
    _ viewModel: ReaderViewModel,
    until predicate: (ReaderViewModel.State) -> Bool
) async throws {
    for _ in 0..<100 {
        if predicate(viewModel.state) {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(predicate(viewModel.state))
}

private func replacingFirstCentralDirectoryUncompressedSize(in data: Data, with size: UInt32) -> Data {
    var result = data
    for offset in 0..<(result.count - 46) {
        guard result[offset] == 0x50,
              result[offset + 1] == 0x4b,
              result[offset + 2] == 0x01,
              result[offset + 3] == 0x02 else {
            continue
        }

        result[offset + 24] = UInt8(size & 0xff)
        result[offset + 25] = UInt8((size >> 8) & 0xff)
        result[offset + 26] = UInt8((size >> 16) & 0xff)
        result[offset + 27] = UInt8((size >> 24) & 0xff)
        break
    }
    return result
}

private func replacingFirstCentralDirectoryField(in data: Data, fieldOffset: Int, with value: UInt16) -> Data {
    var result = data
    for offset in 0..<(result.count - 46) {
        guard result[offset] == 0x50,
              result[offset + 1] == 0x4b,
              result[offset + 2] == 0x01,
              result[offset + 3] == 0x02 else {
            continue
        }

        result[offset + fieldOffset] = UInt8(value & 0xff)
        result[offset + fieldOffset + 1] = UInt8((value >> 8) & 0xff)
        break
    }
    return result
}

private func replacingEOCDCentralDirectory(
    in data: Data,
    entryCount: UInt16,
    centralDirectorySize: UInt32,
    centralDirectoryOffset: UInt32
) -> Data {
    var result = data
    let eocdOffset = result.count - 22
    replaceUInt16(entryCount, in: &result, at: eocdOffset + 8)
    replaceUInt16(entryCount, in: &result, at: eocdOffset + 10)
    replaceUInt32(centralDirectorySize, in: &result, at: eocdOffset + 12)
    replaceUInt32(centralDirectoryOffset, in: &result, at: eocdOffset + 16)
    return result
}

private func replacingFirstMimetypeCompressionMethod(in data: Data, with method: UInt16) -> Data {
    var result = data
    replaceUInt16(method, in: &result, at: 8)
    for offset in 0..<(result.count - 46) {
        guard result[offset] == 0x50,
              result[offset + 1] == 0x4b,
              result[offset + 2] == 0x01,
              result[offset + 3] == 0x02 else {
            continue
        }
        replaceUInt16(method, in: &result, at: offset + 10)
        break
    }
    return result
}

private func replacingFirstMimetypeExtraLength(in data: Data, with length: UInt16) -> Data {
    var result = data
    replaceUInt16(length, in: &result, at: 28)
    for offset in 0..<(result.count - 46) {
        guard result[offset] == 0x50,
              result[offset + 1] == 0x4b,
              result[offset + 2] == 0x01,
              result[offset + 3] == 0x02 else {
            continue
        }
        replaceUInt16(length, in: &result, at: offset + 30)
        break
    }
    return result
}

private func assertArchiveRejects(_ data: Data) {
    let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PeekturnArchiveTests-\(UUID().uuidString)", isDirectory: true)
    let archiveURL = rootDirectory.appendingPathComponent("invalid.epub")
    do {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try data.write(to: archiveURL)
        do {
            _ = try EPUBArchive(url: archiveURL, fileManager: .default)
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    } catch {
        #expect(Bool(false))
    }
    try? FileManager.default.removeItem(at: rootDirectory)
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    UInt32(data[offset]) |
        UInt32(data[offset + 1]) << 8 |
        UInt32(data[offset + 2]) << 16 |
        UInt32(data[offset + 3]) << 24
}

private func replaceUInt16(_ value: UInt16, in data: inout Data, at offset: Int) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
}

private func replaceUInt32(_ value: UInt32, in data: inout Data, at offset: Int) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
    data[offset + 2] = UInt8((value >> 16) & 0xff)
    data[offset + 3] = UInt8((value >> 24) & 0xff)
}

private func makeUTF16LEData(_ string: String) -> Data {
    var data = Data([0xff, 0xfe])
    for codeUnit in string.utf16 {
        data.append(UInt8(codeUnit & 0xff))
        data.append(UInt8((codeUnit >> 8) & 0xff))
    }
    return data
}

private func makeUTF16BEData(_ string: String) -> Data {
    var data = Data([0xfe, 0xff])
    data.append(contentsOf: makeUTF16BEDataWithoutBOM(string))
    return data
}

private func makeUTF16BEDataWithoutBOM(_ string: String) -> Data {
    var data = Data()
    for codeUnit in string.utf16 {
        data.append(UInt8((codeUnit >> 8) & 0xff))
        data.append(UInt8(codeUnit & 0xff))
    }
    return data
}

private func makeUTF16LEDataWithoutBOM(_ string: String) -> Data {
    var data = Data()
    for codeUnit in string.utf16 {
        data.append(UInt8(codeUnit & 0xff))
        data.append(UInt8((codeUnit >> 8) & 0xff))
    }
    return data
}

private func assertImporterRejects(_ data: Data) throws {
    let fileManager = FileManager.default
    let rootDirectory = try makeTemporaryDirectory()
    defer { try? fileManager.removeItem(at: rootDirectory) }

    let sourceURL = rootDirectory.appendingPathComponent("invalid-central-directory.epub")
    try data.write(to: sourceURL)
    let storageDirectory = rootDirectory.appendingPathComponent("PrivateBooks", isDirectory: true)
    let importer = BookImporter(storageDirectory: storageDirectory)

    do {
        _ = try importer.importBook(from: sourceURL)
        #expect(Bool(false))
    } catch {
        #expect(error as? BookImportError == .invalidEPUB)
    }
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
