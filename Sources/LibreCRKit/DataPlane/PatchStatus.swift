import Foundation

public struct PatchStatus: Equatable, Sendable {
    public static let plaintextSize = 12

    public let lifeCount: Int16
    public let errorData: Int16
    public let eventDataRaw: Int16
    public let eventData: Int
    public let index: Int8
    public let totalEvents: Int
    public let patchState: Int8
    public let currentLifeCount: Int16
    public let stackDisconnectReason: Int8
    public let appDisconnectReason: Int8

    public var patchStateKind: Libre3PatchState {
        Libre3PatchState(rawValue: patchState)
    }

    public var hasErrorData: Bool {
        errorData != 0
    }

    /// Sensor error/condition decoded from `errorData`. Distinguishes a
    /// terminal sensor *failure* (the sensor has decided its quality is
    /// unrecoverably impaired and it must be replaced) from a normal
    /// end-of-wear `.expired` and from per-reading data-quality flags.
    /// See `Libre3SensorError` for the inference caveat on the mapping.
    public var sensorError: Libre3SensorError {
        Libre3SensorError(code: errorData)
    }

    /// `true` when the sensor reports an unrecoverable terminal failure
    /// (`.terminated` or `.insertionFailure`) — the sensor must be
    /// replaced. Deliberately `false` for `.expired`: normal end-of-wear
    /// is a graceful end, not a failure. A client that wants to treat
    /// expiry as session-ending too should check `sensorError == .expired`
    /// (or the lifecycle's `isExpired`) separately.
    public var isTerminalFailure: Bool {
        sensorError.isTerminal
    }

    public var hasDisconnectReason: Bool {
        stackDisconnectReason != 0 || appDisconnectReason != 0
    }

    public var defaultLifecycle: SensorLifecycle {
        lifecycle()
    }

    public var defaultLifecyclePhase: SensorLifecyclePhase {
        defaultLifecycle.phase
    }

    public var isInDefaultWarmup: Bool {
        defaultLifecycle.isWarmingUp
    }

    public func lifecycle(
        warmupDurationMinutes: Int = SensorLifecycle.defaultWarmupDurationMinutes,
        wearDurationMinutes: Int? = nil
    ) -> SensorLifecycle {
        SensorLifecycle(
            currentLifeCountMinutes: Int(currentLifeCount),
            warmupDurationMinutes: warmupDurationMinutes,
            wearDurationMinutes: wearDurationMinutes
        )
    }

    /// Lifecycle whose warmup and wear durations are taken from the NFC
    /// patch info rather than the assumed defaults.
    public func lifecycle(patchInfo: Libre3NFCPatchInfo) -> SensorLifecycle {
        lifecycle(
            warmupDurationMinutes: Int(patchInfo.warmupMinutes),
            wearDurationMinutes: Int(patchInfo.wearDurationMinutes)
        )
    }

    public init(plaintext: Data) throws {
        guard plaintext.count == Self.plaintextSize else {
            throw PatchStatusError.wrongPlaintextSize(plaintext.count)
        }
        self.lifeCount = Self.s16(plaintext, 0)
        self.errorData = Self.s16(plaintext, 2)
        self.eventDataRaw = Self.s16(plaintext, 4)
        self.eventData = 4000 + Int(self.eventDataRaw)
        self.index = Int8(bitPattern: plaintext[plaintext.startIndex + 6])
        self.totalEvents = Int(self.index) + 1
        self.patchState = Int8(bitPattern: plaintext[plaintext.startIndex + 7])
        self.currentLifeCount = Self.s16(plaintext, 8)
        self.stackDisconnectReason = Int8(bitPattern: plaintext[plaintext.startIndex + 10])
        self.appDisconnectReason = Int8(bitPattern: plaintext[plaintext.startIndex + 11])
    }

    private static func s16(_ data: Data, _ offset: Int) -> Int16 {
        Int16(bitPattern: u16(data, offset))
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }
}

public enum PatchStatusError: Error, Equatable {
    case wrongPlaintextSize(Int)
}

/// Sensor error code carried in the patch-status / event-log `errorData`
/// field. Mirrors the codes Abbott's app feeds into
/// `SensorState.Companion.from(MSLibre3SensorErrorEvent)`:
/// `3 → insertionFailure`, `5 → expired`, `6 → terminated`,
/// `7 → transmissionError`, `8 → terminated`; everything else is
/// `SENSOR_NO_ERROR`.
///
/// IMPORTANT — the numeric `errorData → code` mapping is INFERRED, not
/// yet confirmed against a captured terminal-failure frame. It rests on:
/// (a) healthy captures consistently showing `errorData == 0`, which
/// lines up with Abbott's `0 == SENSOR_NO_ERROR` fall-through, and
/// (b) the patch-status record sharing the exact
/// `{ lifeCount, errorData, eventData, index }` shape of Abbott's
/// `ABT_Event_Log`, whose `errorData` is the sensor error field. The
/// native DPCRL byte→code translation is not present in the decompiled
/// app, so treat `.terminated`/`.insertionFailure` as strong-signal but
/// validate against a real terminal capture before relying on it for
/// anything safety-critical.
public enum Libre3SensorError: Equatable, Sendable, CustomStringConvertible {
    /// No error (code 0) — the healthy steady state.
    case none
    /// Sensor failed to start / bad insertion (code 3). Terminal.
    case insertionFailure
    /// Normal end-of-wear (code 5). NOT a failure.
    case expired
    /// Unrecoverable sensor failure (codes 6 and 8). Terminal.
    case terminated
    /// Transient transmission error (code 7). Not terminal.
    case transmissionError
    /// Any other non-zero code we don't yet have evidence to name.
    case unknown(Int16)

    public init(code: Int16) {
        switch code {
        case 0:
            self = .none
        case 3:
            self = .insertionFailure
        case 5:
            self = .expired
        case 6, 8:
            self = .terminated
        case 7:
            self = .transmissionError
        default:
            self = .unknown(code)
        }
    }

    /// `true` for unrecoverable failures requiring sensor replacement.
    /// `.expired` is intentionally excluded — it is normal end-of-wear,
    /// not a failure. `.unknown` is excluded too: we won't assert a code
    /// we can't name is terminal.
    public var isTerminal: Bool {
        switch self {
        case .terminated, .insertionFailure:
            return true
        case .none, .expired, .transmissionError, .unknown:
            return false
        }
    }

    public var description: String {
        switch self {
        case .none:
            return "none"
        case .insertionFailure:
            return "insertionFailure"
        case .expired:
            return "expired"
        case .terminated:
            return "terminated"
        case .transmissionError:
            return "transmissionError"
        case .unknown(let code):
            return "unknown(\(code))"
        }
    }
}

public enum Libre3PatchState: Equatable, Sendable, CustomStringConvertible {
    case active
    case raw(Int8)

    public init(rawValue: Int8) {
        switch rawValue {
        case 4:
            self = .active
        default:
            self = .raw(rawValue)
        }
    }

    public var description: String {
        switch self {
        case .active:
            return "active"
        case .raw(let value):
            return "raw(\(value))"
        }
    }
}
