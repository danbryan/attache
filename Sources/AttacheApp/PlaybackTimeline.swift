import AttacheCore
import Combine

/// The high-frequency playback state, updated ~20×/sec by the playback clock.
///
/// It lives in its own observable, separate from `SpeechPlaybackController`'s
/// coarse state (isPlaying, current card, duration). That way the main window,
/// which observes the controller, is not invalidated on every clock tick; only
/// the caption, scrubber, and visualizer observe this object and refresh at 20 Hz.
final class PlaybackTimeline: ObservableObject {
    @Published var currentTimeMs = 0
    @Published var activeWordIndex: Int?
    @Published var renderState = VisualizerRenderState()
    @Published var envelope: Double = 0
}
