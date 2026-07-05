import Foundation
import MediaPlayer

/// Bridges system media controls to playback: the keyboard's play/pause and
/// forward/back keys, Control Center, and the now-playing widget all drive the
/// same transport as the in-app buttons. Publishing now-playing info is what
/// makes the app eligible to receive these remote commands.
final class MediaRemoteController {
    struct Handlers {
        var togglePlayPause: () -> Void
        var play: () -> Void
        var pause: () -> Void
        var skipForward: () -> Void
        var skipBackward: () -> Void
        var seek: (Double) -> Void
    }

    private var handlers: Handlers?
    private var configured = false

    func activate(handlers: Handlers) {
        self.handlers = handlers
        guard !configured else { return }
        configured = true

        let center = MPRemoteCommandCenter.shared()

        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handlers?.togglePlayPause()
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            self?.handlers?.play()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.handlers?.pause()
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.handlers?.skipForward()
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.handlers?.skipBackward()
            return .success
        }
        // Some keyboards send next/previous-track for their forward/back keys, so
        // map those to the same skip.
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.handlers?.skipForward()
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.handlers?.skipBackward()
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.handlers?.seek(event.positionTime)
            return .success
        }
    }

    func setSkipInterval(seconds: Int) {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: seconds)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: seconds)]
    }

    func updateNowPlaying(title: String, artist: String, durationMs: Int, elapsedMs: Int, playing: Bool) {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = artist
        info[MPMediaItemPropertyPlaybackDuration] = Double(max(0, durationMs)) / 1000.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(max(0, elapsedMs)) / 1000.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }

    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
