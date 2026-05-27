import Foundation

public struct Libre3ReceiverID: Equatable, Hashable, Sendable, Codable {
    public let value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    public init(accountlessUniqueID: String) {
        self.value = Self.accountlessValue(from: accountlessUniqueID)
    }

    public init(littleEndianHex: String) throws {
        guard let value = Self.parseLittleEndianHex(littleEndianHex) else {
            throw Libre3ReceiverIDError.invalidLittleEndianHex(littleEndianHex)
        }
        self.value = value
    }

    public var littleEndianData: Data {
        Data([
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ])
    }

    public var littleEndianHex: String {
        littleEndianData.map { String(format: "%02x", $0) }.joined()
    }

    public var displayString: String {
        String(format: "0x%08x / %@", value, littleEndianHex)
    }

    public static func accountlessValue(from uniqueID: String) -> UInt32 {
        var value: UInt32 = 0
        for unit in uniqueID.utf16 {
            value = (value &* 0x811c9dc5) ^ UInt32(unit)
        }
        return value
    }

    public static func parseLittleEndianHex(_ raw: String) -> UInt32? {
        let cleaned = raw
            .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
            .filter { $0.isHexDigit }
        guard cleaned.count == 8 else { return nil }

        var bytes = [UInt8]()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }

        return UInt32(bytes[0]) |
            (UInt32(bytes[1]) << 8) |
            (UInt32(bytes[2]) << 16) |
            (UInt32(bytes[3]) << 24)
    }
}

public enum Libre3ReceiverIDError: Error, Equatable {
    case invalidLittleEndianHex(String)
}
