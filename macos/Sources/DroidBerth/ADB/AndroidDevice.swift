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
        ///
        /// 文案逐字取自设计稿 `icon-system.html` §3.3。开头的 `**…：**` 是 **Markdown**，
        /// 由 `DeviceGuideCard` 用 `AttributedString(markdown:)` 渲染成粗体 —— 与稿子一致。
        var authorizationNote: String {
            switch self {
            case .xiaomi:
                "**小米设备：**先到「设置 › 我的设备 › 全部参数与信息」连点「MIUI 版本」7 次，"
                    + "再回「设置 › 更多设置 › 开发者选项」打开「USB 调试」。"
                    + "部分机型需要登录小米账号并插入 SIM 卡后，才能打开「USB 调试（安全设置）」。"
            case .oppo:
                "**OPPO 系设备：**到「设置 › 关于手机 › 版本信息」连点「版本号」7 次，"
                    + "再回「设置 › 系统设置 › 开发者选项」打开「USB 调试」。"
                    + "部分 ColorOS 版本要求先登录 OPPO 账号。"
            case .vivo:
                "**vivo 设备：**到「设置 › 更多设置 › 关于手机」连点「软件版本号」7 次，"
                    + "再回「设置 › 系统管理 › 开发者选项」打开「USB 调试」。开启前需登录 vivo 账号。"
            case .samsung:
                "**三星设备：**通常不需要额外步骤；若弹窗没有出现，"
                    + "在「开发者选项」里关掉再打开一次「USB 调试」。"
            case .huawei:
                "**华为 / 荣耀设备：**部分机型要先把 USB 用途在「仅充电」与「传输文件」之间"
                    + "切换一次，授权弹窗才会出现。"
            }
        }

        /// 未识别出品牌时的通用说明（设计稿 §3.3 表的「通用（默认）」行）。
        ///
        /// **必须给一个默认值**：稿子把它列为表格第一行，而不是「识别不出就不显示」——
        /// 认不出品牌恰恰是最需要这段说明的时候（用户不知道为什么没有弹窗）。
        static let genericAuthorizationNote =
            "**没看到弹窗？**请确认「开发者选项」里的「USB 调试」已经打开，"
            + "并把 USB 用途改为「传输文件 / MTP」。"

        /// 「弹窗不再出现」的通用补充（设计稿 §3.3 表最后一行，任意品牌）。
        static let dialogNeverAppearsNote =
            "**还是没有弹窗？**到「开发者选项」里点一次「撤销 USB 调试授权」，"
            + "然后拔掉数据线重新插上。"
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
