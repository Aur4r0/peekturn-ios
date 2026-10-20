import SwiftUI

struct LibraryEmptyState: View {
    var body: some View {
        VStack(spacing: PeekturnTheme.Spacing.section) {
            ZStack {
                Circle()
                    .fill(PeekturnTheme.surface)
                    .frame(width: 88, height: 88)

                Image(systemName: "book.closed")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }

            VStack(spacing: PeekturnTheme.Spacing.compact) {
                Text("Your library is empty")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text("Import an original EPUB to begin reading.")
                    .font(.body)
                    .foregroundStyle(PeekturnTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, PeekturnTheme.Spacing.page)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-empty-state")
    }
}

struct LibraryEmptyState_Previews: PreviewProvider {
    static var previews: some View {
        LibraryEmptyState()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PeekturnTheme.pageBackground)
    }
}
