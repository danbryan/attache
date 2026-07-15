import SwiftUI

/// A labeled settings row: a fixed-width secondary label on the left and the
/// supplied control on the right. Shared by ordinary Settings panes.
func settingRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
    HStack(alignment: .center, spacing: 16) {
        // The label is UI vocabulary: route it through the localization table.
        Text(LocalizedStringKey(label))
            .frame(width: 130, alignment: .leading)
            .foregroundStyle(.secondary)
        content()
        Spacer(minLength: 0)
    }
}
