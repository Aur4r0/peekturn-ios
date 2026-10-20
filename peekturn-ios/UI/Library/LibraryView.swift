import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let books: [Book]
    let errorMessage: String?
    let onImportURL: (URL) -> Void
    let onOpenBook: (Book) -> Void
    let onDismissError: () -> Void

    @State private var isFileImporterPresented = false

    init(
        books: [Book] = [],
        errorMessage: String? = nil,
        onImportURL: @escaping (URL) -> Void = { _ in },
        onOpenBook: @escaping (Book) -> Void = { _ in },
        onDismissError: @escaping () -> Void = {}
    ) {
        self.books = books
        self.errorMessage = errorMessage
        self.onImportURL = onImportURL
        self.onOpenBook = onOpenBook
        self.onDismissError = onDismissError
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    LibraryEmptyState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(books) { book in
                        Button {
                            onOpenBook(book)
                        } label: {
                            BookRow(book: book)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("book-row-\(book.id.uuidString)")
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(PeekturnTheme.pageBackground)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Label("Import EPUB", systemImage: "plus")
                    }
                    .accessibilityIdentifier("import-epub-button")
                }
            }
        }
        .tint(.accentColor)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [BookImporter.supportedContentType],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else {
                return
            }
            onImportURL(url)
        }
        .alert(
            "Import failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        onDismissError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                onDismissError()
            }
        } message: {
            Text(errorMessage ?? "The book could not be imported.")
        }
    }
}

private struct BookRow: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: PeekturnTheme.Spacing.compact) {
            Text(book.title)
                .font(.headline)
                .lineLimit(nil)

            Text(book.author)
                .font(.subheadline)
                .foregroundStyle(PeekturnTheme.secondaryText)
                .lineLimit(nil)

            HStack(spacing: PeekturnTheme.Spacing.compact) {
                ProgressView(value: book.progress)
                Text("\(Int(book.progress * 100))% read")
                    .font(.caption)
                    .foregroundStyle(PeekturnTheme.secondaryText)
            }
        }
        .padding(.vertical, PeekturnTheme.Spacing.compact)
    }
}

struct LibraryView_Previews: PreviewProvider {
    static var previews: some View {
        LibraryView()
    }
}
