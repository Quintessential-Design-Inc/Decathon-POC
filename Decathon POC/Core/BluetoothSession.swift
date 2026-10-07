import Foundation
import Observation
import QuinKitBLE
import QuinKitLogger
import QuinKitPermissions

/// App-owned transport and discovery lifetime. Connection and commands arrive later.
@MainActor
@Observable
final class BluetoothSession: QKBLEManagerDelegate {
    private(set) var permissionStatus: QKPermissionStatus
    private(set) var bluetoothState: QKBluetoothState = .unknown
    private(set) var isRequestingPermission = false
    private(set) var scanPhase: HelmetScanPhase = .idle
    private(set) var discoveredHelmets: [DiscoveredHelmet] = []
    private(set) var isStartingScan = false

    @ObservationIgnored
    private(set) var manager: QKBLEManager?

    @ObservationIgnored
    private var hasStarted = false

    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var isScannerVisible = false
    @ObservationIgnored private var needsAutomaticScan = false
    @ObservationIgnored private var scanRequestActive = false
    @ObservationIgnored private var scanID = UUID()
    @ObservationIgnored private var automaticScanTask: Task<Void, Never>?
    @ObservationIgnored private var staleResultsTask: Task<Void, Never>?

    deinit {
        automaticScanTask?.cancel()
        staleResultsTask?.cancel()
    }

    init() {
        permissionStatus = QKPermissions.check(.bluetooth)
    }

    var readiness: BluetoothReadiness {
        if isRequestingPermission {
            return .requestingPermission
        }

        switch permissionStatus {
        case .notDetermined:
            return .needsPermission
        case .denied:
            return .permissionDenied
        case .granted:
            switch bluetoothState {
            case .unknown:
                return .starting
            case .resetting:
                return .resetting
            case .unsupported:
                return .unsupported
            case .unauthorized:
                return .permissionDenied
            case .poweredOff:
                return .poweredOff
            case .poweredOn:
                return .ready
            }
        }
    }

    var isBluetoothReady: Bool {
        permissionStatus == .granted && bluetoothState == .poweredOn
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        isForeground = true
        QKLog.debug(tag: "Bluetooth", "Starting foreground session", permissionStatus)
        await requestPermissionIfNeeded()
    }

    func didBecomeActive() async {
        isForeground = true
        guard hasStarted else {
            await start()
            return
        }

        QKLog.debug(tag: "Lifecycle", "App became active; refreshing Bluetooth access")
        refresh()
    }

    func didEnterBackground() {
        isForeground = false
        if scanPhase == .scanning || isStartingScan {
            needsAutomaticScan = true
            interruptScan()
            QKLog.debug(tag: "Scan", "Paused scan while app is in the background")
        } else if !discoveredHelmets.isEmpty {
            scanPhase = .idle
        }
        discoveredHelmets.removeAll()
    }

    func requestPermissionIfNeeded() async {
        refresh()
        guard permissionStatus == .notDetermined, !isRequestingPermission else { return }

        isRequestingPermission = true
        QKLog.debug(tag: "Bluetooth", "Requesting Bluetooth permission")
        let status = await QKPermissions.request(.bluetooth)
        updatePermission(status)
        isRequestingPermission = false
        refresh()
    }

    func refresh() {
        updatePermission(QKPermissions.check(.bluetooth))

        if permissionStatus == .granted, manager == nil {
            let transport = QKBLEManager(configuration: QKBLEConfiguration(
                showPowerAlert: false,
                maxSimultaneousConnections: 1,
                reconnectPolicy: .disabled
            ))
            transport.delegate = self
            manager = transport
            QKLog.debug(tag: "Bluetooth", "Created foreground QuinKitBLE transport")
        }

        if let manager {
            updateBluetoothState(manager.bluetoothState)
        }
        scheduleAutomaticScanIfNeeded()
    }

    func enterScanner() async {
        guard !isScannerVisible else { return }
        isScannerVisible = true
        needsAutomaticScan = true
        QKLog.debug(tag: "Scan", "Entered discovery screen")
        await startScan()
    }

