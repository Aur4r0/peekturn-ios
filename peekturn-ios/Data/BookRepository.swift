import Foundation

enum BookRepositoryError: LocalizedError, Equatable {
    case invalidLibraryData
    case invalidBookFileName
    case transactionRecoveryFailed

    var errorDescription: String? {
        switch self {
        case .invalidLibraryData:
            return "The local library could not be read."
        case .invalidBookFileName:
            return "The local book file name is invalid."
        case .transactionRecoveryFailed:
            return "The local library could not be updated safely."
        }
    }
}

protocol BookRepositoryFileSystem {
    func fileExists(atPath path: String) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws
    func readData(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(at url: URL) throws
}

extension FileManager: BookRepositoryFileSystem {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: nil
        )
    }

    func readData(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }
}

final class BookRepository {
    let rootDirectory: URL
    let booksDirectory: URL

    private let libraryFileURL: URL
    private let fileSystem: BookRepositoryFileSystem
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootDirectory: URL = BookRepository.defaultRootDirectory(),
        fileSystem: BookRepositoryFileSystem = FileManager.default
    ) {
        self.rootDirectory = rootDirectory
        self.booksDirectory = rootDirectory.appendingPathComponent("Books", isDirectory: true)
        self.libraryFileURL = rootDirectory.appendingPathComponent("library.json", isDirectory: false)
        self.fileSystem = fileSystem

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func fetchAll() throws -> [Book] {
        try prepareDirectories()

        guard fileSystem.fileExists(atPath: libraryFileURL.path) else {
            return []
        }

        do {
            let data = try fileSystem.readData(from: libraryFileURL)
            return try decoder.decode([Book].self, from: data)
        } catch {
            throw BookRepositoryError.invalidLibraryData
        }
    }

    func save(_ book: Book) throws {
        try prepareDirectories()
        try validateFileNameIfPresent(book.epubFileName)

        var books = try fetchAll()
        if let existingIndex = books.firstIndex(where: { $0.id == book.id }) {
            books[existingIndex] = book
        } else {
            books.append(book)
        }

        let data = try encoder.encode(books)
        try fileSystem.write(data, to: libraryFileURL, options: .atomic)
    }

    func delete(_ book: Book) throws {
        try prepareDirectories()
        try validateFileNameIfPresent(book.epubFileName)

        var books = try fetchAll()
        books.removeAll { $0.id == book.id }

        let data = try encoder.encode(books)
        let transactionID = UUID().uuidString
        let temporaryLibraryURL = rootDirectory.appendingPathComponent(
            ".library-\(transactionID).tmp",
            isDirectory: false
        )
        let libraryBackupURL = rootDirectory.appendingPathComponent(
            ".library-\(transactionID).backup",
            isDirectory: false
        )
        let bookURL = book.epubFileName.isEmpty
            ? nil
            : booksDirectory.appendingPathComponent(book.epubFileName, isDirectory: false)
        let bookBackupURL = booksDirectory.appendingPathComponent(
            ".delete-\(transactionID).backup",
            isDirectory: false
        )

        let libraryWasPresent = fileSystem.fileExists(atPath: libraryFileURL.path)
        let bookWasPresent = bookURL.map { fileSystem.fileExists(atPath: $0.path) } ?? false

        do {
            if libraryWasPresent {
                try fileSystem.copyItem(at: libraryFileURL, to: libraryBackupURL)
            }
            if bookWasPresent, let bookURL {
                try fileSystem.copyItem(at: bookURL, to: bookBackupURL)
            }

            try fileSystem.write(data, to: temporaryLibraryURL, options: .atomic)

            if bookWasPresent, let bookURL {
                try fileSystem.removeItem(at: bookURL)
            }

            if libraryWasPresent {
                try fileSystem.removeItem(at: libraryFileURL)
            }
            try fileSystem.moveItem(at: temporaryLibraryURL, to: libraryFileURL)
        } catch {
            do {
                try recoverDeleteTransaction(
                    temporaryLibraryURL: temporaryLibraryURL,
                    libraryBackupURL: libraryBackupURL,
                    libraryWasPresent: libraryWasPresent,
                    bookURL: bookURL,
                    bookBackupURL: bookBackupURL,
                    bookWasPresent: bookWasPresent
                )
            } catch {
                throw BookRepositoryError.transactionRecoveryFailed
            }
            throw error
        }

        // The new library is already durable. Orphaned backups are harmless and
        // can be removed opportunistically without changing the committed state.
        removeIfPresent(temporaryLibraryURL)
        removeIfPresent(libraryBackupURL)
        removeIfPresent(bookBackupURL)
    }

    func fileURL(for book: Book) throws -> URL? {
        try validateFileNameIfPresent(book.epubFileName)
        guard !book.epubFileName.isEmpty else {
            return nil
        }
        return booksDirectory.appendingPathComponent(book.epubFileName, isDirectory: false)
    }

    private func prepareDirectories() throws {
        try fileSystem.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileSystem.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
    }

    private func recoverDeleteTransaction(
        temporaryLibraryURL: URL,
        libraryBackupURL: URL,
        libraryWasPresent: Bool,
        bookURL: URL?,
        bookBackupURL: URL,
        bookWasPresent: Bool
    ) throws {
        removeIfPresent(temporaryLibraryURL)

        if libraryWasPresent {
            if !fileSystem.fileExists(atPath: libraryFileURL.path),
               fileSystem.fileExists(atPath: libraryBackupURL.path) {
                try fileSystem.moveItem(at: libraryBackupURL, to: libraryFileURL)
            } else {
                removeIfPresent(libraryBackupURL)
            }
        } else {
            removeIfPresent(libraryFileURL)
            removeIfPresent(libraryBackupURL)
        }

        if bookWasPresent, let bookURL {
            if fileSystem.fileExists(atPath: bookURL.path) {
                removeIfPresent(bookBackupURL)
            } else if fileSystem.fileExists(atPath: bookBackupURL.path) {
                try fileSystem.moveItem(at: bookBackupURL, to: bookURL)
            }
        } else {
            removeIfPresent(bookBackupURL)
        }
    }

    private func removeIfPresent(_ url: URL) {
        guard fileSystem.fileExists(atPath: url.path) else { return }
        try? fileSystem.removeItem(at: url)
    }

    private func validateFileNameIfPresent(_ fileName: String) throws {
        guard fileName.isEmpty || isSinglePathComponent(fileName) else {
            throw BookRepositoryError.invalidBookFileName
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

    private static func defaultRootDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupport.appendingPathComponent("Peekturn", isDirectory: true)
    }
}
