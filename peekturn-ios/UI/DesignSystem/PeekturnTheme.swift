import SwiftUI
import UIKit

enum PeekturnTheme {
    enum Spacing {
        static let page = 24.0
        static let section = 20.0
        static let content = 12.0
        static let compact = 8.0
    }

    enum Radius {
        static let card = 20.0
        static let control = 14.0
    }

    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let outline = Color(uiColor: .separator)
}
