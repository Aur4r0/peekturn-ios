import Foundation

enum ReaderHTMLSecurity {
    static let contentSecurityPolicy = "default-src 'self'; img-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; media-src 'self'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    static func securedData(from data: Data) -> Data {
        guard var html = String(data: data, encoding: .utf8) else {
            return data
        }

        let metaTag = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\" />"
        if let headEnd = html.range(of: "</head>", options: .caseInsensitive) {
            html.insert(contentsOf: metaTag, at: headEnd.lowerBound)
        } else {
            html.insert(contentsOf: metaTag, at: html.startIndex)
        }
        return Data(html.utf8)
    }
}
