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
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.prepareToLoad(
            webView: webView,
            documentURL: documentURL,
            readAccessDirectory: readAccessDirectory
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.prepareToLoad(
            webView: webView,
            documentURL: documentURL,
            readAccessDirectory: readAccessDirectory
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var hasStartedLoading = false
        private var readAccessDirectory: URL?

        func prepareToLoad(webView: WKWebView, documentURL: URL, readAccessDirectory: URL) {
            guard !hasStartedLoading else { return }
            hasStartedLoading = true
            self.readAccessDirectory = readAccessDirectory

            let encodedRules = """
            [{"trigger":{"url-filter":"^https?://","resource-type":["document","image","style-sheet","script","font","media","svg-document","raw","popup"]},"action":{"type":"block"}}]
            """
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "PeekturnReaderBlockExternalNetwork",
                encodedContentRuleList: encodedRules
            ) { [weak self, weak webView] ruleList, _ in
                DispatchQueue.main.async {
                    guard let self, let webView else { return }
                    if let ruleList {
                        webView.configuration.userContentController.add(ruleList)
                    }
                    webView.loadFileURL(
                        documentURL,
                        allowingReadAccessTo: readAccessDirectory
                    )
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let readAccessDirectory else {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(
                ReaderNavigationPolicy.allowsNavigation(url, inside: readAccessDirectory)
                    ? .allow
                    : .cancel
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            guard let url = navigationResponse.response.url,
                  let readAccessDirectory else {
                decisionHandler(.cancel)
                return
            }

            decisionHandler(
                ReaderNavigationPolicy.allowsResourceRequest(url, inside: readAccessDirectory)
                    ? .allow
                    : .cancel
            )
        }

        func webView(
            _ webView: WKWebView,
            didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
        ) {
            webView.stopLoading()
        }
    }
}
