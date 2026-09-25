import Foundation

@MainActor
@Observable
final class DeviceMonitor {
    enum Status: Sendable {
        case idle
        case sidecarMissing
        case adbMissing
        case failed(String)
    }

    private(set) var devices: [AndroidDevice] = []
    private(set) var status: Status = .idle
    private(set) var adbPath: String?
    private(set) var lastRefreshed: Date?

    var selectedSerial: String?

    private var polling: Task<Void, Never>?

    var usableDevices: [AndroidDevice] {
        devices.filter { $0.state.isUsable }
    }

    var selectedDevice: AndroidDevice? {
        guard let selectedSerial else { return nil }
        return devices.first { $0.serial == selectedSerial }
    }

    var activeDevice: AndroidDevice? {
        selectedDevice ?? usableDevices.first
    }

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let idle = self?.devices.isEmpty ?? true
                try? await Task.sleep(for: .seconds(idle ? 3 : 1))
            }
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
    }

    func refresh() async {
        guard let adb = await Task.detached(priority: .utility, operation: { ADBBinary.shared.path }).value else {
            status = ADBBinary.shared.isSidecarMissing ? .sidecarMissing : .adbMissing
            adbPath = nil
            devices = []
            return
        }

        adbPath = adb.path

        let result = await Task.detached(priority: .utility) {
            ProcessRunner.run(adb, ["devices", "-l"], timeout: 15)
        }.value

        if let spawnError = result.spawnError {
            status = .failed(spawnError)
            devices = []
            return
        }

        let parsed = AndroidDevice.parse(result.stdout)
        devices = parsed
        status = .idle
        lastRefreshed = Date()

        if let selectedSerial, !parsed.contains(where: { $0.serial == selectedSerial && $0.state.isUsable }) {
            self.selectedSerial = nil
        }
        if selectedSerial == nil {
            selectedSerial = parsed.first(where: { $0.state.isUsable })?.serial
        }
    }

    func shell(for device: AndroidDevice) -> DeviceShell? {
        guard let path = adbPath ?? ADBBinary.shared.path?.path else { return nil }
        return DeviceShell(adb: URL(fileURLWithPath: path), serial: device.serial)
    }
}
