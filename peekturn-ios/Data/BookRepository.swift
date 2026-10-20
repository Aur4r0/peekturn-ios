import Foundation

enum BookRepositoryError: LocalizedError, Equatable {
    case invalidLibraryData
    case invalidBookFileName

    var errorDescription: String? {
        switch self {
        case .invalidLibraryData:
            return "The local library could not be read."
        case .invalidBookFileName:
            return "The local book file name is invalid."
        }
    }
}

final class BookRepository {
    let rootDirectory: URL
    let booksDirectory: URL

    private let libraryFileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        rootDirectory: URL = BookRepository.defaultRootDirectory(),
        fileManager: FileManager = .default
    ) {
        self.rootDirectory = rootDirectory
        self.booksDirectory = rootDirectory.appendingPathComponent("Books", isDirectory: true)
        self.libraryFileURL = rootDirectory.appendingPathComponent("library.json", isDirectory: false)
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func fetchAll() throws -> [Book] {
        try prepareDirectories()

        guard fileManager.fileExists(atPath: libraryFileURL.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: libraryFileURL)
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
        try data.write(to: libraryFileURL, options: .atomic)
    }

    func delete(_ book: Book) throws {
        try prepareDirectories()
        try validateFileNameIfPresent(book.epubFileName)

        var books = try fetchAll()
        books.removeAll { $0.id == book.id }

        let data = try encoder.encode(books)
        try data.write(to: libraryFileURL, options: .atomic)

        if !book.epubFileName.isEmpty {
            let fileURL = booksDirectory.appendingPathComponent(book.epubFileName, isDirectory: false)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    func fileURL(for book: Book) throws -> URL? {
        try validateFileNameIfPresent(book.epubFileName)
        guard !book.epubFileName.isEmpty else {
            return nil
        }
        return booksDirectory.appendingPathComponent(book.epubFileName, isDirectory: false)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
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
