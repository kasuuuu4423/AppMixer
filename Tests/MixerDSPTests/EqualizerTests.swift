import Darwin
import Testing
import MixerDSP

@Test func flatSettingsPreserveStereo() {
    var processor = StereoProcessor(sampleRate: 48_000)
    let (left, right) = processor.process(left: 0.25, right: -0.75)
    #expect(left == 0.25)
    #expect(right == -0.75)
}

@Test func volumeConvergesAndMuteSettlesToZero() {
    var processor = StereoProcessor(sampleRate: 48_000)
    processor.configure(volume: 20, equalizer: Equalizer())
    for _ in 0..<2_000 { _ = processor.process(left: 1, right: -1) }
    let (left, right) = processor.process(left: 1, right: -1)
    #expect(abs(left - 0.2) < 0.0001)
    #expect(abs(right + 0.2) < 0.0001)

    processor.configure(volume: 0, equalizer: Equalizer())
    for _ in 0..<2_000 { _ = processor.process(left: 1, right: -1) }
    #expect(processor.process(left: 1, right: -1).0 == 0)
}

@Test(arguments: [44_100.0, 48_000.0])
func frequencyBandsAttenuateDifferentPartsOfTheSignal(sampleRate: Double) {
    #expect(level(frequency: 40, equalizer: Equalizer(low: -12), sampleRate: sampleRate) < 0.4)
    #expect(level(frequency: 1000, equalizer: Equalizer(mid: -12), sampleRate: sampleRate) < 0.4)
    #expect(level(frequency: 13_000, equalizer: Equalizer(high: -12), sampleRate: sampleRate) < 0.4)
    #expect(level(frequency: 13_000, equalizer: Equalizer(low: -12), sampleRate: sampleRate) > 0.95)
    #expect(level(frequency: 40, equalizer: Equalizer(high: -12), sampleRate: sampleRate) > 0.95)
}

@Test func twoHundredPercentDoublesQuietSignals() {
    var processor = StereoProcessor(sampleRate: 48_000)
    processor.configure(volume: 200, equalizer: Equalizer(), immediately: true)
    let (left, right) = processor.process(left: 0.2, right: -0.3)
    #expect(abs(left - 0.4) < 0.0001)
    #expect(abs(right + 0.6) < 0.0001)
}

@Test(arguments: [44_100.0, 48_000.0])
func bassBoostDoesNotAttenuateUnrelatedFrequencies(sampleRate: Double) {
    let bass = Equalizer(low: 12)
    #expect(level(frequency: 40, equalizer: bass, sampleRate: sampleRate) > 3.5)
    #expect(abs(level(frequency: 1000, equalizer: bass, sampleRate: sampleRate) - 1) < 0.01)
    #expect(abs(level(frequency: 4000, equalizer: bass, sampleRate: sampleRate) - 1) < 0.01)
}

@Test func limiterKeepsStereoBalanceAndRecoversAfterLoudPeak() {
    var processor = StereoProcessor(sampleRate: 48_000)
    processor.configure(volume: 200, equalizer: Equalizer(), immediately: true)
    let (left, right) = processor.process(left: 0.9, right: -0.45)
    #expect(abs(left - 1) < 0.0001)
    #expect(abs(right + 0.5) < 0.0001)
    let next = processor.process(left: 0.2, right: 0).0
    #expect(next > 0.2 && next < 0.3)
    for _ in 0..<24_000 { _ = processor.process(left: 0.2, right: 0) }
    #expect(abs(processor.process(left: 0.2, right: 0).0 - 0.4) < 0.0001)
}

private func level(frequency: Double, equalizer: Equalizer, sampleRate: Double) -> Double {
    var processor = StereoProcessor(sampleRate: sampleRate)
    processor.configure(volume: 100, equalizer: equalizer, immediately: true)
    var before = 0.0
    var after = 0.0
    for frame in 0..<Int(sampleRate / 2) {
        let input = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * 0.25)
        let (output, _) = processor.process(left: input, right: 0)
        guard frame > 4000 else { continue }
        before += Double(input * input)
        after += Double(output * output)
    }
    return sqrt(after / before)
}
