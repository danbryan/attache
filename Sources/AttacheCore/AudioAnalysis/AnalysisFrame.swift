import Foundation

public struct AnalysisFrame: Sendable, Equatable {
    public var rms: Float = 0
    public var peak: Float = 0
    public var bands: [Float] = []
    public var bass: Float = 0
    public var mid: Float = 0
    public var treble: Float = 0
    public var centroid: Float = 0
    public var zeroCrossingRate: Float = 0
    public var silence: Float = 1
    public var waveform: [Float] = []
    public var sampleRate: Double = 48_000
    public var timestamp: Double = 0

    public init() {}
}
