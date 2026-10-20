import Foundation

enum EPUBArchivePathError: Error, Equatable {
    case emptyPath
    case absolutePath
    case pathTraversal
    case invalidComponent
}

struct EPUBArchivePath {
    static func normalized(_ rawPath: String, relativeTo basePath: String? = nil) throws -> String {
        let baseComponents: [String]
        if let basePath {
            baseComponents = try components(from: basePath, startingWith: [])
        } else {
            baseComponents = []
        }

        return try components(from: rawPath, startingWith: baseComponents).joined(separator: "/")
    }

    static func normalizedArchiveEntry(_ rawPath: String) throws -> String {
        let decodedPath = try decodedPath(from: rawPath, strippingURIComponents: false)
        guard !decodedPath.split(separator: "/").contains("..") else {
            throw EPUBArchivePathError.pathTraversal
        }
        return try normalized(decodedPath)
    }

    static func directory(of path: String) throws -> String? {
        let normalizedPath = try normalized(path)
        let components = normalizedPath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    private static func components(from rawPath: String, startingWith initial: [String]) throws -> [String] {
        let decodedPath = try decodedPath(from: rawPath, strippingURIComponents: true)
        guard !decodedPath.hasPrefix("/") else {
            throw EPUBArchivePathError.absolutePath
        }

        var components = initial
        for component in decodedPath.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else {
                    throw EPUBArchivePathError.pathTraversal
                }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }

        guard !components.isEmpty else {
            throw EPUBArchivePathError.emptyPath
        }
        return components
    }

    private static func decodedPath(from rawPath: String, strippingURIComponents: Bool) throws -> String {
        guard !rawPath.isEmpty,
              !rawPath.contains("\0"),
              !rawPath.contains("\\") else {
            throw EPUBArchivePathError.invalidComponent
        }

        let pathPart = strippingURIComponents
            ? rawPath.split(whereSeparator: { $0 == "#" || $0 == "?" }).first.map(String.init) ?? ""
            : rawPath
        guard !pathPart.isEmpty,
              !pathPart.contains("://"),
              !pathPart.lowercased().hasPrefix("data:") else {
            throw EPUBArchivePathError.invalidComponent
        }

        guard let decodedPath = pathPart.removingPercentEncoding else {
            throw EPUBArchivePathError.invalidComponent
        }
        guard decodedPath.split(separator: "/").first?.contains(":") != true else {
            throw EPUBArchivePathError.invalidComponent
        }
        return decodedPath
    }
}
