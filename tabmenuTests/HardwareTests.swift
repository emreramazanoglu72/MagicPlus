//
//  HardwareTests.swift
//  tabmenuTests
//

import Testing
import Foundation
@testable import tabmenu

@Suite("SMC wire format")
struct SMCParametersTests {
    /// The SMC user client takes a fixed 80-byte structure. Swift lays the fields out to
    /// match C here, and this is the one place where a wrong guess would be invisible: the
    /// call would simply return nothing on every key.
    @Test func theParameterBlockIsEightyBytes() {
        #expect(MemoryLayout<SMCParameters>.stride == 80)
    }

    /// Every field has to land where the C header puts it, not merely add up to the right
    /// total: a payload read from the wrong offset is the failure this pins down.
    @Test func everyFieldSitsWhereTheKernelExpectsIt() {
        #expect(MemoryLayout<SMCParameters>.offset(of: \.key) == 0)
        #expect(MemoryLayout<SMCParameters>.offset(of: \.version) == 4)
        #expect(MemoryLayout<SMCParameters>.offset(of: \.powerLimits) == 12)
        #expect(MemoryLayout<SMCParameters>.offset(of: \.keyInfo) == 28)
        #expect(MemoryLayout<SMCParameters>.offset(of: \.result) == 40)
        #expect(MemoryLayout<SMCParameters>.offset(of: \.status) == 41)
        #expect(MemoryLayout<SMCParameters>.offset(of: \.data8) == 42)
        #expect(MemoryLayout<SMCParameters>.offset(of: \.data32) == 44)
        #expect(MemoryLayout<SMCParameters>.offset(of: \.bytes) == 48)
    }

    @Test func keysRoundTripThroughTheirFourCharacterCode() {
        for key in ["#KEY", "TC0P", "F0Ac", "BCLM", "CH0B"] {
            #expect(SMCConnection.string(from: SMCConnection.code(key)) == key)
        }
    }
}

@Suite("SMC value decoding")
struct SMCDecodingTests {
    /// Fixed point: the last character of the type name is the number of fraction bits.
    @Test func signedFixedPointReadsAsDegrees() {
        #expect(SMCConnection.decode([0x2D, 0x00], type: "sp78") == 45)
        #expect(SMCConnection.decode([0x2D, 0x80], type: "sp78") == 45.5)
    }

    @Test func unsignedFixedPointReadsAsFanSpeed() {
        #expect(SMCConnection.decode([0x0F, 0xA0], type: "fpe2") == 1_000)
    }

    @Test func floatsAreLittleEndian() {
        let value = SMCConnection.decode([0x00, 0x00, 0x36, 0x42], type: "flt ")
        #expect(value == 45.5)
    }

    @Test func plainIntegersAreBigEndian() {
        #expect(SMCConnection.decode([0x01, 0x00], type: "ui16") == 256)
        #expect(SMCConnection.decode([0x50], type: "ui8 ") == 80)
    }

    @Test func negativeIntegersKeepTheirSign() {
        #expect(SMCConnection.decode([0xFF], type: "si8 ") == -1)
    }

    @Test func unknownTypesAreRefusedRatherThanGuessed() {
        #expect(SMCConnection.decode([0x01, 0x02, 0x03, 0x04], type: "ch8*") == nil)
        #expect(SMCConnection.decode([], type: "ui8 ") == nil)
    }
}

@Suite("Sensor grouping")
struct SensorCategoryTests {
    @Test func appleSiliconAndIntelKeysLandInTheSameGroups() {
        #expect(SensorCategory.forKey("Tp01") == .cpu)
        #expect(SensorCategory.forKey("TC0P") == .cpu)
        #expect(SensorCategory.forKey("Tg0D") == .gpu)
        #expect(SensorCategory.forKey("TG0P") == .gpu)
        #expect(SensorCategory.forKey("TB0T") == .battery)
        #expect(SensorCategory.forKey("TA0P") == .ambient)
    }

