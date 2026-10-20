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
    mimetype: String = "application/epub+zip"
) throws -> URL {
    let rootDirectory = try makeTemporaryDirectory()
    let epubURL = rootDirectory.appendingPathComponent("reader.epub")
    try makeReaderEPUBData(
        packagePath: packagePath,
        packageXML: packageXML,
        resources: resources,
        mimetype: mimetype
    ).write(to: epubURL)
    return epubURL
}

private func makeReaderEPUBData(
    packagePath: String = "OEBPS/content.opf",
    packageXML: String,
    resources: [(String, String)] = [],
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
