import Darwin

public struct Equalizer: Equatable, Sendable {
    public var low: Int
    public var mid: Int
    public var high: Int

    public init(low: Int = 0, mid: Int = 0, high: Int = 0) {
        self.low = low
        self.mid = mid
        self.high = high
    }

    public var isFlat: Bool { self == Equalizer() }
}

public struct StereoProcessor {
    public static let maximumVolume = 200

    private let sampleRate: Double
    private let limiterRecovery: Float
    private var filters = Array(repeating: Biquad(), count: 6)
    private var targetGain: Float = 1
    private var gain: Float = 1
    private var limiterGain: Float = 1
    private var currentEQ = Equalizer()

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // Recover gradually after peaks, with the same time constant at any sample rate.
        limiterRecovery = Float(1 - exp(-1 / (sampleRate * 0.05)))
    }

    public mutating func configure(volume: Int, equalizer: Equalizer, immediately: Bool = false) {
        let volume = min(Self.maximumVolume, max(0, volume))
        targetGain = Float(volume) / 100
        if immediately { gain = targetGain }
        guard equalizer != currentEQ else { return }
        setBand(0, .lowShelf, 120, equalizer.low)
        setBand(1, .peak, 1000, equalizer.mid)
        setBand(2, .highShelf, 6000, equalizer.high)
        currentEQ = equalizer
    }

    private mutating func setBand(_ index: Int, _ shape: Shape, _ frequency: Double, _ decibels: Int) {
        let filter = Biquad(shape: shape, frequency: frequency, decibels: decibels, sampleRate: sampleRate)
        filters[index] = filter
        filters[index + 3] = filter
    }

    public mutating func process(left: Float, right: Float) -> (Float, Float) {
        gain += (targetGain - gain) * 0.01
        if abs(gain - targetGain) < 0.00001 { gain = targetGain }
        var left = left.isFinite ? left * gain : 0
        var right = right.isFinite ? right * gain : 0
        for index in 0..<3 {
            left = filters[index].process(left)
            right = filters[index + 3].process(right)
        }
        let peak = max(abs(left), abs(right))
        let ceilingGain: Float = peak > 1 ? 1 / peak : 1
        let recoveredGain = limiterGain + (1 - limiterGain) * limiterRecovery
        // Link both channels so a peak in one does not pull the stereo image sideways.
        limiterGain = min(ceilingGain, recoveredGain)
        if limiterGain > 0.99999 { limiterGain = ceilingGain }
        return (max(-1, min(1, left * limiterGain)), max(-1, min(1, right * limiterGain)))
    }
}

private enum Shape { case lowShelf, peak, highShelf }

private struct Biquad {
    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var z1: Float = 0
    private var z2: Float = 0

    init() {}

    init(shape: Shape, frequency: Double, decibels: Int, sampleRate: Double) {
        guard decibels != 0 else { return }
        let amplitude = pow(10, Double(decibels) / 40)
        let angle = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let cosine = cos(angle)
        let alpha = sin(angle) / sqrt(2)
        let shelf = 2 * sqrt(amplitude) * alpha
        let plus = amplitude + 1
        let minus = amplitude - 1
        let coefficients: (Double, Double, Double, Double, Double, Double)
        switch shape {
        case .lowShelf:
            coefficients = (
                amplitude * (plus - minus * cosine + shelf), 2 * amplitude * (minus - plus * cosine),
                amplitude * (plus - minus * cosine - shelf), plus + minus * cosine + shelf,
                -2 * (minus + plus * cosine), plus + minus * cosine - shelf
            )
        case .peak:
            coefficients = (
                1 + alpha * amplitude, -2 * cosine, 1 - alpha * amplitude,
                1 + alpha / amplitude, -2 * cosine, 1 - alpha / amplitude
            )
        case .highShelf:
            coefficients = (
                amplitude * (plus + minus * cosine + shelf), -2 * amplitude * (minus + plus * cosine),
                amplitude * (plus + minus * cosine - shelf), plus - minus * cosine + shelf,
                2 * (minus - plus * cosine), plus - minus * cosine - shelf
            )
        }
        let (b0, b1, b2, a0, a1, a2) = coefficients
        self.b0 = Float(b0 / a0)
        self.b1 = Float(b1 / a0)
        self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0)
        self.a2 = Float(a2 / a0)
    }

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }
}