    @Test func unknownKeysAreStillReported() {
        #expect(SensorCategory.forKey("TZ99") == .other)
    }

    /// The hottest core is the number that matters; averaging a dozen sensors hides it.
    @Test func aGroupReportsItsHottestSensor() {
        let snapshot = SensorSnapshot(
            sensors: [
                SensorReading(key: "Tp01", category: .cpu, celsius: 48),
                SensorReading(key: "Tp05", category: .cpu, celsius: 71),
                SensorReading(key: "TB0T", category: .battery, celsius: 30)
            ],
            fans: [],
            isAvailable: true
        )
        #expect(snapshot.hottest(in: .cpu) == 71)
        #expect(snapshot.hottest(in: .gpu) == nil)
        #expect(snapshot.hottest?.key == "Tp05")
    }

    @Test func temperatureRatioStaysInsideTheBar() {
        #expect(Format.temperatureRatio(20) == 0)
        #expect(Format.temperatureRatio(120) == 1)
        #expect(Format.temperatureRatio(65) > 0.4)
        #expect(Format.temperatureRatio(65) < 0.6)
    }
}

@Suite("Fan readings")
struct FanReadingTests {
    @Test func aFanSittingAtItsMinimumReadsAsZero() {
        let fan = FanReading(index: 0, actual: 1_200, minimum: 1_200, maximum: 5_000)
        #expect(fan.ratio == 0)
        #expect(fan.isSpinning)
    }

    @Test func aFanAtFullSpeedReadsAsOne() {
        #expect(FanReading(index: 0, actual: 5_000, minimum: 1_200, maximum: 5_000).ratio == 1)
    }

    /// A machine that reports the same minimum and maximum must not divide by zero.
    @Test func aFanWithNoRangeIsHarmless() {
        #expect(FanReading(index: 0, actual: 0, minimum: 0, maximum: 0).ratio == 0)
    }
}

@Suite("Charge limit policy")
struct ChargeLimitPolicyTests {
    private let hysteresis = 0.05

    @Test func chargingStopsAtTheTarget() {
        #expect(ChargeLimitPolicy.shouldInhibit(level: 0.80, target: 0.80, hysteresis: hysteresis, isInhibited: false))
        #expect(ChargeLimitPolicy.shouldInhibit(level: 0.92, target: 0.80, hysteresis: hysteresis, isInhibited: false))
    }

    @Test func chargingResumesOnlyAfterTheBatteryHasFallenAway() {
        // Just below the target: whatever is happening keeps happening.
        #expect(ChargeLimitPolicy.shouldInhibit(level: 0.78, target: 0.80, hysteresis: hysteresis, isInhibited: true))
        #expect(!ChargeLimitPolicy.shouldInhibit(level: 0.78, target: 0.80, hysteresis: hysteresis, isInhibited: false))
        // Far enough below it that charging is worth switching back on.
        #expect(!ChargeLimitPolicy.shouldInhibit(level: 0.74, target: 0.80, hysteresis: hysteresis, isInhibited: true))
    }

    /// The reason the band exists: a battery resting on the target must not toggle charging
    /// on every tick.
    @Test func aBatteryRestingOnTheTargetDoesNotOscillate() {
        var isInhibited = false
        for level in [0.80, 0.79, 0.78, 0.79, 0.80, 0.79] {
            isInhibited = ChargeLimitPolicy.shouldInhibit(
                level: level,
                target: 0.80,
                hysteresis: hysteresis,
                isInhibited: isInhibited
            )
        }
        #expect(isInhibited)
    }
}

@Suite("Battery condition")
struct BatteryConditionTests {
    @Test func healthIsUnknownUntilTheBatteryReportsIt() {
        #expect(!BatteryCondition().isHealthKnown)
        var condition = BatteryCondition()
        condition.healthRatio = 0.91
        #expect(condition.isHealthKnown)
    }

    @Test func aMacWithoutABatteryReportsNothing() {
        let condition = BatteryCondition()
        #expect(!condition.isPresent)
        #expect(condition.minutesToFull == nil)
    }
}
