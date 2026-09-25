import Foundation

struct AndroidDevice: Identifiable, Hashable, Sendable {
    enum State: String, Sendable {
        case ready = "device"
        case unauthorized
        case offline
        case bootloader
        case recovery
        case sideload
        case unknown

        var isUsable: Bool { self == .ready }

        var localizedDescription: String {
            switch self {
            case .ready: "已连接"
            case .unauthorized: "未授权"
            case .offline: "离线"
            case .bootloader: "Bootloader"
            case .recovery: "Recovery"
            case .sideload: "Sideload"
            case .unknown: "未知状态"
            }
        }
    }

    let serial: String
    let state: State
    let rawState: String
    let model: String?
    let product: String?
    let device: String?
    let transportID: String?
    let usbDescriptor: String?

    var id: String { serial }

    var isWireless: Bool { serial.contains(":") }

    var displayName: String {
        let name = model?.replacingOccurrences(of: "_", with: " ")
        if let name, !name.isEmpty { return name }
        if let product, !product.isEmpty { return product }
        return serial
    }

    var connectionLabel: String { isWireless ? "无线" : "USB" }

    static func parse(_ output: String) -> [AndroidDevice] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("List of devices") && !$0.hasPrefix("*") }
            .compactMap { line -> AndroidDevice? in
                let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard fields.count >= 2 else { return nil }
                let serial = fields[0]
                let rawState = fields[1]

                var attributes: [String: String] = [:]
                for field in fields.dropFirst(2) {
                    guard let separator = field.firstIndex(of: ":") else { continue }
                    attributes[String(field[field.startIndex..<separator])] = String(field[field.index(after: separator)...])
                }

                return AndroidDevice(
                    serial: serial,
                    state: State(rawValue: rawState) ?? .unknown,
                    rawState: rawState,
                    model: attributes["model"],
                    product: attributes["product"],
                    device: attributes["device"],
                    transportID: attributes["transport_id"],
                    usbDescriptor: attributes["usb"]
                )
            }
    }
}
