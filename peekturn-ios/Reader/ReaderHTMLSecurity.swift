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

    private enum HTMLTextEncoding {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
    }

    private nonisolated static func decodeHTML(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        let (encoding, payload): (HTMLTextEncoding, Data)
        if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian
            payload = Data(data.dropFirst(2))
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian
            payload = Data(data.dropFirst(2))
        } else if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8
            payload = Data(data.dropFirst(3))
        } else if bytes.count >= 4, bytes[1] == 0, bytes[3] == 0 {
            encoding = .utf16LittleEndian
            payload = data
        } else if bytes.count >= 4, bytes[0] == 0, bytes[2] == 0 {
            encoding = .utf16BigEndian
            payload = data
        } else {
            encoding = .utf8
            payload = data
        }

        let stringEncoding: String.Encoding
        switch encoding {
        case .utf8:
            stringEncoding = .utf8
        case .utf16LittleEndian:
            stringEncoding = .utf16LittleEndian
        case .utf16BigEndian:
            stringEncoding = .utf16BigEndian
        }
        guard let decoded = String(data: payload, encoding: stringEncoding) else {
            throw ReaderHTMLSecurityError.invalidEncoding
        }
        let html = decoded.hasPrefix("\u{FEFF}") ? String(decoded.dropFirst()) : decoded
        guard isCompatibleXMLDeclarationEncoding(in: html, with: encoding) else {
            throw ReaderHTMLSecurityError.invalidEncoding
        }
        return html
    }

    private nonisolated static func isCompatibleXMLDeclarationEncoding(
        in html: String,
        with encoding: HTMLTextEncoding
    ) -> Bool {
        guard let declaredEncoding = xmlDeclarationEncoding(in: html) else {
            return true
        }

        switch encoding {
        case .utf8:
            return declaredEncoding == "utf-8" || declaredEncoding == "utf8"
        case .utf16LittleEndian:
            return declaredEncoding == "utf-16" ||
                declaredEncoding == "utf16" ||
                declaredEncoding == "utf-16le" ||
                declaredEncoding == "utf16le"
        case .utf16BigEndian:
            return declaredEncoding == "utf-16" ||
                declaredEncoding == "utf16" ||
                declaredEncoding == "utf-16be" ||
                declaredEncoding == "utf16be"
        }
    }

    private nonisolated static func xmlDeclarationEncoding(in html: String) -> String? {
        guard let declarationRange = html.range(
            of: "^\\s*<\\?xml\\b.*?\\?>",
            options: [.caseInsensitive, .regularExpression]
        ) else {
            return nil
        }

        let declaration = String(html[declarationRange])
        guard let encodingRange = declaration.range(
            of: "encoding\\s*=\\s*[\"']([^\"']+)[\"']",
            options: [.caseInsensitive, .regularExpression]
        ) else {
            return nil
        }
        let encoding = declaration[encodingRange]
            .split(separator: "=", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .lowercased()
        return encoding?.replacingOccurrences(of: "_", with: "-")
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
