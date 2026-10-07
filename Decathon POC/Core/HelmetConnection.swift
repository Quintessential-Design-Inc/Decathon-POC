import CoreBluetooth
import Foundation
import Observation
import QuinKitBLE
import QuinKitLogger

/// Owns one selected connection and its notification consumers across view updates.
@MainActor
@Observable
final class HelmetConnection {
    private(set) var helmet: DiscoveredHelmet?
    private(set) var phase: ConnectionPreparationPhase = .idle
    private(set) var services: [QKService] = []
    private(set) var profile: DecathlonProfile?
    private(set) var enabledNotificationIDs: Set<String> = []
    private(set) var dataNotificationCount = 0
    private(set) var alertNotificationCount = 0
    private(set) var lastAlert: String?
    private(set) var isOperationRunning = false
    private(set) var battery: HelmetBatteryReading?
    private(set) var temperature: HelmetTemperatureReading?
    private(set) var activity: HelmetActivity?
    private(set) var activityReceivedAt: Date?
    private(set) var thresholds: HelmetCrashThresholds?
    private(set) var deviceInformation: [HelmetDeviceInfoField: String] = [:]
    private(set) var batteryReadIssue: String?
    private(set) var thresholdReadIssue: String?
    private(set) var deviceInformationIssues: [HelmetDeviceInfoField: String] = [:]
    private(set) var isReadingDashboard = false
    let retrieval = OfflineRetrieval()

    @ObservationIgnored private weak var manager: QKBLEManager?
    @ObservationIgnored private var peripheral: QKPeripheral?
    @ObservationIgnored private var attemptID = UUID()
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var dashboardReadTask: Task<Void, Never>?

    deinit {
        preparationTask?.cancel()
        dashboardReadTask?.cancel()
        for task in notificationTasks { task.cancel() }
    }

    var canSelectHelmet: Bool {
        !isOperationRunning && !retrieval.isBusy && peripheral == nil && (manager?.connectedPeripherals.isEmpty ?? true)
    }

    var canRetrieveOfflineData: Bool {
        phase == .ready && !isReadingDashboard && !retrieval.isBusy && !retrieval.requiresReconnect &&
            peripheral?.isConnected == true && profile != nil &&
            enabledNotificationIDs.count == 2 && (thresholds.map { $0.crashMode & 0x02 == 0 } ?? true)
    }

    func retrieveOfflineData() async {
        guard canRetrieveOfflineData, let helmet, let peripheral, let profile else { return }
        let context = OfflineDownloadContext(
            id: UUID(), peripheralID: helmet.id, deviceName: helmet.name,
            macAddress: helmet.advertisement.macAddress,
            advertisedEventCount: helmet.advertisement.storedEventCount, startedAt: Date(),
            deviceInformation: Dictionary(uniqueKeysWithValues: deviceInformation.map { ($0.key.rawValue, $0.value) })
        )
        await retrieval.start(context: context, peripheral: peripheral, profile: profile)
    }