    func leaveScanner() {
        isScannerVisible = false
        needsAutomaticScan = false
        scanRequestActive = false
        scanPhase = .idle
        cancelStaleResultCleanup()
        manager?.stopScan()
        discoveredHelmets.removeAll()
        QKLog.debug(tag: "Scan", "Left discovery screen; scan stopped")
    }

    func startScan() async {
        refresh()
        guard isScannerVisible, isForeground, isBluetoothReady, let manager,
              !isStartingScan, scanPhase != .scanning else { return }

        needsAutomaticScan = false
        scanRequestActive = true
        isStartingScan = true
        scanID = UUID()
        scanPhase = .scanning
        discoveredHelmets.removeAll()
        defer {
            isStartingScan = false
            scheduleAutomaticScanIfNeeded()
        }

        do {
            try await manager.startScan(QKScanRequest(
                serviceUUIDs: nil,
                timeout: 30,
                allowDuplicates: true,
                nameKeywords: [],
                minimumRSSI: Int.min
            ))

            // A power/lifecycle change can occur during the async permission preflight.
            guard scanRequestActive, isScannerVisible, isForeground, isBluetoothReady else {
                manager.stopScan()
                return
            }

            startStaleResultCleanup()
            QKLog.debug(tag: "Scan", "Started 30-second Decathlon scan")
        } catch {
            guard scanRequestActive else { return }
            scanRequestActive = false
            scanPhase = .failed(error.localizedDescription)
            QKLog.error(tag: "Scan", "Could not start scan", error)
        }
    }

    func stopScan() {
        needsAutomaticScan = false
        scanRequestActive = false
        scanPhase = .stopped
        cancelStaleResultCleanup()
        manager?.stopScan()
        QKLog.debug(tag: "Scan", "User stopped scan", discoveredHelmets.count)
    }

    func openSettings() {
        QKLog.debug(tag: "Bluetooth", "Opening app Settings")
        QKPermissions.openSettings()
    }

    func bleManager(_ manager: QKBLEManager, didUpdateBluetoothState state: QKBluetoothState) {
        updatePermission(QKPermissions.check(.bluetooth))
        updateBluetoothState(state)
    }

    func bleManager(_ manager: QKBLEManager, didDiscover result: QKScanResult) {
        guard scanRequestActive, scanPhase == .scanning, isScannerVisible, isForeground, isBluetoothReady,
              let helmet = DiscoveredHelmet(scanResult: result) else { return }

        if let index = discoveredHelmets.firstIndex(where: { $0.id == helmet.id }) {
            discoveredHelmets[index] = helmet
        } else {
            discoveredHelmets.append(helmet)
            QKLog.debug(tag: "Scan", "Discovered Decathlon helmet", helmet.name, helmet.advertisement.macAddress)
            if helmet.advertisement.batteryPercentage == nil {
                QKLog.error(tag: "Scan", "Advertisement has an invalid battery percentage", helmet.id)
            }
        }
    }

    func bleManagerDidStopScan(_ manager: QKBLEManager) {
        let completedScanID = scanID
        // QuinKit may report scan-stop immediately before its power-state callback.
        Task { @MainActor [weak self] in
            guard let self, self.scanID == completedScanID, self.scanPhase == .scanning else { return }
            if !self.isBluetoothReady || !self.isForeground || !self.isScannerVisible {
                self.needsAutomaticScan = self.isScannerVisible
                self.interruptScan()
            } else {
                self.scanRequestActive = false
                self.scanPhase = .finished
                self.cancelStaleResultCleanup()
                QKLog.debug(tag: "Scan", "Scan window finished", self.discoveredHelmets.count)
            }
        }
    }

