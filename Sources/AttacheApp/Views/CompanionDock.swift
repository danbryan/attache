import SwiftUI

extension CompanionRootView {
    // The always-summoned bottom dock: the few actions one click away. Focus
    // status is dock-owned: a circle button plus a status card that appears on
    // hover or briefly when focus changes (docs/design/focus-indicator-concepts).
    var slimDock: some View {
        VStack(spacing: 8) {
            if focusDockStatusCardVisible {
                focusDockStatusCard
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                callButton
                if model.onCall { callMicButton }
                if model.canSendToAgent { sendToAgentComposerButton }
                focusButton
                unreadBadge
                if model.showPersonalitySwitcher {
                    personalitySwitcher
                }
                settingsButton
            }
        }
        .contentShape(Rectangle())
        .onHover { setDockAreaHover($0) }
    }

    var focusDockStatusCardVisible: Bool {
        hoveredDockItem == .focus || focusConfirmationVisible
    }

    var focusButton: some View {
        Button {
            // The palette receiver in the root view closes the other overlays.
            NotificationCenter.default.post(name: .attacheOpenPalette, object: nil)
        } label: {
            Image(systemName: focusDockIconName)
                .typoIcon(size: 13, .semibold)
                .foregroundStyle(model.anyWatchedSessionNeedsUser || model.attachedCodexSessionID != nil || hoveredDockItem == .focus ? accent : Color.primary.opacity(0.62))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial.opacity(hoveredDockItem == .focus ? 0.72 : 0.58), in: Circle())
                .overlay(
                    Circle()
                        .stroke(model.attachedCodexSessionID != nil || hoveredDockItem == .focus ? accent.opacity(0.45) : Color.primary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help(focusDockHelpText)
        .accessibilityLabel("Focus status")
        .onHover { setDockHover(.focus, $0) }
    }

    var sendToAgentComposerButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                surfaceMode = .live
                liveComposerVisible = true
            }
        } label: {
            Image(systemName: "paperplane.fill")
                .typoIcon(size: 13, .semibold)
                .foregroundStyle(liveComposerVisible || hoveredDockItem == .send ? .orange : Color.primary.opacity(0.62))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial.opacity(hoveredDockItem == .send ? 0.72 : 0.58), in: Circle())
                .overlay(
                    Circle()
                        .stroke(liveComposerVisible || hoveredDockItem == .send ? Color.orange.opacity(0.5) : Color.primary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help("Send an instruction to the focused agent")
        .accessibilityLabel("Open send-to-agent composer")
        .onHover { setDockHover(.send, $0) }
    }

    private var focusDockIconName: String {
        if model.anyWatchedSessionNeedsUser { return "exclamationmark.bubble.fill" }
        return model.attachedCodexSessionID == nil ? "link.badge.plus" : "link"
    }

    private var focusDockHelpText: String {
        if model.anyWatchedSessionNeedsUser {
            return "An agent is waiting on you. Click to open ⌘K and jump to it."
        }
        if let target = model.attachedCodexSession {
            return "Focused on \(target.displayTitle). Click to choose a different session with ⌘K."
        }
        return "No session focused. Click or press ⌘K to choose one."
    }

    private var focusDockTitle: String {
        guard let target = model.attachedCodexSession else { return "No session focused" }
        return model.onCall ? "On a call · \(target.displayTitle)" : "Focused · \(target.displayTitle)"
    }

    private var focusDockSubtitle: String {
        guard model.attachedCodexSession != nil else { return "Press ⌘K to pick a session." }
        if model.onCall { return "Listening live. Hang up to send updates to your inbox." }
        if !model.voicemailMode { return "Narrating updates as they happen. ⇧⌘V to go quiet." }
        if model.attachedTargets.count > 1 {
            return "Watching \(model.attachedTargets.count) · updates wait in your inbox."
        }
        return "Updates wait in your inbox. Call to talk live."
    }

    var focusDockStatusCard: some View {
        HStack(spacing: 8) {
            Image(systemName: focusDockIconName)
                .typoIcon(size: 11, .bold)
                .foregroundStyle(accent)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(focusDockTitle)
                    .typoLabel(.bold)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                Text(focusDockSubtitle)
                    .typoCaption(.medium, design: .monospaced)
                    .foregroundStyle(.primary.opacity(0.58))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: 390, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.68), in: RoundedRectangle(cornerRadius: 10))
        .readingPlate(theme: model.theme, cornerRadius: 10, minimumOpacity: 0.65)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent.opacity(model.attachedCodexSessionID == nil ? 0.16 : 0.28))
        )
        .allowsHitTesting(false)
    }

    func setDockAreaHover(_ hovering: Bool) {
        dockHovering = hovering
    }

    // Icon-only by default: the active personality is ambient state, not a
    // frequent control, so the name stays out of the dock unless the user
    // turns it on. Hover reveals the current name either way.
    var personalitySwitcher: some View {
        Menu {
            // Plain rows with a checkmark on the active one; the masks logo
            // belongs to the dock button, not every menu line.
            ForEach(model.personalities) { personality in
                Button {
                    model.selectPersonality(personality.id)
                } label: {
                    if personality.id == model.activePersonalityID {
                        Label(personality.name, systemImage: "checkmark")
                    } else {
                        Text(personality.name)
                    }
                }
            }
        } label: {
            if model.showPersonalityNameInDock {
                HStack(spacing: 7) {
                    Image(systemName: "theatermasks")
                        .typoIcon(size: 13, .semibold)
                    Text(model.activePersonality?.name ?? "Personality")
                        .typoLabel(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(hoveredDockItem == .personality ? accent : Color.primary.opacity(0.78))
                .padding(.horizontal, 13)
                .frame(height: 38)
                .frame(maxWidth: 190)
                .background(.ultraThinMaterial.opacity(hoveredDockItem == .personality ? 0.72 : 0.58), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(hoveredDockItem == .personality ? accent.opacity(0.45) : Color.primary.opacity(0.12))
                )
            } else {
                Image(systemName: "theatermasks")
                    .typoIcon(size: 13, .semibold)
                    .foregroundStyle(hoveredDockItem == .personality ? accent : Color.primary.opacity(0.62))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial.opacity(hoveredDockItem == .personality ? 0.72 : 0.58), in: Circle())
                    .overlay(
                        Circle()
                            .stroke(hoveredDockItem == .personality ? accent.opacity(0.45) : Color.primary.opacity(0.12))
                    )
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("Personality: \(model.activePersonality?.name ?? "none"). Switch with ⌘[ / ⌘].")
        .accessibilityLabel("Switch personality")
        .onHover { setDockHover(.personality, $0) }
    }

    func setDockHover(_ item: DockItem, _ hovering: Bool) {
        if hovering { hoveredDockItem = item }
        else if hoveredDockItem == item { hoveredDockItem = nil }
    }

    @ViewBuilder
    var unreadBadge: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                inboxVisible = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.unreadCount > 0 ? "tray.full" : "tray")
                    .typoIcon(size: 13, .semibold)
                if model.unreadCount > 0 {
                    Text("\(model.unreadCount)")
                        .typoBody(.bold, design: .rounded)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(model.unreadCount > 0 || hoveredDockItem == .unread ? accent : Color.primary.opacity(0.62))
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial.opacity(hoveredDockItem == .unread ? 0.72 : 0.58), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(model.unreadCount > 0 || hoveredDockItem == .unread ? accent.opacity(0.45) : Color.primary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .help("Open inbox")
        .accessibilityLabel("Open inbox")
        .accessibilityValue(model.unreadCount > 0 ? "\(model.unreadCount) unread" : "No unread")
        .onHover { setDockHover(.unread, $0) }
    }

    @ViewBuilder
    var settingsButton: some View {
        Button {
            surfaceMode = .live
            NotificationCenter.default.post(name: .attacheOpenSettings, object: nil)
        } label: {
            Image(systemName: "gearshape")
                .typoIcon(size: 13, .semibold)
                .foregroundStyle(hoveredDockItem == .settings ? accent : Color.primary.opacity(0.62))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial.opacity(hoveredDockItem == .settings ? 0.72 : 0.58), in: Circle())
                .overlay(
                    Circle()
                        .stroke(hoveredDockItem == .settings ? accent.opacity(0.5) : Color.primary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help("Open settings")
        .accessibilityLabel("Open settings")
        .onHover { setDockHover(.settings, $0) }
    }

    var talkButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if model.conversationActive { model.endConversation() }
                else { model.startConversation() }
            }
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
                .typoIcon(size: 13, .semibold)
                .foregroundStyle(model.conversationActive || hoveredDockItem == .talk ? accent : Color.primary.opacity(0.62))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial.opacity(hoveredDockItem == .talk ? 0.72 : 0.58), in: Circle())
                .overlay(
                    Circle()
                        .stroke(model.conversationActive || hoveredDockItem == .talk ? accent.opacity(0.45) : Color.primary.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help("Converse with Attaché — type or hold to talk (⌘L)")
        .accessibilityLabel(model.conversationActive ? "Close conversation" : "Open conversation")
        .onHover { setDockHover(.talk, $0) }
    }

    // The Live <-> Voicemail spine: one labeled toggle, current state always shown.
    var modeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { model.toggleVoicemailMode() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.voicemailMode ? "voicemail" : "phone.fill")
                    .typoIcon(size: 12, .semibold)
                Text(model.voicemailMode ? "Inbox" : "Live")
                    .typoLabel(.semibold)
            }
            .foregroundStyle(model.voicemailMode || hoveredDockItem == .mode ? accent : Color.primary.opacity(0.78))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(.ultraThinMaterial.opacity(hoveredDockItem == .mode ? 0.72 : 0.58), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(model.voicemailMode || hoveredDockItem == .mode ? accent.opacity(0.45) : Color.primary.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
        .help(model.voicemailMode
              ? "Inbox: updates wait quietly as voicemail. Click to go Live (⇧⌘V)."
              : "Live: the focused session narrates as it goes. Click to go quiet (⇧⌘V).")
        .onHover { setDockHover(.mode, $0) }
    }
}
