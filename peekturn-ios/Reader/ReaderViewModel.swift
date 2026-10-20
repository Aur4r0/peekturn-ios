import Combine
import Foundation

@MainActor
final class ReaderViewModel: ObservableObject {
    enum State {
        case loading
        case loaded(EPUBReadingDocument)
        case failed(String)
    }

    @Published private(set) var state: State = .loading

    let book: Book

    private let repository: BookRepository
    private var loadTask: Task<Void, Never>?
    private var readingDocument: EPUBReadingDocument?

    init(book: Book, repository: BookRepository) {
        self.book = book
        self.repository = repository
        load()
    }

    func load() {
        stop()
        state = .loading

        let epubURL: URL?
        do {
            epubURL = try repository.fileURL(for: book)
        } catch {
            state = .failed(Self.userFacingMessage(for: error))
            return
        }

        guard let epubURL else {
            state = .failed("This book file is unavailable.")
            return
        }

        loadTask = Task { [weak self] in
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try EPUBBookReader().prepareReadingDocument(from: epubURL)
                }.value

                guard !Task.isCancelled else {
                    document.removeTemporaryFiles()
                    return
                }

                self?.readingDocument = document
                self?.state = .loaded(document)
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(Self.userFacingMessage(for: error))
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        readingDocument?.removeTemporaryFiles()
        readingDocument = nil
    }

    deinit {
        loadTask?.cancel()
        readingDocument?.removeTemporaryFiles()
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return "This book could not be opened."
    }
}
