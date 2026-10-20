import Foundation

struct ReaderNavigationState: Equatable {
    private(set) var selectedBook: Book?

    var isReaderPresented: Bool {
        selectedBook != nil
    }

    mutating func open(book: Book) {
        selectedBook = book
    }

    mutating func returnToLibrary() {
        selectedBook = nil
    }
}
