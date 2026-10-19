import Foundation

struct Book: Identifiable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let progress: Double

    init(id: UUID = UUID(), title: String, author: String, progress: Double = 0) {
        self.id = id
        self.title = title
        self.author = author
        self.progress = progress.isFinite ? min(max(progress, 0), 1) : 0
    }
}
