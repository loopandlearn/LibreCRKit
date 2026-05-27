import Foundation

/// Decoded clinical-stream record (0x08981ab8). Distinct from
/// `HistoricalReadingPage`: clinical pages are NOT six samples at
/// 5-minute stride — each page is a single time-point record with six
/// 16-bit fields, emitted once per minute while the sensor is connected.
/// Field semantics were determined against ground truth where realtime
/// forwards and historical backfill at known lifeCounts let us pin each
/// field's meaning:
///
/// | word | meaning                                                  |
/// | ---- | -------------------------------------------------------- |
/// |  0   | `lifeCount` — current minute (page emitted per minute)   |
/// |  1   | unknown raw sensor field (observed 0x4700–0x4900)        |
/// |  2   | unknown raw sensor field (observed 0x0e80–0x0f20)        |
/// |  3   | reserved / zero (only 0x0000 observed)                   |
/// |  4   | minute-resolution glucose at `lifeCount` (low byte mg/dL)|
/// |  5   | most recent 5-minute committed (smoothed) glucose value  |
///
/// Word[4] is the same per-minute value the realtime stream emits each
/// minute. Word[5] is the same per-five-minute smoothed value the
/// historical stream emits, but trailing the current lifeCount by
/// `smoothedGlucoseLifeCountOffset` (observed at 17 across all samples;
/// modeling as a constant pending more captures).
///
/// Practical use: the clinical stream is the only published way to
/// backfill *minute-resolution* glucose during a disconnect window —
/// historical only persists 5-min boundaries. Apps integrating this
/// should consume `currentGlucose` keyed by `lifeCount`.
public struct ClinicalReadingRecord: Equatable, Sendable {
    public static let plaintextSize = 14

    /// LifeCount of this clinical record (per-minute granularity).
    public let lifeCount: UInt16

    public let reservedWord1: UInt16
    public let reservedWord2: UInt16
    public let reservedWord3: UInt16

    /// Raw 16-bit current-minute glucose value. Feed to
    /// `Libre3GlucoseValueStatus(rawSensorValue:)` to get mg/dL.
    public let currentGlucoseRaw: UInt16

    /// Raw 16-bit most-recent 5-min smoothed glucose value. Its lifeCount
    /// is `lifeCount &- Self.smoothedGlucoseLifeCountOffset`.
    public let smoothedGlucoseRaw: UInt16

    /// Observed delay (in lifeCounts/minutes) between the current
    /// `lifeCount` and the lifeCount that `smoothedGlucoseRaw` represents.
    /// Always 17 in captured data; modeled as a constant pending evidence
    /// of variance.
    public static let smoothedGlucoseLifeCountOffset: UInt16 = 17

    public init(plaintext: Data) throws {
        guard plaintext.count == Self.plaintextSize else {
            throw ClinicalReadingRecordError.wrongPlaintextSize(plaintext.count)
        }
        let words = stride(from: 0, to: plaintext.count, by: 2).map { offset -> UInt16 in
            UInt16(plaintext[offset]) | (UInt16(plaintext[offset + 1]) << 8)
        }
        self.lifeCount = words[0]
        self.reservedWord1 = words[1]
        self.reservedWord2 = words[2]
        self.reservedWord3 = words[3]
        self.currentGlucoseRaw = words[4]
        self.smoothedGlucoseRaw = words[5]
    }

    public var currentGlucose: Libre3GlucoseValueStatus {
        Libre3GlucoseValueStatus(rawSensorValue: currentGlucoseRaw)
    }

    public var currentGlucoseMgDL: UInt16? {
        currentGlucose.displayMgDL
    }

    public var smoothedGlucose: Libre3GlucoseValueStatus {
        Libre3GlucoseValueStatus(rawSensorValue: smoothedGlucoseRaw)
    }

    public var smoothedGlucoseMgDL: UInt16? {
        smoothedGlucose.displayMgDL
    }

    /// LifeCount that `smoothedGlucoseRaw` represents.
    public var smoothedLifeCount: UInt16 {
        lifeCount &- Self.smoothedGlucoseLifeCountOffset
    }
}

public enum ClinicalReadingRecordError: Error, Equatable {
    case wrongPlaintextSize(Int)
}