    func start(helmet: DiscoveredHelmet, manager: QKBLEManager) {
        guard canSelectHelmet, manager.isBluetoothReady, manager.connectedPeripherals.isEmpty else { return }
        self.manager = manager
        self.helmet = helmet
        services = []
        profile = nil
        enabledNotificationIDs = []
        dataNotificationCount = 0
        alertNotificationCount = 0
        lastAlert = nil
        battery = nil
        temperature = nil
        activity = nil
        activityReceivedAt = nil
        thresholds = nil
        deviceInformation = [:]
        batteryReadIssue = nil
        thresholdReadIssue = nil
        deviceInformationIssues = [:]
        isReadingDashboard = false
        retrieval.resetForConnection()
        let id = UUID()
        attemptID = id
        phase = .connecting
        isOperationRunning = true
        QKLog.debug(tag: "Connection", "Connecting to selected helmet", helmet.id, helmet.advertisement.macAddress)
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isOperationRunning = false
                self.preparationTask = nil
            }
            await self.prepare(helmet: helmet, manager: manager, attempt: id)
        }
    }

    func disconnect(reason: String = "Disconnected. Double-tap the helmet before scanning again.") {
        guard helmet != nil else { return }
        stop(with: .disconnected(reason))
    }

    func handleDisconnect(peripheralID: UUID, error: QKBLEError?) {
        guard helmet?.id == peripheralID else { return }
        peripheral = nil
        switch phase {
        case .failed, .disconnected, .idle:
            break
        default:
            stop(with: .disconnected(error.map { "Connection lost. \($0.localizedDescription)" }
                ?? "The helmet disconnected. It may have gone to sleep. Wake it and double-tap before scanning again."))
        }
        QKLog.debug(tag: "Connection", "Peripheral disconnected", peripheralID, error?.localizedDescription ?? "No BLE error")
    }

    private func prepare(helmet: DiscoveredHelmet, manager: QKBLEManager, attempt: UUID) async {
        do {
            try checkAttempt(attempt)
            let connected = try await manager.connect(helmet.scanResult, timeout: 15)
            guard attemptID == attempt, !Task.isCancelled else {
                manager.disconnect(connected)
                return
            }
            peripheral = connected
            QKLog.debug(tag: "Connection", "Connected; beginning service discovery", connected.id)
            phase = .discoveringServices
            services = try await connected.discoverServices(timeout: 10)
            try checkAttempt(attempt)

            phase = .discoveringCharacteristics
            for service in services {
                QKLog.debug(tag: "Profile", "Discovered service", service.uuid.uuidString)
                let characteristics = try await connected.discoverCharacteristics(for: service, timeout: 10)
                try checkAttempt(attempt)
                services = connected.services
                for characteristic in characteristics {
                    QKLog.debug(tag: "Profile", "Discovered characteristic", characteristic.id, characteristic.propertySummary)
                }
            }

            phase = .validatingProfile
            let resolved = try DecathlonProfile(services: services)
            profile = resolved
            QKLog.debug(tag: "Profile", "Validated discovered channels", resolved.data.id, resolved.alerts.id,
                        resolved.data.supportsWriteWithResponse ? "Data write with response" : "Data write without response")

            // notificationStream registers its continuation synchronously. Register
            // BOTH consumers before the first CCCD is enabled so early values are caught.
            registerNotifications(for: resolved.data, peripheral: connected, attempt: attempt, isData: true)
            registerNotifications(for: resolved.alerts, peripheral: connected, attempt: attempt, isData: false)
            phase = .enablingNotifications
            for characteristic in [resolved.data, resolved.alerts] {
                try checkAttempt(attempt)
                try await connected.setNotify(true, for: characteristic, timeout: 10)
                try checkAttempt(attempt)
                services = connected.services
                guard connected.characteristic(serviceUUID: characteristic.serviceUUID, uuid: characteristic.uuid)?.isNotifying == true else {
                    throw ProfileError("Notification setup was not confirmed for \(characteristic.uuid.uuidString).")
                }
                enabledNotificationIDs.insert(characteristic.id)
                QKLog.debug(tag: "Notifications", "Confirmed value updates enabled", characteristic.id)
            }
            try checkAttempt(attempt)
            phase = .ready
            QKLog.debug(tag: "Connection", "Connection preparation complete; RTC setup remains pending", connected.id)
            beginDashboardReads(peripheral: connected, profile: resolved, attempt: attempt)
        } catch {
            guard attemptID == attempt else { return }
            QKLog.error(tag: "Connection", "Connection preparation failed", phase.title, error)
            stop(with: .failed(error.localizedDescription))
        }
    }

    private func checkAttempt(_ id: UUID) throws {
        guard attemptID == id, !Task.isCancelled else { throw CancellationError() }
        guard manager?.isBluetoothReady == true else {
            throw ProfileError("Bluetooth is unavailable. Restore Bluetooth access and scan again.")
        }
        if let peripheral, !peripheral.isConnected {
            throw ProfileError("The helmet disconnected during preparation. Double-tap it and scan again.")
        }
    }

    private func registerNotifications(for characteristic: QKCharacteristic, peripheral: QKPeripheral, attempt: UUID, isData: Bool) {
        let stream = peripheral.notificationStream(for: characteristic)
        notificationTasks.append(Task { @MainActor [weak self] in
            do {
                for try await value in stream {
                    guard !Task.isCancelled, let self, self.attemptID == attempt else { return }
                    if isData {
                        self.dataNotificationCount += 1
                        await self.retrieval.receive(value, at: Date())
                        QKLog.debug(tag: "Notifications", "Data notification received", value.count, self.dataNotificationCount)
                    } else {
                        self.alertNotificationCount += 1
                        self.lastAlert = String(data: value.prefix(512), encoding: .utf8) ?? "Non-text alert (\(value.count) bytes)"
                        self.receiveAlert(value, at: Date(), fromRead: false)
                        QKLog.debug(tag: "Notifications", "Alert received", self.lastAlert ?? "", self.alertNotificationCount)
                    }
                }
                guard !Task.isCancelled, let self, self.attemptID == attempt else { return }
                self.stop(with: .failed("A notification channel closed. Double-tap the helmet and scan again."))
            } catch {
                guard !Task.isCancelled, let self, self.attemptID == attempt else { return }
                QKLog.error(tag: "Notifications", "Notification channel failed", characteristic.id, error)
                self.stop(with: .failed("Notification channel failed. \(error.localizedDescription)"))
            }
        })
    }

    private func receiveAlert(_ data: Data, at date: Date, fromRead: Bool, readStartedAt: Date? = nil) {
        guard let alert = HelmetAlert(data: data) else { return }
        switch alert {
        case .battery(let percentage, let category, let celsius):
            // A cached read must not replace a notification received after the read began.
            if let readStartedAt, let battery, battery.receivedAt > readStartedAt { return }
            battery = HelmetBatteryReading(percentage: percentage, category: category, receivedAt: date, fromRead: fromRead)
            batteryReadIssue = nil
            if let readStartedAt, let temperature, temperature.receivedAt > readStartedAt { return }
            temperature = HelmetTemperatureReading(celsius: celsius, receivedAt: date)
        case .activity(let value):
            if let readStartedAt, let activityReceivedAt, activityReceivedAt > readStartedAt { return }
            activity = value
            activityReceivedAt = date
        case .temperature(let celsius):
            if let readStartedAt, let temperature, temperature.receivedAt > readStartedAt { return }
            temperature = HelmetTemperatureReading(celsius: celsius, receivedAt: date)
        }
    }

    private func beginDashboardReads(peripheral: QKPeripheral, profile: DecathlonProfile, attempt: UUID) {
        isReadingDashboard = true
        dashboardReadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.attemptID == attempt {
                    self.isReadingDashboard = false
                    self.dashboardReadTask = nil
                }
            }
            // Read only once. The firmware subsequently supplies battery/activity updates.
            let readStartedAt = Date()
            do {
                try self.checkAttempt(attempt)
                let value = try await peripheral.readValue(for: profile.alerts, timeout: 5)
                try self.checkAttempt(attempt)
                self.receiveAlert(value, at: Date(), fromRead: true, readStartedAt: readStartedAt)
                if self.battery == nil { self.batteryReadIssue = "No valid battery status received. Double-tap the connected helmet to request a battery update." }
                QKLog.debug(tag: "Dashboard", "Read initial alert value", value.count)
            } catch {
                guard self.attemptID == attempt else { return }
                if self.battery == nil { self.batteryReadIssue = "Battery read failed. Waiting for a battery notification." }
                QKLog.error(tag: "Dashboard", "Initial battery read failed", error)
            }

            do {
                try self.checkAttempt(attempt)
                let configuration = try DecathlonProfile.readableConfiguration(in: self.services, alerts: profile.alerts)
                let value = try await peripheral.readValue(for: configuration, timeout: 5)
                try self.checkAttempt(attempt)
                guard let thresholds = HelmetCrashThresholds(data: value, receivedAt: Date()) else {
                    throw ProfileError("Expected a 10-byte configuration; received \(value.count) bytes.")
                }
                self.thresholds = thresholds
                QKLog.debug(tag: "Dashboard", "Read crash thresholds", thresholds.majorG, thresholds.minorG)
            } catch {
                guard self.attemptID == attempt else { return }
                self.thresholdReadIssue = error.localizedDescription
                QKLog.error(tag: "Dashboard", "Could not read crash thresholds", error)
            }

            for field in HelmetDeviceInfoField.allCases {
                do {
                    try self.checkAttempt(attempt)
                    let candidates = self.services.filter { $0.uuid == CBUUID(string: "180A") }
                        .flatMap(\.characteristics).filter { $0.uuid == CBUUID(string: field.uuidString) }
                    guard candidates.count == 1, let characteristic = candidates.first, characteristic.isReadable else {
                        self.deviceInformationIssues[field] = "No unique readable characteristic is available."
                        continue
                    }
                    let value = try await peripheral.readValue(for: characteristic, timeout: 5)
                    try self.checkAttempt(attempt)
                    guard value.count <= 512, let raw = String(data: value, encoding: .utf8) else {
                        throw ProfileError("Device information is not valid text.")
                    }
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
                    guard !text.isEmpty else { throw ProfileError("Device information is empty.") }
                    self.deviceInformation[field] = text
                    QKLog.debug(tag: "Dashboard", "Read device information", field.rawValue, text)
                } catch {
                    guard self.attemptID == attempt else { return }
                    self.deviceInformationIssues[field] = error.localizedDescription
                    QKLog.error(tag: "Dashboard", "Could not read device information", field.rawValue, error)
                }
            }
        }
    }

    private func stop(with phase: ConnectionPreparationPhase) {
        retrieval.interrupt(reason: "Connection ended before retrieval completed. \(phase.message)")
        attemptID = UUID()
        preparationTask?.cancel()
        dashboardReadTask?.cancel()
        dashboardReadTask = nil
        isReadingDashboard = false
        for task in notificationTasks { task.cancel() }
        notificationTasks.removeAll()
        enabledNotificationIDs.removeAll()
        profile = nil
        peripheral = nil
        self.phase = phase
        manager?.disconnectAll()
        QKLog.debug(tag: "Connection", "Stopped connection session", phase.title)
    }
}

