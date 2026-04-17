import Foundation

/// Estimates remaining time for a `0.0...1.0` progress stream using an
/// exponential moving average of the implied total time (`elapsed / progress`).
public final class ETAEstimator {
    public var warmupThreshold: Double = 0.05
    public var smoothingFactor: Double = 0.1

    private var emaTotal: Double?

    public init() {}

    public func estimate(progress: Double, elapsed: TimeInterval) -> TimeInterval? {
        guard progress > warmupThreshold, progress < 1.0, elapsed > 0 else { return nil }
        let currentTotal = elapsed / progress
        let updated = emaTotal.map { $0 + smoothingFactor * (currentTotal - $0) } ?? currentTotal
        emaTotal = updated
        return max(updated - elapsed, 0)
    }

    public func reset() { emaTotal = nil }
}
