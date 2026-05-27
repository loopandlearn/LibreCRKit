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