enum ConnectionPreparationPhase: Equatable {
    case idle, connecting, discoveringServices, discoveringCharacteristics, validatingProfile, enablingNotifications, ready
    case failed(String), disconnected(String)

    var isPreparing: Bool {
        switch self {
        case .connecting, .discoveringServices, .discoveringCharacteristics, .validatingProfile, .enablingNotifications: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .idle: "Select a helmet"
        case .connecting: "Connecting"
        case .discoveringServices: "Discovering services"
        case .discoveringCharacteristics: "Discovering characteristics"
        case .validatingProfile: "Checking capabilities"
        case .enablingNotifications: "Enabling notifications"
        case .ready: "Connected"
        case .failed: "Preparation failed"
        case .disconnected: "Disconnected"
        }
    }

    var message: String {
        switch self {
        case .idle: "Choose your helmet from the nearby results."
        case .connecting: "Keep the helmet nearby. A connection attempt can take up to 15 seconds."
        case .discoveringServices, .discoveringCharacteristics: "Reading the helmet's services and full characteristic UUIDs."
        case .validatingProfile: "Checking the data and alert channels support the required operations."
        case .enablingNotifications: "Waiting for the helmet to confirm both notification channels."
        case .ready: "The data and alert notification channels are subscribed."
        case .failed(let message), .disconnected(let message): message
        }
    }
}
