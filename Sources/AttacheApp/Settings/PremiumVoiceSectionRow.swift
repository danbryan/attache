import SwiftUI

/// The "Attaché Premium" section that leads the on-device voice list: the Azelma
/// row plus its consent/download/verify/retry affordances. Selection is gated by
/// `PremiumVoiceSelectionController` so picking Azelma never silently downloads
/// and never changes the working voice until the weights actually install.
struct PremiumVoiceSectionRow: View {
    @ObservedObject var model: AppModel
    @StateObject private var controller: PremiumVoiceSelectionController
    var isSelected: Bool
    /// Persists the selection (voiceRef -> Attaché Premium). Called immediately
    /// when the weights are already installed, or deferred until an install
    /// completes.
    var onComplete: () -> Void

    init(model: AppModel, isSelected: Bool, onComplete: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _controller = StateObject(wrappedValue: PremiumVoiceSelectionController(weights: model.premiumVoiceWeights))
        self.isSelected = isSelected
        self.onComplete = onComplete
    }

    private var descriptor: PremiumVoiceSectionDescriptor {
        controller.descriptor(isSelected: isSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(descriptor.sectionTitle.uppercased())
                .typoCaption(.bold)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 10) {
                selectionRow
                PremiumVoiceAffordanceView(affordance: descriptor.affordance, controller: controller)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                (isSelected ? model.theme.signatureColor.opacity(0.12) : Color.primary.opacity(0.03)),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
    }

    private var selectionRow: some View {
        HStack(spacing: 10) {
            Button {
                controller.select(complete: onComplete)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(descriptor.voiceName).typoBody(.semibold)
                            Text("Premium")
                                .typoCaption(.bold)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        Text(caption)
                            .typoCaption()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(model.theme.signatureColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Premium Voice Azelma")
            .accessibilityLabel("Voice \(descriptor.voiceName), Attaché Premium\(isSelected ? ", selected" : "")")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            Button {
                model.previewPremiumVoiceSample()
            } label: {
                Image(systemName: "play.circle")
                    .typoIcon(size: 18)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("Premium Voice Preview")
            .accessibilityLabel("Play sample of \(descriptor.voiceName)")
            .help("Play a sample")
        }
    }

    /// The caption plus any state suffix (download size, progress, verifying).
    private var caption: String {
        guard let suffix = descriptor.stateSuffix else { return descriptor.caption }
        return "\(descriptor.caption) \(suffix)"
    }
}

/// The Azelma row that leads the onboarding voice step (E3). It reuses the E2
/// selection controller (consent gate, download progress, cancel-revert,
/// failure-retry, deferred install completion) and the shared affordance view;
/// only the leading-row styling, copy, and AX identifiers are onboarding-
/// specific. The controller is owned by `AppModel`, not this transient step
/// view, so a download started here still completes the deferred voiceRef
/// switch after the user pages ahead in onboarding.
struct OnboardingPremiumVoiceRowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: PremiumVoiceSelectionController
    /// Observed so inline progress and state suffixes update as the download
    /// advances, independent of the transient step view's lifecycle.
    @ObservedObject var weights: PremiumVoiceWeightsManager
    var isSelected: Bool
    /// Persists the selection (voiceRef -> Attaché Premium). Called immediately
    /// when the weights are already installed, or deferred until an install
    /// completes.
    var onComplete: () -> Void

    private var accent: Color { model.theme.signatureColor }

    private var descriptor: PremiumVoiceSectionDescriptor {
        controller.descriptor(isSelected: isSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    controller.select(complete: onComplete)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                            .typoIcon(size: 14)
                            .foregroundStyle(isSelected ? accent : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(OnboardingPremiumVoiceRow.voiceName).typoBody(.semibold)
                                Text(OnboardingPremiumVoiceRow.badge)
                                    .typoCaption(.bold)
                                    .foregroundStyle(accent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(accent.opacity(0.15), in: Capsule())
                            }
                            Text(caption)
                                .typoCaption()
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(OnboardingPremiumVoiceRow.rowIdentifier)
                .accessibilityLabel("Voice Azelma, Attaché Premium, included\(isSelected ? ", selected" : "")")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

                Button("Preview") {
                    model.previewPremiumVoiceSample()
                }
                .typoCaption(.medium)
                .accessibilityIdentifier(OnboardingPremiumVoiceRow.previewIdentifier)
                .accessibilityLabel("Preview Azelma")
            }
            PremiumVoiceAffordanceView(affordance: descriptor.affordance, controller: controller)
        }
        .padding(12)
        .background(
            (isSelected ? accent.opacity(0.14) : accent.opacity(0.06)),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(accent.opacity(0.35)))
    }

    private var caption: String {
        guard let suffix = descriptor.stateSuffix else { return OnboardingPremiumVoiceRow.caption }
        return "\(OnboardingPremiumVoiceRow.caption) \(suffix)"
    }
}

/// The consent/download/verify/failure follow-up shared by the Settings voice
/// list row and the onboarding voice-step row, so both drive the identical
/// `PremiumVoiceSelectionController` state machine and expose the same
/// download/cancel/retry AX identifiers.
struct PremiumVoiceAffordanceView: View {
    var affordance: PremiumVoiceAffordance
    var controller: PremiumVoiceSelectionController

    @ViewBuilder var body: some View {
        switch affordance {
        case .selectable:
            EmptyView()
        case .consent(let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Download") { controller.confirmDownload() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("Premium Voice Download")
                    Button("Cancel") { controller.cancel() }
                        .accessibilityIdentifier("Premium Voice Cancel")
                }
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: min(max(progress, 0), 1))
                    .accessibilityLabel("Attaché Premium voice download progress")
                Button("Cancel") { controller.cancel() }
                    .accessibilityIdentifier("Premium Voice Cancel")
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Verifying…").typoCaption().foregroundStyle(.secondary)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 8) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .typoCaption()
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Retry") { controller.retry() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("Premium Voice Download")
                    Button("Cancel") { controller.cancel() }
                        .accessibilityIdentifier("Premium Voice Cancel")
                }
            }
        }
    }
}
