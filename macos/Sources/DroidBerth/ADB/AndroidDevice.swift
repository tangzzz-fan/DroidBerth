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

    /// 厂商家族 —— PRD §17.1 要求「引导卡片按检测到的品牌显示对应图文」。
    ///
    /// **判据只能用 `adb devices -l` 已经带回来的字段**（`model` / `product` / `device`）。
    /// 需要这张卡片的时候，设备往往正是「未授权」，而**未授权状态下 `adb shell` 跑不了** ——
    /// 于是 `getprop ro.product.brand` 这条最权威的路，恰恰在关键时刻不可用。
    /// 用已经在手上的三个属性做字符串匹配，是这里唯一可行的判据。
    var brandFamily: BrandFamily? {
        let haystack = [model, product, device]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        guard !haystack.isEmpty else { return nil }
        return BrandFamily.allCases.first { family in
            family.markers.contains { haystack.contains($0) }
        }
    }

    /// 厂商家族与它们在 USB 授权环节多出来的那一步。
    ///
    /// ⚠️ 这些额外步骤来自各家公开的开发者文档与用户手册，**未在真机上逐机型核对**
    /// （本机只有一台华为 Android 10 可用，见 README「验证状态」）。文案一律写成
    /// 「还可能需要…」而不是断言，避免把未验证的事实说死。
    enum BrandFamily: String, CaseIterable, Sendable {
        case xiaomi
        case oppo
        case vivo
        case samsung
        case huawei

        /// 匹配用的子串。判据是**从宽**：宁可多给一条厂商提示，也不要漏掉。
        var markers: [String] {
            switch self {
            case .xiaomi: ["xiaomi", "redmi", "poco", "mi "]
            case .oppo: ["oppo", "realme", "oneplus", "one plus"]
            case .vivo: ["vivo", "iqoo"]
            case .samsung: ["samsung", "sm-", "galaxy"]
            case .huawei: ["huawei", "honor", "hwd", "ele-", "jny-", "dvc-"]
            }
        }

        var label: String {
            switch self {
            case .xiaomi: "小米 / Redmi / POCO"
            case .oppo: "OPPO / realme / 一加"
            case .vivo: "vivo / iQOO"
            case .samsung: "三星"
            case .huawei: "华为 / 荣耀"
            }
        }

        /// 授权卡片底部那一段按品牌变的文案（PRD §17.1「厂商差异」）。
        var authorizationNote: String? {
            switch self {
            case .xiaomi:
                "检测到 \(label)。这类机型在「开发者选项」里通常还有一个「USB 调试（安全设置）」，需要单独打开并等待倒计时结束。"
            case .oppo:
                "检测到 \(label)。这类机型的「USB 调试」可能带一个需要登录账号才能开启的开关；另外确认「默认 USB 配置」是「传输文件」。"
            case .vivo:
                "检测到 \(label)。这类机型可能要求登录账号后才能打开「USB 调试（安全设置）」，打开后请再插拔一次数据线。"
            case .samsung:
                "检测到 \(label)。通常不需要额外步骤；若弹窗没有出现，在「开发者选项」里关掉再打开一次「USB 调试」。"
            case .huawei:
                "检测到 \(label)。部分机型要先把 USB 用途在「仅充电」与「传输文件」之间切换一次，授权弹窗才会出现。"
            }
        }
    }

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
