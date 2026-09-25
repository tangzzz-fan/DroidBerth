import Foundation

enum ConflictPolicy: String, CaseIterable, Sendable {
    case keepBoth
    case overwrite

    var label: String {
        switch self {
        case .keepBoth: "保留两者"
        case .overwrite: "覆盖"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    var concurrency: Int {
        didSet { defaults.set(concurrency, forKey: Key.concurrency) }
    }

    var conflictPolicy: ConflictPolicy {
        didSet { defaults.set(conflictPolicy.rawValue, forKey: Key.conflictPolicy) }
    }

    var routingEnabled: Bool {
        didSet { defaults.set(routingEnabled, forKey: Key.routingEnabled) }
    }

    var rememberLastDestination: Bool {
        didSet { defaults.set(rememberLastDestination, forKey: Key.rememberLastDestination) }
    }

    var scanAfterTransfer: Bool {
        didSet { defaults.set(scanAfterTransfer, forKey: Key.scanAfterTransfer) }
    }

    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    private var lastDestination: [String: String] {
        didSet { defaults.set(lastDestination, forKey: Key.lastDestination) }
    }

    private var wirelessAddress: [String: String] {
        didSet { defaults.set(wirelessAddress, forKey: Key.wirelessAddress) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedConcurrency = defaults.integer(forKey: Key.concurrency)
        concurrency = storedConcurrency > 0 ? storedConcurrency : 4
        conflictPolicy = ConflictPolicy(rawValue: defaults.string(forKey: Key.conflictPolicy) ?? "") ?? .keepBoth
        routingEnabled = defaults.object(forKey: Key.routingEnabled) as? Bool ?? true
        rememberLastDestination = defaults.object(forKey: Key.rememberLastDestination) as? Bool ?? true
        scanAfterTransfer = defaults.object(forKey: Key.scanAfterTransfer) as? Bool ?? true
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        lastDestination = defaults.dictionary(forKey: Key.lastDestination) as? [String: String] ?? [:]
        wirelessAddress = defaults.dictionary(forKey: Key.wirelessAddress) as? [String: String] ?? [:]
    }

    func destination(for serial: String) -> String? {
        lastDestination[serial]
    }

    func rememberDestination(_ path: String, for serial: String) {
        guard rememberLastDestination else { return }
        lastDestination[serial] = path
    }

    func address(for serial: String) -> String? {
        wirelessAddress[serial]
    }

    func rememberAddress(_ address: String, for serial: String) {
        wirelessAddress[serial] = address
    }

    func forgetAddress(for serial: String) {
        wirelessAddress.removeValue(forKey: serial)
    }

    var rememberedWirelessDevices: [(serial: String, address: String)] {
        wirelessAddress.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    private enum Key {
        static let concurrency = "transfer.concurrency"
        static let conflictPolicy = "transfer.conflictPolicy"
        static let routingEnabled = "transfer.routingEnabled"
        static let rememberLastDestination = "transfer.rememberLastDestination"
        static let scanAfterTransfer = "media.scanAfterTransfer"
        static let appearance = "ui.appearance"
        static let lastDestination = "device.lastDestination"
        static let wirelessAddress = "device.wirelessAddress"
    }
}
