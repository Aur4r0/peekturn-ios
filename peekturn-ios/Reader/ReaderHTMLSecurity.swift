import Foundation

enum ReaderSecurityPolicyError: Error, Equatable, Sendable {
    case invalidContentRuleList
}

struct ReaderSecurityPolicy: Equatable, Sendable {
    let contentSecurityPolicy: String
    let encodedContentRuleList: String

    nonisolated static func make(
        encodedContentRuleList: String = ReaderHTMLSecurity.encodedContentRuleList
    ) -> Result<ReaderSecurityPolicy, ReaderSecurityPolicyError> {
        guard let data = encodedContentRuleList.data(using: .utf8),
              let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !rules.isEmpty else {
            return .failure(.invalidContentRuleList)
        }

        return .success(
            ReaderSecurityPolicy(
                contentSecurityPolicy: ReaderHTMLSecurity.contentSecurityPolicy,
                encodedContentRuleList: encodedContentRuleList
            )
        )
    }
}

enum ReaderHTMLSecurityError: Error, Equatable, Sendable {
    case invalidUTF8
}

enum ReaderHTMLSecurity {
    nonisolated static let contentSecurityPolicy = "default-src 'self'; img-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; media-src 'self'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"

    nonisolated static let encodedContentRuleList = """
    [{"trigger":{"url-filter":"^https?://","resource-type":["document","image","style-sheet","script","font","media","svg-document","raw","popup"]},"action":{"type":"block"}}]
    """

    nonisolated static func securedData(
        from data: Data,
        policy: ReaderSecurityPolicy
    ) throws -> Data {
        guard var html = String(data: data, encoding: .utf8) else {
            throw ReaderHTMLSecurityError.invalidUTF8
        }

        let metaTag = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy.contentSecurityPolicy)\" />"
        if let headStart = html.range(of: "<head[^>]*>", options: [.caseInsensitive, .regularExpression]) {
            html.insert(contentsOf: metaTag, at: headStart.upperBound)
        } else if let htmlStart = html.range(of: "<html[^>]*>", options: [.caseInsensitive, .regularExpression]) {
            let securedHead = "<head>\(metaTag)</head>"
            html.insert(contentsOf: securedHead, at: htmlStart.upperBound)
        } else {
            html = "<!doctype html><html><head>\(metaTag)</head><body>\(html)</body></html>"
        }
        return Data(html.utf8)
    }
}
