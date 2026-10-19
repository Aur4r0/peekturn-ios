import SwiftUI

struct LibraryView: View {
    let books: [Book]

    init(books: [Book] = []) {
        self.books = books
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    LibraryEmptyState()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(books) { book in
                        VStack(alignment: .leading, spacing: PeekturnTheme.Spacing.compact) {
                            Text(book.title)
                                .font(.headline)
                            Text(book.author)
                                .font(.subheadline)
                                .foregroundStyle(PeekturnTheme.secondaryText)
                        }
                        .padding(.vertical, PeekturnTheme.Spacing.compact)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(PeekturnTheme.pageBackground)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
        }
        .tint(.accentColor)
    }
}

#Preview {
    LibraryView()
}
