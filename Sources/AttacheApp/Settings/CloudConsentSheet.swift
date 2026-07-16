import SwiftUI

/// One-time confirmation shown the first time a cloud provider is chosen in a
/// category (presentation or voice). States plainly what leaves the Mac. Enable
/// applies the selection and records the acknowledgment; Cancel keeps the
/// previous provider.
struct CloudConsentSheet: View {
    let providerName: String
    /// What the provider produces, e.g. "summaries" or "speech".
    let produces: String
    /// What is sent to it, one sentence.
    let sends: String
    /// The normalized destination receiving the data, when it is configurable.
    let destination: String?
    let onEnable: () -> Void
    let onCancel: () -> Void

    init(
        providerName: String,
        produces: String,
        sends: String,
        destination: String? = nil,
        onEnable: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.providerName = providerName
        self.produces = produces
        self.sends = sends
        self.destination = destination
        self.onEnable = onEnable
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "cloud")
                    .typoIcon(size: 22)
                    .foregroundStyle(.orange)
                Text("Use \(providerName)?")
                    .typoSection()
            }

            Text("\(providerName) runs in the cloud. To generate \(produces), Attaché will send \(sends) to \(providerName). Nothing is sent while you use a local provider.")
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let destination, !destination.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Destination")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(destination)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }

            Text("You're acknowledging this once for \(produces). You can switch back to a local provider at any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Enable", action: onEnable)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
