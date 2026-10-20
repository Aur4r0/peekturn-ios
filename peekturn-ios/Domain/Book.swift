import Foundation

nonisolated struct Book: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let progress: Double
    let epubFileName: String

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        progress: Double = 0,
        epubFileName: String = ""
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
        self.epubFileName = epubFileName
    }
}
