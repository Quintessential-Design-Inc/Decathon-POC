import Foundation
import Observation
import QuinKitBLE
import QuinKitLogger
import QuinKitPermissions

/// App-owned transport lifetime. Product discovery and commands arrive in later steps.
@MainActor
@Observable
final class BluetoothSession: QKBLEManagerDelegate {
    private(set) var permissionStatus: QKPermissionStatus
    private(set) var bluetoothState: QKBluetoothState = .unknown
    private(set) var isRequestingPermission = false

    @ObservationIgnored
    private(set) var manager: QKBLEManager?

    @ObservationIgnored
    private var hasStarted = false

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
        QKLog.debug(tag: "Bluetooth", "Starting foreground session", permissionStatus)
        await requestPermissionIfNeeded()
    }

    func didBecomeActive() async {
        guard hasStarted else {
            await start()
            return
        }

        QKLog.debug(tag: "Lifecycle", "App became active; refreshing Bluetooth access")
        refresh()
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
    }

    func openSettings() {
        QKLog.debug(tag: "Bluetooth", "Opening app Settings")
        QKPermissions.openSettings()
    }

    func bleManager(_ manager: QKBLEManager, didUpdateBluetoothState state: QKBluetoothState) {
        updatePermission(QKPermissions.check(.bluetooth))
        updateBluetoothState(state)
    }

    private func updatePermission(_ status: QKPermissionStatus) {
        guard permissionStatus != status else { return }
        permissionStatus = status
        QKLog.debug(tag: "Bluetooth", "Permission changed", status)
    }

    private func updateBluetoothState(_ state: QKBluetoothState) {
        guard bluetoothState != state else { return }
        bluetoothState = state
        QKLog.debug(tag: "Bluetooth", "Power/availability changed", state)
    }
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
