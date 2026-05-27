import Foundation
@preconcurrency import CoreBluetooth

#if canImport(UIKit) || canImport(AppKit)

// Connected-and-discovered session against a Libre 3 sensor. After
// `discoverAndSubscribe()` returns the session is ready to send/receive
// fragments per the BleFraming protocol.

public struct NotifyEvent: Sendable {
    public let characteristic: CBUUID
    public let fragment: Data       // raw notify payload (1B seq + chunk)
    public let receivedAt: Date
}

public struct SensorCharacteristicSnapshot: Sendable {
    public let uuidString: String
    public let serviceUUIDString: String
    public let properties: [String]
    public let isNotifying: Bool
}

public enum SensorSessionError: Error {
    case missingCharacteristic(CBUUID)
    case notifyFailed(CBUUID, Bool, String)
    case readFailed(CBUUID, String)
    case writeFailed(CBUUID, String)
    case disconnected(String?)
    case discoveryFailed(String)
}

public final class SensorSession: NSObject, @unchecked Sendable {
    public let peripheral: CBPeripheral
    private let queue: DispatchQueue
    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var discoveryContinuation: CheckedContinuation<Void, Error>?
    private struct PendingWrite {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let timeoutWorkItem: DispatchWorkItem?
    }
    private struct PendingRead {
        let box: PendingReadBox
    }
    private struct PendingNotifyChange {
        let enabled: Bool
        let box: PendingNotifyBox
    }
    private final class PendingReadBox: @unchecked Sendable {
        let id: UUID
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?

        init(id: UUID, continuation: CheckedContinuation<Data, Error>) {
            self.id = id
            self.continuation = continuation
        }

        func resume(returning data: Data) -> Bool {
            let cont = takeContinuation()
            guard let cont else { return false }
            cont.resume(returning: data)
            return true
        }

        func resume(throwing error: Error) -> Bool {
            let cont = takeContinuation()
            guard let cont else { return false }
            cont.resume(throwing: error)
            return true
        }

        private func takeContinuation() -> CheckedContinuation<Data, Error>? {
            lock.lock()
            defer { lock.unlock() }
            let cont = continuation
            continuation = nil
            return cont
        }
    }
    private final class PendingNotifyBox: @unchecked Sendable {
        let id: UUID
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(id: UUID, continuation: CheckedContinuation<Void, Error>) {
            self.id = id
            self.continuation = continuation
        }

        func resume() -> Bool {
            let cont = takeContinuation()
            guard let cont else { return false }
            cont.resume()
            return true
        }

        func resume(throwing error: Error) -> Bool {
            let cont = takeContinuation()
            guard let cont else { return false }
            cont.resume(throwing: error)
            return true
        }

        private func takeContinuation() -> CheckedContinuation<Void, Error>? {
            lock.lock()
            defer { lock.unlock() }
            let cont = continuation
            continuation = nil
            return cont
        }
    }
    private var pendingWrites: [CBUUID: [PendingWrite]] = [:]
    private var pendingReads: [CBUUID: [PendingRead]] = [:]
    private var pendingNotifyChanges: [CBUUID: [PendingNotifyChange]] = [:]
    private var notifyContinuations: [AsyncStream<NotifyEvent>.Continuation] = []
    private var servicesPendingChars: Int = 0
    private var notifyPending: Set<CBUUID> = []
    private var discoveryStartedAt: Date?
    private var serviceDiscoveredAt: Date?
    private var charsDiscoveredAt: Date?

    init(peripheral: CBPeripheral, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.queue = queue
        super.init()
        peripheral.delegate = self
    }

