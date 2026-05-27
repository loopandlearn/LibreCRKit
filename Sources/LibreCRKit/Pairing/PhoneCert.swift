import Foundation

// Phone certificate — 162 bytes, sent as the first phone-→sensor write
// during a fresh-pair handshake (Phase 1, handle 0x002d).
//
// Format:
//
//   [0..2)    msg_type / version  (e.g. 03 03 or 03 00)
//   [2..18)   16B test pattern    (canonically 01 02 03 ... 0f 10)
//   [18..33)  15B header          (00 01 61 89 76 55 01 + 8 zero bytes)
//   [33]      0x04 (P-256 uncompressed-point prefix)
//   [34..98)  X(32) || Y(32)      ← phone STATIC pubkey
//   [98..162) ECDSA signature     (64B raw r || s)
//
// 2026-05-09 live-device correction:
// `phone_cert_firstpair.bin` (`03 00...`) was rejected before
// CertificateAccepted by a fresh sensor, while captured `phone_cert_162b.bin`
// (`03 03...`) passed cert acceptance but still failed before Phase 6 with the
// index-0/default Phase 5 static scalar. Harness replay with the index-1
// private blob shows `03 03` needs the native index-1 static scalar window
// below. A live rerun with that correction still failed
// before Phase 6, so this scalar selection is necessary evidence, not a
// complete first-pair source/state fix.

public struct PhoneCert: Equatable, Sendable {
    public let raw: Data           // full 162B blob
    public let staticPub: Data     // 65B uncompressed P-256 point (with 0x04 prefix)

    public static let totalSize: Int = 162
    public static let pubkeyRange: Range<Int> = 33..<98

    public init(raw: Data) throws {
        guard raw.count == Self.totalSize else { throw PhoneCertError.wrongSize(raw.count) }
        let pub = raw.subdata(in: Self.pubkeyRange)
        guard pub.first == 0x04 else { throw PhoneCertError.notUncompressedPoint }
        self.raw = raw
        self.staticPub = pub
    }

    /// First-pair Phase 5 static-scalar policy inferred from the cert family.
    /// `03 00` uses the older entry-source-derived scalar; `03 03` uses the
    /// observed index-1 native scalar window. This does not by itself
    /// prove that the remaining native first-pair source/state is complete.
    public var phase5StaticScalarWindowOverride: Data? {
        guard raw.prefix(2).elementsEqual([0x03, 0x03]) else { return nil }
        return FirstPairStaticScalarWindow.firstPairIndex1
    }

    /// Loads the bundled `phone_cert_firstpair.bin` candidate. This is kept as
    /// the default resource for tests and controlled experiments, but live
    /// fresh-sensor testing has shown it is not universally accepted.
    public static func bundledFirstPair() throws -> PhoneCert {
        try bundled(named: "phone_cert_firstpair")
    }

    static func bundled(named resource: String) throws -> PhoneCert {
        guard let url = Bundle.module.url(
            forResource: resource,
            withExtension: "bin",
            subdirectory: "RuntimeTables"
        ) else {
            throw PhoneCertError.bundledResourceMissing(resource)
        }
        return try PhoneCert(raw: try Data(contentsOf: url))
    }
}

public enum FirstPairStaticScalarWindow {
    private static let firstPairIndex1Prefix: [UInt8] = [
        0x97, 0x8d, 0x11, 0xed, 0x64, 0x6e, 0xe3, 0x55,
        0x93, 0x36, 0xd5, 0xfe, 0xba, 0x58, 0x7c, 0xe9,
        0x84, 0x12, 0x31, 0x98, 0xcd, 0x9e, 0x88, 0x0d,
        0x34, 0xba, 0xd0, 0xfa, 0xc8, 0xa9, 0x97, 0xbf,
    ]

    /// Native `0x6388f0` row-59 static scalar window for the Abbott
    /// cert-private index 1 (`03 03` cert family).
    public static let firstPairIndex1 = Data(
        firstPairIndex1Prefix + [UInt8](repeating: 0, count: 38)
    )
}

public enum PhoneCertError: Error, Equatable {
    case wrongSize(Int)
    case notUncompressedPoint
    case bundledResourceMissing(String)
}
