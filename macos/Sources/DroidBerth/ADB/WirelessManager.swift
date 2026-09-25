import Foundation

@MainActor
@Observable
final class WirelessManager {
    struct Outcome: Sendable {
        let serial: String
        let address: String
        let message: String
    }

    enum EnableResult: Sendable {
        case success(Outcome)
        case failure(String)
    }

    private(set) var busy = false
    private(set) var lastError: String?
    private(set) var lastOutcome: Outcome?

    var rememberedCount: Int { AppSettings.shared.rememberedWirelessDevices.count }

    func enable(device: AndroidDevice) async -> EnableResult {
        guard let monitor = currentMonitor else { return .failure("内部状态未就绪") }
        guard let shell = monitor.shell(for: device) else { return .failure("未找到可用的 adb") }

        busy = true
        lastError = nil
        defer { busy = false }

        guard !device.isWireless else {
            return .failure("该设备已经是无线连接")
        }

        guard let address = await Task.detached(priority: .userInitiated, operation: {
            shell.wifiAddress()
        }).value else {
            let message = "读不到设备的 Wi-Fi 地址。请确认手机已连上 Wi-Fi 后重试"
            lastError = message
            return .failure(message)
        }

        let tcpipResult = await Task.detached(priority: .userInitiated) {
            shell.raw(["tcpip", "5555"], timeout: 30)
        }.value
        guard tcpipResult.ok else {
            let message = "启用无线调试失败：\(tcpipResult.failureMessage)"
            lastError = message
            return .failure(message)
        }

        try? await Task.sleep(for: .seconds(2))

        let target = "\(address):5555"
        let connectResult = await Task.detached(priority: .userInitiated) {
            ProcessRunner.run(shell.adb, ["connect", target], timeout: 30)
        }.value

        let output = connectResult.stdout + connectResult.stderr
        guard output.contains("connected") else {
            let message = "连接 \(target) 失败：\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
            lastError = message
            return .failure(message)
        }

        AppSettings.shared.rememberAddress(target, for: device.serial)
        await monitor.refresh()

        let outcome = Outcome(
            serial: device.serial,
            address: target,
            message: "无线连接已启用：\(target)。现在可以拔掉数据线"
        )
        lastOutcome = outcome
        return .success(outcome)
    }

    func reconnectRemembered(monitor: DeviceMonitor) async {
        let remembered = AppSettings.shared.rememberedWirelessDevices
        guard !remembered.isEmpty else { return }

        let active = Set(monitor.devices.map(\.serial))
        let missing = remembered.filter { !active.contains($0.address) }
        guard !missing.isEmpty else { return }

        guard let adb = ADBPathHolder.path else { return }

        for entry in missing {
            _ = await Task.detached(priority: .utility) {
                ProcessRunner.run(adb, ["connect", entry.address], timeout: 15)
            }.value
        }

        await monitor.refresh()
    }

    func disconnect(address: String) async {
        guard let adb = ADBPathHolder.path else { return }
        _ = await Task.detached(priority: .utility) {
            ProcessRunner.run(adb, ["disconnect", address], timeout: 15)
        }.value
    }

    private var currentMonitor: DeviceMonitor?

    func attach(monitor: DeviceMonitor) {
        currentMonitor = monitor
    }
}

enum ADBPathHolder {
    static var path: URL? { ADBBinary.shared.path }
}
