import Foundation

/// Controls admission pace, not a claimed limit on decoder CPU/GPU usage.
enum QualityCueWorkPolicy {
    struct Resources: Equatable, Sendable {
        enum Thermal: Sendable { case nominal, fair, serious, critical }
        var lowPower: Bool
        var thermal: Thermal

        static var current: Self {
            let info = ProcessInfo.processInfo
            let thermal: Thermal
            switch info.thermalState {
            case .nominal: thermal = .nominal
            case .fair: thermal = .fair
            case .serious: thermal = .serious
            case .critical: thermal = .critical
            @unknown default: thermal = .serious
            }
            return Self(lowPower: info.isLowPowerModeEnabled, thermal: thermal)
        }
    }

    /// Equal rest/work for a normal folder sweep, at least 100 ms per batch.
    /// Low power/serious thermal state rests three times the preceding work;
    /// critical rests seven times. Explicit foreground interest can wake rest.
    static func rest(after work: Duration, resources: Resources) -> Duration {
        let multiplier: Int
        switch resources.thermal {
        case .critical: multiplier = 7
        case .serious: multiplier = 3
        case .nominal, .fair: multiplier = resources.lowPower ? 3 : 1
        }
        return max(.milliseconds(100), max(.zero, work) * multiplier)
    }
}
