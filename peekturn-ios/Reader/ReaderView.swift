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
                let loadID = viewModel.loadID
                EPUBWebView(
                    documentURL: document.mainDocumentURL,
                    readAccessDirectory: document.readAccessDirectory,
                    onFailure: { message in
                        viewModel.handleWebKitFailure(message, for: loadID)
                    }
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
    let onFailure: (String) -> Void

    func makeCoordinator() -> ReaderWebViewCoordinator {
        ReaderWebViewCoordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = WKUserContentController()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        context.coordinator.prepareToLoad(
            webView: webView,
            documentURL: documentURL,
            readAccessDirectory: readAccessDirectory,
            onFailure: onFailure
        )
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.prepareToLoad(
            webView: webView,
            documentURL: documentURL,
            readAccessDirectory: readAccessDirectory,
            onFailure: onFailure
        )
    }

}

final class ReaderWebViewCoordinator: NSObject, WKNavigationDelegate {
    private let securityPolicyProvider: () -> Result<ReaderSecurityPolicy, ReaderSecurityPolicyError>
    private let navigationPolicy: (URL, URL) -> Bool
    private let onFinish: () -> Void
    private let onServerRedirect: () -> Void
    private var hasStartedLoading = false
    private var hasRejectedServerRedirect = false
    private var readAccessDirectory: URL?
    private var onFailure: ((String) -> Void)?

    init(
        securityPolicyProvider: @escaping () -> Result<ReaderSecurityPolicy, ReaderSecurityPolicyError> = {
            ReaderSecurityPolicy.make()
        },
        navigationPolicy: @escaping (URL, URL) -> Bool = { url, readAccessDirectory in
            ReaderNavigationPolicy.allowsNavigation(url, inside: readAccessDirectory)
        },
        onFinish: @escaping () -> Void = {},
        onServerRedirect: @escaping () -> Void = {}
    ) {
        self.securityPolicyProvider = securityPolicyProvider
        self.navigationPolicy = navigationPolicy
        self.onFinish = onFinish
        self.onServerRedirect = onServerRedirect
        super.init()
    }

    func prepareToLoad(
        webView: WKWebView,
        documentURL: URL,
        readAccessDirectory: URL,
        onFailure: @escaping (String) -> Void
    ) {
        self.onFailure = onFailure
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        hasRejectedServerRedirect = false
        self.readAccessDirectory = readAccessDirectory

        guard case .success(let securityPolicy) = securityPolicyProvider() else {
            reportFailure("Reader security could not be initialized.")
            return
        }

        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "PeekturnReaderBlockExternalNetwork",
            encodedContentRuleList: securityPolicy.encodedContentRuleList
        ) { [weak self, weak webView] ruleList, error in
            DispatchQueue.main.async {
                guard let self, let webView else { return }
                guard let ruleList else {
                    self.reportFailure(
                        error?.localizedDescription ?? "Reader security could not be initialized."
                    )
                    return
                }
                webView.configuration.userContentController.add(ruleList)
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
            navigationPolicy(url, readAccessDirectory)
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
            navigationPolicy(url, readAccessDirectory)
                ? .allow
                : .cancel
        )
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard !hasRejectedServerRedirect else { return }
        reportFailure(error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard !hasRejectedServerRedirect else { return }
        reportFailure(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!
    ) {
        hasRejectedServerRedirect = true
        onServerRedirect()
        webView.stopLoading()
        reportFailure("External redirects are not allowed.")
    }

    private func reportFailure(_ message: String) {
        onFailure?(message)
    }
}