    /// Discovers the Libre 3 services + characteristics and subscribes to all
    /// notify-capable characteristics. Resolves once discovery is complete.
    /// Requests BOTH the data service (glucose/log channels) AND the security
    /// service (cert exchange + challenge channels) — Phase 1–6 needs both.
    public func discoverAndSubscribe() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                self.discoveryContinuation = cont
                self.discoveryStartedAt = Date()
                let cachedServices = (self.peripheral.services ?? []).map { $0.uuid.uuidString }
                BLETiming.log("discoverAndSubscribe: starting (peripheral.services cached count=\(cachedServices.count))")
                self.peripheral.discoverServices([
                    LibreSensorGATT.serviceUUID,
                    LibreSensorGATT.securityServiceUUID,
                ])
            }
        }
    }

    /// Stream of every incoming notify fragment, tagged by characteristic UUID.
    /// Multiple subscribers each get their own stream (broadcast). Yields on a
    /// terminated continuation are no-ops, so we never bother removing dead
    /// entries from the broadcast list.
    public func notifications() -> AsyncStream<NotifyEvent> {
        AsyncStream { cont in
            self.queue.async {
                self.notifyContinuations.append(cont)
            }
        }
    }

    public func characteristicSnapshots() async -> [SensorCharacteristicSnapshot] {
        await withCheckedContinuation { cont in
            queue.async {
                let snapshots = self.characteristics.values.map { chr in
                    SensorCharacteristicSnapshot(
                        uuidString: chr.uuid.uuidString,
                        serviceUUIDString: chr.service?.uuid.uuidString ?? "unknown",
                        properties: Self.propertyNames(chr.properties),
                        isNotifying: chr.isNotifying
                    )
                }.sorted { $0.uuidString < $1.uuidString }
                cont.resume(returning: snapshots)
            }
        }
    }

    /// Explicitly updates a characteristic notification subscription and waits
    /// for CoreBluetooth's CCCD acknowledgement.
    public func setNotify(_ enabled: Bool, for uuid: CBUUID, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let chr = self.characteristics[uuid] else {
                    cont.resume(throwing: SensorSessionError.missingCharacteristic(uuid))
                    return
                }
                guard chr.properties.contains(.notify) || chr.properties.contains(.indicate) else {
                    cont.resume(
                        throwing: SensorSessionError.notifyFailed(uuid, enabled, "Characteristic is not notifiable")
                    )
                    return
                }
                if chr.isNotifying == enabled {
                    cont.resume()
                    return
                }

                let box = PendingNotifyBox(id: UUID(), continuation: cont)
                self.pendingNotifyChanges[uuid, default: []].append(
                    PendingNotifyChange(enabled: enabled, box: box)
                )
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self, box] in
                    guard box.resume(
                        throwing: SensorSessionError.notifyFailed(
                            uuid,
                            enabled,
                            String(format: "Timed out waiting %.1fs for notification state", timeout)
                        )
                    ) else { return }
                    self?.queue.async {
                        self?.removePendingNotifyChange(uuid: uuid, id: box.id)
                    }
                }
                self.peripheral.setNotifyValue(enabled, for: chr)
            }
        }
    }

    /// Refresh CCCDs on the data-plane characteristics with an off→on cycle.
    ///
    /// After Phase 6 (or any subsequent re-handshake against the same
    /// sensor) the BLE link is open but the sensor will not start streaming
    /// glucose/status until each data-plane notify characteristic has its
    /// CCCD re-armed. Calling this method right after the handshake
    /// completes is what kicks the sensor into broadcasting; without it
    /// the link stays silent and eventually drops.
    ///
    /// By default this refreshes the five characteristics that experimental
    /// captures show the sensor expects to be re-armed
    /// (`LibreSensorGATT.Char.dataPlaneNotifying`): `patchControl`,
    /// `eventLog`, `factoryData`, `glucoseData`, `patchStatus`. Callers can
    /// pass an alternative list for narrower refreshes.
    ///
    /// - Parameters:
    ///   - characteristics: UUIDs to refresh. Defaults to
    ///     `LibreSensorGATT.Char.dataPlaneNotifying`.
    ///   - perCharacteristicTimeout: Per-`setNotify` timeout.
    ///   - settleDelay: Sleep between toggles. Empirically a brief settle
    ///     (≈90ms) avoids the sensor missing the off→on transition.
    public func refreshDataPlaneNotifications(
        characteristics: [CBUUID] = LibreSensorGATT.Char.dataPlaneNotifying,
        perCharacteristicTimeout: TimeInterval = 8,
        settleDelay: TimeInterval = 0.09
    ) async throws {
        for uuid in characteristics {
            try await setNotify(false, for: uuid, timeout: perCharacteristicTimeout)
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
            try await setNotify(true, for: uuid, timeout: perCharacteristicTimeout)
            try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        }
    }

    /// Fragments `payload` per BleFraming and writes each fragment with response.
    /// Resolves when all fragments have been ACKed by the peripheral.
    public func send(_ payload: Data, to uuid: CBUUID) async throws {
        let fragments = BleFraming.fragmentForWrite(payload)
        for frag in fragments {
            try await writeFragment(frag, to: uuid)
        }
    }

    /// Raw write — no BleFraming offset prefix. For single-byte command-channel
    /// writes (e.g. the security state-machine clock byte on 0x0027).
    public func writeRaw(_ data: Data, to uuid: CBUUID) async throws {
        try await writeFragment(data, to: uuid)
    }

    /// Raw write with a response timeout. Use this for post-auth control writes,
    /// where a busy sensor may neither ACK nor deliver an ATT error promptly.
    public func writeRaw(_ data: Data, to uuid: CBUUID, timeout: TimeInterval) async throws {
        try await writeFragment(data, to: uuid, timeout: timeout)
    }

    /// Raw read with a response timeout. CoreBluetooth delivers read responses
    /// through the same delegate callback as notifications, so callers should
    /// expect the returned value to also appear on `notifications()`.
    public func readRaw(_ uuid: CBUUID, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async {
                guard let chr = self.characteristics[uuid] else {
                    cont.resume(throwing: SensorSessionError.missingCharacteristic(uuid))
                    return
                }
                guard chr.properties.contains(.read) else {
                    cont.resume(throwing: SensorSessionError.readFailed(uuid, "Characteristic is not readable"))
                    return
                }
                let box = PendingReadBox(id: UUID(), continuation: cont)
                self.pendingReads[uuid, default: []].append(PendingRead(box: box))
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) { [weak self, box] in
                    guard box.resume(
                        throwing: SensorSessionError.readFailed(
                            uuid,
                            String(format: "Timed out waiting %.1fs for read response", timeout)
                        )
                    ) else { return }
                    self?.queue.async {
                        self?.removePendingRead(uuid: uuid, id: box.id)
                    }
                }
                self.peripheral.readValue(for: chr)
            }
        }
    }

    private func removePendingRead(uuid: CBUUID, id: UUID) {
        guard var reads = pendingReads[uuid],
              let index = reads.firstIndex(where: { $0.box.id == id }) else {
            return
        }
        reads.remove(at: index)
        if reads.isEmpty {
            pendingReads.removeValue(forKey: uuid)
        } else {
            pendingReads[uuid] = reads
        }
    }

    private func removePendingNotifyChange(uuid: CBUUID, id: UUID) {
        guard var changes = pendingNotifyChanges[uuid],
              let index = changes.firstIndex(where: { $0.box.id == id }) else {
            return
        }
        changes.remove(at: index)
        if changes.isEmpty {
            pendingNotifyChanges.removeValue(forKey: uuid)
        } else {
            pendingNotifyChanges[uuid] = changes
        }
    }

    private func writeFragment(_ fragment: Data, to uuid: CBUUID, timeout: TimeInterval? = nil) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let chr = self.characteristics[uuid] else {
                    cont.resume(throwing: SensorSessionError.missingCharacteristic(uuid))
                    return
                }
                let writeID = UUID()
                let timeoutWorkItem: DispatchWorkItem?
                if let timeout {
                    timeoutWorkItem = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        guard var writes = self.pendingWrites[uuid],
                              let index = writes.firstIndex(where: { $0.id == writeID }) else {
                            return
                        }
                        let pending = writes.remove(at: index)
                        if writes.isEmpty {
                            self.pendingWrites.removeValue(forKey: uuid)
                        } else {
                            self.pendingWrites[uuid] = writes
                        }
                        pending.continuation.resume(
                            throwing: SensorSessionError.writeFailed(
                                uuid,
                                String(format: "Timed out waiting %.1fs for write response", timeout)
                            )
                        )
                    }
                } else {
                    timeoutWorkItem = nil
                }
                self.pendingWrites[uuid, default: []].append(
                    PendingWrite(id: writeID, continuation: cont, timeoutWorkItem: timeoutWorkItem)
                )
                self.peripheral.writeValue(fragment, for: chr, type: .withResponse)
                if let timeout, let timeoutWorkItem {
                    self.queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
                }
            }
        }
    }

    func handleDisconnect(error: Error?) {
        let msg = error?.localizedDescription
        queue.async {
            for (_, conts) in self.pendingWrites {
                for c in conts {
                    c.timeoutWorkItem?.cancel()
                    c.continuation.resume(throwing: SensorSessionError.disconnected(msg))
                }
            }
            self.pendingWrites.removeAll()
            for (_, conts) in self.pendingReads {
                for c in conts {
                    _ = c.box.resume(throwing: SensorSessionError.disconnected(msg))
                }
            }
            self.pendingReads.removeAll()
            for (_, conts) in self.pendingNotifyChanges {
                for c in conts {
                    _ = c.box.resume(throwing: SensorSessionError.disconnected(msg))
                }
            }
            self.pendingNotifyChanges.removeAll()
            for cont in self.notifyContinuations { cont.finish() }
            self.notifyContinuations.removeAll()
            if let cont = self.discoveryContinuation {
                self.discoveryContinuation = nil
                cont.resume(throwing: SensorSessionError.disconnected(msg))
            }
        }
    }

    private static func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
        var names: [String] = []
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.writeWithoutResponse) { names.append("writeWithoutResponse") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("authenticatedSignedWrites") }
        if properties.contains(.extendedProperties) { names.append("extendedProperties") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notifyEncryptionRequired") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicateEncryptionRequired") }
        return names
    }
}

