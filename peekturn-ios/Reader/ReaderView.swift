import SwiftUI
import WebKit

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: ReaderViewModel

    init(book: Book, repository: BookRepository) {
        _viewModel = StateObject(wrappedValue: ReaderViewModel(book: book, repository: repository))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                VStack(spacing: PeekturnTheme.Spacing.section) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Opening book…")
                        .font(.headline)
                        .foregroundStyle(PeekturnTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("reader-loading-state")
            case .loaded(let document):
                EPUBWebView(
                    documentURL: document.mainDocumentURL,
                    readAccessDirectory: document.readAccessDirectory
                )
                .accessibilityIdentifier("epub-reader-webview")
            case .failed(let message):
                VStack(spacing: PeekturnTheme.Spacing.section) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.orange)

                    VStack(spacing: PeekturnTheme.Spacing.compact) {
                        Text("Unable to open book")
                            .font(.title2.weight(.semibold))
                        Text(message)
                            .font(.body)
                            .foregroundStyle(PeekturnTheme.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Try Again") {
                        viewModel.load()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("reader-retry-button")
                }
                .padding(PeekturnTheme.Spacing.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("reader-error-state")
            }
        }
        .background(PeekturnTheme.pageBackground)
        .navigationTitle(viewModel.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Library") {
                    dismiss()
                }
                .accessibilityIdentifier("reader-back-button")
            }
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}

private struct EPUBWebView: UIViewRepresentable {
    let documentURL: URL
    let readAccessDirectory: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        loadDocument(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        loadDocument(in: webView, coordinator: context.coordinator)
    }

    private func loadDocument(in webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.loadedURL != documentURL else { return }
        coordinator.loadedURL = documentURL
        webView.loadFileURL(documentURL, allowingReadAccessTo: readAccessDirectory)
    }

    final class Coordinator {
        var loadedURL: URL?
    }
}
