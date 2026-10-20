import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel: LibraryViewModel

    init() {
        let repository = BookRepository()
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
            onDismissError: {
                viewModel.clearError()
            }
        )
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
