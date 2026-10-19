import Testing
@testable import peekturn_ios

struct peekturn_iosTests {
    @Test func bookProgressIsKeptInsideTheSupportedRange() {
        #expect(Book(title: "A", author: "B", progress: -0.2).progress == 0)
        #expect(Book(title: "A", author: "B", progress: 0.4).progress == 0.4)
        #expect(Book(title: "A", author: "B", progress: 1.4).progress == 1)
    }

    @Test func nonFiniteBookProgressFallsBackToZero() {
        #expect(Book(title: "A", author: "B", progress: .infinity).progress == 0)
        #expect(Book(title: "A", author: "B", progress: .nan).progress == 0)
    }
}
