public struct EnvelopeFollower: Sendable, Equatable {
    public private(set) var value: Float = 0
    public var attack: Float
    public var release: Float

    public init(attack: Float = 0.3, release: Float = 0.08) {
        self.attack = attack
        self.release = release
    }

    @discardableResult
    public mutating func update(_ target: Float) -> Float {
        let coefficient = target > value ? attack : release
        value += (target - value) * coefficient
        return value
    }

    public mutating func reset() {
        value = 0
    }
}
