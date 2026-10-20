import SwiftUI

struct ContentView: View {
    private let repository: BookRepository
    @StateObject private var viewModel: LibraryViewModel
    @State private var navigationState = ReaderNavigationState()

    init() {
        let repository = BookRepository()
        self.repository = repository
        let importer = BookImporter(storageDirectory: repository.booksDirectory)
        _viewModel = StateObject(wrappedValue: LibraryViewModel(repository: repository, importer: importer))
    }

    var body: some View {
        LibraryView(
            books: viewModel.books,
            errorMessage: viewModel.errorMessage,
            onImportURL: { url in
                viewModel.importBook(from: url)
            },
            onOpenBook: { book in
                navigationState.open(book: book)
            },
            onDismissError: {
                viewModel.clearError()
            }
        )
        .sheet(
            item: Binding(
                get: { navigationState.selectedBook },
                set: { selectedBook in
                    if selectedBook == nil {
                        navigationState.returnToLibrary()
                    }
                }
            )
        ) { book in
            NavigationStack {
                ReaderView(book: book, repository: repository)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
