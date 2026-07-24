import AppKit
import AttacheCore
import SwiftUI

/// Right-click actions for the live caption and the pinned last-turn card:
/// open the running transcript, pin it open, or copy the turn text. Right-click
/// is free on the caption (single/double-click and scroll are already reserved
/// for seek/play/line-count), so this adds an affordance without a new gesture.
struct TranscriptContextMenu: ViewModifier {
    @ObservedObject var model: AppModel
    var currentText: String

    func body(content: Content) -> some View {
        content.contextMenu {
            Button {
                model.showTranscriptPanel()
            } label: {
                Label("Show conversation", systemImage: "bubble.left.and.bubble.right")
            }
            Button {
                model.setTranscriptPanelPinned(true)
            } label: {
                Label("Keep panel open", systemImage: "pin")
            }
            Divider()
            Button {
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                let toCopy = text.isEmpty ? (model.liveCallTranscript.pinnedText ?? "") : text
                guard !toCopy.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(toCopy, forType: .string)
            } label: {
                Label("Copy text", systemImage: "doc.on.doc")
            }
        }
    }
}

/// The running conversation transcript for a live call (combination "B + A",
/// PART A). An ordered list of both the user's spoken turns and Attaché's,
/// newest at the bottom, auto-scrolling as turns arrive. The turn being spoken
/// is highlighted; each Attaché turn offers a replay control that plays that
/// turn's audio through the standard History playback path. It reuses the app's
/// in-memory conversation turns (`model.liveCallTranscript`) and never builds a
/// parallel store. Shown only during a call; ordinary voicemail/history playback
/// keeps the single-turn `LyricsSidePanel`.
struct LiveTranscriptPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var playback: SpeechPlaybackController

    /// Panel width at the moment a resize drag began, so the drag maps
    /// absolutely rather than accumulating per frame.
    @State private var dragStartWidth: CGFloat?

    private var accent: Color { model.theme.signatureColor }
    private var transcript: LiveCallTranscript { model.liveCallTranscript }

    private var speakingID: String? {
        transcript.speakingEntryID(
            spokenText: playback.currentText,
            isPlaying: playback.isPlaying || playback.isPaused
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                thread
            }
            .frame(width: model.transcriptPanelWidth)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .leading) { resizeHandle }
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
        .accessibilityIdentifier("Live Transcript Panel")
    }

    /// A draggable grip on the panel's left edge. The panel is anchored to the
    /// right, so dragging the edge left widens it and right narrows it. Width is
    /// clamped and persisted by `AppModel.setTranscriptPanelWidth`.
    private var resizeHandle: some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = dragStartWidth ?? model.transcriptPanelWidth
                                if dragStartWidth == nil { dragStartWidth = start }
                                model.setTranscriptPanelWidth(start - value.translation.width)
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
                    .accessibilityLabel("Resize conversation panel")
            )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                .typoCaption(.semibold)
                .foregroundStyle(accent)
            Spacer()
            Button {
                model.setTranscriptPanelPinned(!model.transcriptPanelPinned)
            } label: {
                Image(systemName: model.transcriptPanelPinned ? "pin.fill" : "pin")
                    .typoIcon(size: 12, .semibold)
                    .foregroundStyle(model.transcriptPanelPinned ? accent : Color.primary.opacity(0.55))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(model.transcriptPanelPinned ? "Unpin. The panel closes when you're done." : "Keep panel open across turns and calls.")
            .accessibilityLabel(model.transcriptPanelPinned ? "Unpin conversation panel" : "Pin conversation panel open")
            .accessibilityAddTraits(model.transcriptPanelPinned ? [.isSelected] : [])

            Button {
                model.toggleTranscriptPanel()
            } label: {
                Image(systemName: "xmark")
                    .typoIcon(size: 11, .bold)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close conversation panel")
            .accessibilityLabel("Close conversation panel")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var thread: some View {
        if transcript.isEmpty {
            VStack(spacing: 6) {
                Text("No turns yet")
                    .typoBody(.semibold)
                    .foregroundStyle(.primary.opacity(0.75))
                Text("Your conversation will appear here as you talk.")
                    .typoCaption()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 18)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(transcript.entries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Auto-scroll to the newest turn as it arrives, so a new turn is
                // never below the fold.
                .onChange(of: transcript.newestEntryID) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: speakingID) { id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onAppear {
                    if let id = transcript.newestEntryID { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func row(_ entry: LiveCallTranscriptEntry) -> some View {
        let isUser = entry.speaker == .user
        let isSpeaking = entry.id == speakingID
        return HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 32) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(entry.speaker.cue)
                        .typoCaption(.semibold)
                        .foregroundStyle(isUser ? Color.white.opacity(0.9) : accent)
                    if isSpeaking {
                        Image(systemName: "waveform")
                            .typoIcon(size: 10, .bold)
                            .foregroundStyle(isUser ? Color.white : accent)
                            .accessibilityLabel("Now speaking")
                    }
                    Spacer(minLength: 0)
                    if !isUser, entry.isReplayable {
                        Button {
                            model.replayTranscriptEntry(entry)
                        } label: {
                            Image(systemName: "play.circle")
                                .typoIcon(size: 13, .semibold)
                                .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)
                        .help("Replay this turn")
                        .accessibilityLabel("Replay this turn")
                    }
                }
                Text(entry.text)
                    .typoBody()
                    .foregroundStyle(isUser ? Color.white : Color.primary.opacity(0.92))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(
                isUser ? AnyShapeStyle(accent) : AnyShapeStyle(Color.primary.opacity(0.07)),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(accent.opacity(isSpeaking ? 0.9 : 0), lineWidth: 2)
            )
            if !isUser { Spacer(minLength: 32) }
        }
    }
}
