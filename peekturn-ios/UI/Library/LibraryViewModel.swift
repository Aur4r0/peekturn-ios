import Combine
import Foundation

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var books: [Book] = []
    @Published private(set) var errorMessage: String?

    private let repository: BookRepository
    private let importer: BookImporter

    init(repository: BookRepository, importer: BookImporter) {
        self.repository = repository
        self.importer = importer
        loadBooks()
    }

    func importBook(from url: URL) {
        do {
            let book = try importer.importBook(from: url)
            do {
                try repository.save(book)
            } catch {
                try? importer.removeImportedFile(for: book)
                throw error
            }
            books = try repository.fetchAll()
            errorMessage = nil
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func loadBooks() {
        do {
            books = try repository.fetchAll()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "The book could not be imported."
    }
}
