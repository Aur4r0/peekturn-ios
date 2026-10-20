import Foundation

enum ReaderNavigationPolicy {
    static func allowsLocalFile(_ url: URL, inside directory: URL) -> Bool {
        guard url.isFileURL else { return false }

        let rootPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = url.standardizedFileURL.resolvingSymlinksInPath().path
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
