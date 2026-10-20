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
    case invalidEncoding
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
        var html = try decodeHTML(data)
        html = normalizeXMLDeclaration(in: html)

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

    private nonisolated static func decodeHTML(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) {
            guard let html = String(data: data, encoding: .utf16LittleEndian) else {
                throw ReaderHTMLSecurityError.invalidEncoding
            }
            return html.hasPrefix("\u{FEFF}") ? String(html.dropFirst()) : html
        }

        if data.starts(with: [0xFE, 0xFF]) {
            guard let html = String(data: data, encoding: .utf16BigEndian) else {
                throw ReaderHTMLSecurityError.invalidEncoding
            }
            return html.hasPrefix("\u{FEFF}") ? String(html.dropFirst()) : html
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ReaderHTMLSecurityError.invalidEncoding
        }
        let htmlWithoutBOM = html.hasPrefix("\u{FEFF}") ? String(html.dropFirst()) : html
        guard hasSupportedXMLDeclarationEncoding(in: htmlWithoutBOM) else {
            throw ReaderHTMLSecurityError.invalidEncoding
        }
        return htmlWithoutBOM
    }

    private nonisolated static func hasSupportedXMLDeclarationEncoding(in html: String) -> Bool {
        guard let declarationRange = html.range(
            of: "^\\s*<\\?xml\\b.*?\\?>",
            options: [.caseInsensitive, .regularExpression]
        ) else {
            return true
        }

        let declaration = String(html[declarationRange])
        guard let encodingRange = declaration.range(
            of: "encoding\\s*=\\s*[\"']([^\"']+)[\"']",
            options: [.caseInsensitive, .regularExpression]
        ) else {
            return true
        }
        let encoding = declaration[encodingRange]
            .split(separator: "=", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        return encoding == "utf-8" || encoding == "utf8"
    }

    private nonisolated static func normalizeXMLDeclaration(in html: String) -> String {
        guard let declarationRange = html.range(
            of: "^\\s*<\\?xml\\b.*?\\?>",
            options: [.caseInsensitive, .regularExpression]
        ) else {
            return html
        }

        let declaration = String(html[declarationRange])
        let normalizedDeclaration = declaration.replacingOccurrences(
            of: "(encoding\\s*=\\s*[\"'])[^\"']+([\"'])",
            with: "$1UTF-8$2",
            options: [.caseInsensitive, .regularExpression]
        )
        return html.replacingCharacters(in: declarationRange, with: normalizedDeclaration)
    }
}