    private func scheduleAutomaticScanIfNeeded() {
        guard isScannerVisible, isForeground, needsAutomaticScan, isBluetoothReady,
              !isStartingScan, scanPhase != .scanning, automaticScanTask == nil else { return }
        automaticScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.startScan()
            self.automaticScanTask = nil
            self.scheduleAutomaticScanIfNeeded()
        }
    }

    private func interruptScan() {
        scanRequestActive = false
        scanPhase = .interrupted
        cancelStaleResultCleanup()
        manager?.stopScan()
        discoveredHelmets.removeAll()
    }

    private func startStaleResultCleanup() {
        cancelStaleResultCleanup()
        staleResultsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch { return }
                guard let self, self.scanPhase == .scanning else { return }
                let cutoff = Date().addingTimeInterval(-10)
                self.discoveredHelmets.removeAll { $0.lastSeen < cutoff }
            }
        }
    }

    private func cancelStaleResultCleanup() {
        staleResultsTask?.cancel()
        staleResultsTask = nil
    }

    private func updatePermission(_ status: QKPermissionStatus) {
        guard permissionStatus != status else { return }
        permissionStatus = status
        QKLog.debug(tag: "Bluetooth", "Permission changed", status)
        if status != .granted {
            handleBluetoothUnavailable()
        }
    }

    private func updateBluetoothState(_ state: QKBluetoothState) {
        guard bluetoothState != state else { return }
        bluetoothState = state
        QKLog.debug(tag: "Bluetooth", "Power/availability changed", state)
        if !state.isReady {
            handleBluetoothUnavailable()
        }
        scheduleAutomaticScanIfNeeded()
    }

    private func handleBluetoothUnavailable() {
        if scanPhase == .scanning || isStartingScan {
            needsAutomaticScan = true
            interruptScan()
            QKLog.debug(tag: "Scan", "Scan interrupted because Bluetooth is unavailable")
        } else if !discoveredHelmets.isEmpty {
            scanPhase = .idle
        }
        discoveredHelmets.removeAll()
    }
}

enum HelmetScanPhase: Equatable {
    case idle
    case scanning
    case finished
    case stopped
    case interrupted
    case failed(String)
}

enum BluetoothReadiness {
    case needsPermission
    case requestingPermission
    case permissionDenied
    case starting
    case resetting
    case unsupported
    case poweredOff
    case ready

    var title: String {
        switch self {
        case .needsPermission: "Permission needed"
        case .requestingPermission: "Waiting for permission"
        case .permissionDenied: "Access not allowed"
        case .starting: "Checking Bluetooth"
        case .resetting: "Bluetooth is restarting"
        case .unsupported: "Bluetooth unavailable"
        case .poweredOff: "Bluetooth is off"
        case .ready: "Ready"
        }
    }

    var message: String {
        switch self {
        case .needsPermission:
            "Allow Bluetooth access to connect to your helmet and retrieve its offline events."
        case .requestingPermission:
            "Respond to the iPhone's Bluetooth permission request to continue."
        case .permissionDenied:
            "Allow Bluetooth access for this app in Settings. If access is restricted, check your device restrictions."
        case .starting:
            "Checking whether Bluetooth is available on your iPhone."
        case .resetting:
            "Please wait while Bluetooth restarts. Your status will update automatically."
        case .unsupported:
            "Bluetooth Low Energy is unavailable on this device. Run the app on a supported iPhone to use your helmet."
        case .poweredOff:
            "Turn on Bluetooth in Settings or Control Center. Your status will update automatically."
        case .ready:
            "Bluetooth access is allowed and Bluetooth is on. Your iPhone is ready for device discovery."
        }
    }

    var systemImage: String {
        switch self {
        case .ready: "checkmark"
        case .permissionDenied: "lock.fill"
        case .poweredOff: "power"
        case .unsupported: "exclamationmark.triangle"
        case .starting, .resetting, .requestingPermission: "arrow.trianglehead.2.clockwise"
        case .needsPermission: "antenna.radiowaves.left.and.right"
        }
    }

    var isWaiting: Bool {
        switch self {
        case .requestingPermission, .starting, .resetting: true
        default: false
        }
    }
}