extension SensorSession: CBPeripheralDelegate {

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            finishDiscovery(.failure(SensorSessionError.discoveryFailed(error.localizedDescription)))
            return
        }
        let wanted: Set<CBUUID> = [
            LibreSensorGATT.serviceUUID,
            LibreSensorGATT.securityServiceUUID,
        ]
        let services = (peripheral.services ?? []).filter { wanted.contains($0.uuid) }
        if let start = discoveryStartedAt {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            BLETiming.log("didDiscoverServices: \(services.count) wanted service(s) found after \(ms)ms")
        }
        serviceDiscoveredAt = Date()
        guard !services.isEmpty else {
            finishDiscovery(.failure(SensorSessionError.discoveryFailed("no Libre 3 services found")))
            return
        }
        // Track how many service-discoveries we expect before finishing.
        servicesPendingChars = services.count
        for svc in services {
            let cachedChars = (svc.characteristics ?? []).count
            BLETiming.log("discoverCharacteristics for service \(svc.uuid.uuidString) (cached count=\(cachedChars))")
            peripheral.discoverCharacteristics(LibreSensorGATT.Char.all, for: svc)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            finishDiscovery(.failure(SensorSessionError.discoveryFailed(error.localizedDescription)))
            return
        }
        if let start = serviceDiscoveredAt {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            BLETiming.log("didDiscoverCharacteristicsFor \(service.uuid.uuidString) after \(ms)ms; \((service.characteristics ?? []).count) char(s)")
        }
        var notifyRequested = 0
        for chr in service.characteristics ?? [] {
            characteristics[chr.uuid] = chr
            if chr.properties.contains(.notify) {
                if chr.isNotifying {
                    BLETiming.log("setNotifyValue: skipping \(chr.uuid.uuidString) — already notifying")
                } else {
                    notifyPending.insert(chr.uuid)
                    notifyRequested += 1
                    peripheral.setNotifyValue(true, for: chr)
                }
            }
        }
        if notifyRequested > 0 {
            BLETiming.log("setNotifyValue(true) issued for \(notifyRequested) char(s) on \(service.uuid.uuidString)")
        }
        servicesPendingChars -= 1
        // Wait for ALL services' characteristic discovery and all notify
        // subscriptions to be acknowledged before reporting the session ready.
        if servicesPendingChars <= 0 && notifyPending.isEmpty {
            if let start = discoveryStartedAt {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                BLETiming.log("discoverAndSubscribe: complete in \(ms)ms (all notify subs already on)")
            }
            finishDiscovery(.success(()))
        } else if servicesPendingChars <= 0 {
            charsDiscoveredAt = Date()
            BLETiming.log("discoverAndSubscribe: char discovery done; awaiting \(notifyPending.count) notify ack(s)")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let pending = pendingNotifyChanges[characteristic.uuid]?.first {
            pendingNotifyChanges[characteristic.uuid] = Array(pendingNotifyChanges[characteristic.uuid]!.dropFirst())
            if pendingNotifyChanges[characteristic.uuid]?.isEmpty == true {
                pendingNotifyChanges.removeValue(forKey: characteristic.uuid)
            }

            if let error {
                _ = pending.box.resume(
                    throwing: SensorSessionError.notifyFailed(
                        characteristic.uuid,
                        pending.enabled,
                        error.localizedDescription
                    )
                )
            } else if characteristic.isNotifying == pending.enabled {
                _ = pending.box.resume()
            } else {
                _ = pending.box.resume(
                    throwing: SensorSessionError.notifyFailed(
                        characteristic.uuid,
                        pending.enabled,
                        "Characteristic state did not match requested state"
                    )
                )
            }
        } else if let error {
            finishDiscovery(.failure(SensorSessionError.discoveryFailed(error.localizedDescription)))
            return
        }

        if characteristic.isNotifying {
            notifyPending.remove(characteristic.uuid)
        }
        if servicesPendingChars <= 0 && notifyPending.isEmpty {
            if let start = discoveryStartedAt {
                let totalMs = Int(Date().timeIntervalSince(start) * 1000)
                let charsToNotifyMs = charsDiscoveredAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
                BLETiming.log("discoverAndSubscribe: complete in \(totalMs)ms (notify-ack phase \(charsToNotifyMs)ms)")
            }
            finishDiscovery(.success(()))
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let conts = pendingReads[characteristic.uuid], !conts.isEmpty {
            pendingReads[characteristic.uuid] = Array(conts.dropFirst())
            let pending = conts.first!
            if let error = error {
                _ = pending.box.resume(
                    throwing: SensorSessionError.readFailed(characteristic.uuid, error.localizedDescription)
                )
            } else if let value = characteristic.value {
                _ = pending.box.resume(returning: value)
            } else {
                _ = pending.box.resume(
                    throwing: SensorSessionError.readFailed(characteristic.uuid, "Read returned no value")
                )
            }
        }

        guard error == nil, let value = characteristic.value else { return }
        let event = NotifyEvent(characteristic: characteristic.uuid, fragment: value, receivedAt: Date())
        for cont in notifyContinuations { cont.yield(event) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let conts = pendingWrites[characteristic.uuid] ?? []
        if !conts.isEmpty {
            pendingWrites[characteristic.uuid] = Array(conts.dropFirst())
            conts.first!.timeoutWorkItem?.cancel()
            if let error = error {
                conts.first!.continuation.resume(
                    throwing: SensorSessionError.writeFailed(characteristic.uuid, error.localizedDescription)
                )
            } else {
                conts.first!.continuation.resume()
            }
        }
    }

    private func finishDiscovery(_ result: Result<Void, Error>) {
        guard let cont = discoveryContinuation else { return }
        discoveryContinuation = nil
        switch result {
        case .success: cont.resume()
        case .failure(let e): cont.resume(throwing: e)
        }
    }
}

#endif
