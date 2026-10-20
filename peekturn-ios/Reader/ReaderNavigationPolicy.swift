import Foundation

enum ReaderNavigationPolicy {
    static func allowsLocalFile(_ url: URL, inside directory: URL) -> Bool {
        guard url.isFileURL,
              url.host == nil || url.host?.isEmpty == true else {
            return false
        }

        let rootPath = directory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let candidatePath = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func allowsNavigation(_ url: URL, inside directory: URL) -> Bool {
        allowsLocalFile(url, inside: directory)
    }

    static func allowsRedirect(_ url: URL, inside directory: URL) -> Bool {
        allowsLocalFile(url, inside: directory)
    }

    static func allowsResourceRequest(_ url: URL, inside directory: URL) -> Bool {
        allowsLocalFile(url, inside: directory)
    }
}
