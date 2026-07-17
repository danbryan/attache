import AttacheCore
import Combine
import Foundation

/// The render-only data a Settings pane needs to show the active
/// provider/model label and its detected capability evidence, without
/// observing `AppModel`.
///
/// This exists so panes never declare `@ObservedObject var model: AppModel`
/// just to read these values (INF-351). `AppModel` publishes at high
/// frequency during narration, character animation, and call playback; a
/// pane holding a reference to it directly re-renders on all of that churn
/// even though it reads only a handful of derived values. `SettingsPaneState`
/// is the narrow seam: `AppModel` recomputes a snapshot whenever the
/// presentation provider, model, base URL, or discovered model list actually
/// changes, and publishes it only when the recomputed snapshot differs from
/// the current one (compare-before-publish).
///
/// The Custom-policy override (`AttacheContextCustomPolicy`, owned by
/// `AttacheContextUIState`, a separate narrow, already-injectable seam) is
/// deliberately not baked in here: a pane combines `profile` with that
/// override via `AttacheCapabilitySummary.from(detected:override:)` in its
/// own body, which is a cheap, pure struct construction, not the expensive
/// lookup this snapshot exists to avoid recomputing on every AppModel
/// publish.
public struct SettingsPaneSnapshot: Equatable {
    public var providerSummary: String
    public var modelLabel: String
    public var profile: AttacheModelCapabilityProfile
    public var capabilityNotice: String?

    public init(
        providerSummary: String,
        modelLabel: String,
        profile: AttacheModelCapabilityProfile,
        capabilityNotice: String?
    ) {
        self.providerSummary = providerSummary
        self.modelLabel = modelLabel
        self.profile = profile
        self.capabilityNotice = capabilityNotice
    }

    /// The state before `AppModel` has computed a real snapshot. `AppModel`
    /// replaces this during `init`, before any Settings pane can observe it.
    public static let empty = SettingsPaneSnapshot(
        providerSummary: "",
        modelLabel: "",
        profile: .unknown,
        capabilityNotice: nil
    )
}

/// Owned by `AppModel`, updated only through `update(_:)`. Settings panes
/// that only render the provider/model label and capability evidence should
/// observe this instead of `AppModel` itself.
public final class SettingsPaneState: ObservableObject {
    @Published public private(set) var snapshot: SettingsPaneSnapshot

    public init(snapshot: SettingsPaneSnapshot = .empty) {
        self.snapshot = snapshot
    }

    /// Publishes the new snapshot only if it differs from the current one
    /// (compare-before-publish), so unrelated `AppModel` churn that leaves
    /// these values unchanged never triggers a re-render of an observing
    /// pane.
    public func update(_ new: SettingsPaneSnapshot) {
        guard new != snapshot else { return }
        snapshot = new
    }
}
