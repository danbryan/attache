import Foundation

public struct VisualizerRenderState: Sendable, Equatable {
    public private(set) var latestFrame = AnalysisFrame()
    public private(set) var level: Float = 0
    public private(set) var pulse: Float = 0
    public private(set) var bass: Float = 0
    public private(set) var mid: Float = 0
    public private(set) var treble: Float = 0
    public private(set) var centroid: Float = 0
    public private(set) var bars: [Float] = []

    private var levelEnv = EnvelopeFollower(attack: 0.30, release: 0.05)
    private var pulseEnv = EnvelopeFollower(attack: 0.58, release: 0.10)
    private var bassEnv = EnvelopeFollower(attack: 0.38, release: 0.06)
    private var midEnv = EnvelopeFollower(attack: 0.40, release: 0.07)
    private var trebleEnv = EnvelopeFollower(attack: 0.50, release: 0.09)
    private var centroidEnv = EnvelopeFollower(attack: 0.20, release: 0.05)
    private var barEnvs: [EnvelopeFollower] = []

    public init() {}

    public mutating func apply(_ frame: AnalysisFrame) {
        latestFrame = frame
        level = levelEnv.update(frame.rms)
        pulse = pulseEnv.update(frame.peak)
        bass = bassEnv.update(frame.bass)
        mid = midEnv.update(frame.mid)
        treble = trebleEnv.update(frame.treble)
        centroid = centroidEnv.update(frame.centroid)
        updateBars(frame.bands)
    }

    public mutating func decayToSilence() {
        var frame = AnalysisFrame()
        frame.bands = [Float](repeating: 0, count: max(56, bars.count))
        apply(frame)
    }

    public mutating func reset() {
        latestFrame = AnalysisFrame()
        level = 0
        pulse = 0
        bass = 0
        mid = 0
        treble = 0
        centroid = 0
        bars = []
        levelEnv.reset()
        pulseEnv.reset()
        bassEnv.reset()
        midEnv.reset()
        trebleEnv.reset()
        centroidEnv.reset()
        barEnvs = []
    }

    private mutating func updateBars(_ raw: [Float]) {
        guard !raw.isEmpty else { return }
        if barEnvs.count != raw.count {
            barEnvs = raw.map { _ in EnvelopeFollower(attack: 0.42, release: 0.08) }
        }
        var next = [Float](repeating: 0, count: raw.count)
        for index in raw.indices {
            next[index] = barEnvs[index].update(raw[index])
        }
        bars = next
    }
}
