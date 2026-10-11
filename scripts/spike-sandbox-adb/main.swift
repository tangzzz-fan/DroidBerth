import Darwin
import Foundation
import IOKit

// S1 探针 —— 在（可选）沙盒里跑包内内嵌的 adb。
//
// 它必须回答三个**互相独立**的问题，因为它们的结论完全不同：
//
//   S1-a  沙盒里能不能**执行**包内的 adb
//   S1-b  adb 的 server 能不能在沙盒里**起在自定义端口**（要 network.server）
//   S1-c  沙盒里 adb 能不能**通过 USB 看见真机**
//
// 设计上有两条硬要求，缺一条结论就不可信：
//
// ① **必须自己回答「我到底有没有被沙盒化」。**
//    若探针其实没进沙盒，「USB 能用」就是**假阳性** —— 那比测不出来更糟，
//    因为它会让人放心地往下做。
//    判据：passwd 数据库里的真实家目录 vs `NSHomeDirectory()`（沙盒会把它改写到容器）。
//
// ② **必须把「能跑 adb」与「能看见真机」分开报。**
//    `emulator-5554` 走 **TCP**，完全不经过 USB 通路 —— 只见得到模拟器时，
//    S1-c 必须报「**未验证**」而不是 PASS。这条与项目里那句
//    「模拟器 ≠ 真机，设备端权限相关的结论不能只靠模拟器」是同一条判据。

// ─────────────────────────────────────────────────────────────
// 最小进程封装：**用文件接输出，不用管道**
//
// 不用 `Pipe` + `readDataToEndOfFile`：`adb` 会 fork 出一个**常驻的 server**，
// 那个子进程会继承 stdout/stderr 的 fd。管道因此不会 EOF，读的那一侧会**永久阻塞**。
// 重定向到文件则永远不阻塞。
// ─────────────────────────────────────────────────────────────

struct RunResult {
    let code: Int32
    let out: String
    let err: String
    let timedOut: Bool

    var ok: Bool { !timedOut && code == 0 }
}

/// 探针自己的临时目录（沙盒下就是容器里的那一个）。
let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("droidberth-sandbox-probe")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

@MainActor
func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 25) -> RunResult {
    let outURL = scratch.appendingPathComponent("out-\(UUID().uuidString).txt")
    let errURL = scratch.appendingPathComponent("err-\(UUID().uuidString).txt")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)

    guard let outHandle = try? FileHandle(forWritingTo: outURL),
          let errHandle = try? FileHandle(forWritingTo: errURL) else {
        return RunResult(code: -1, out: "", err: "无法在容器内创建临时文件", timedOut: false)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = outHandle
    process.standardError = errHandle

    do {
        try process.run()
    } catch {
        try? outHandle.close(); try? errHandle.close()
        return RunResult(code: -1, out: "", err: "spawn 失败：\(error)", timedOut: false)
    }

    // 超时也要能收工 —— adb 卡住时不能把整个探针一起拖死。
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        usleep(50_000)
    }
    let timedOut = process.isRunning
    if timedOut { process.terminate() }

    try? outHandle.close()
    try? errHandle.close()
    let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
    let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(at: outURL)
    try? FileManager.default.removeItem(at: errURL)

    return RunResult(code: timedOut ? -1 : process.terminationStatus, out: out, err: err, timedOut: timedOut)
}

/// 打印并**立即刷出**。
///
/// 少了 `fflush` 这一步，沙盒版一旦在启动阶段被杀（实测会 `Trace/BPT trap`），
/// 已经走过的每一步都还躺在 stdio 的缓冲里 —— 而进程是被信号打死的，没有 atexit，
/// 缓冲区直接丢掉。现象就是「**什么输出都没有**」，让人完全看不出死在哪一步。
@MainActor
func say(_ text: String = "") {
    print(text)
    fflush(stdout)
}

// ─────────────────────────────────────────────────────────────
// 0. 我是谁、我在不在沙盒里
// ─────────────────────────────────────────────────────────────

/// 从 passwd 数据库取**真实**家目录。沙盒不会改这里 —— 它改的是 `HOME` / `NSHomeDirectory()`。
func realHomeDirectory() -> String {
    guard let entry = getpwuid(getuid()) else { return "?" }
    return String(cString: entry.pointee.pw_dir)
}

let home = NSHomeDirectory()
let real = realHomeDirectory()
let sandboxed = home != real

say("── 环境")
say("  可执行文件      : \(CommandLine.arguments[0])")
say("  NSHomeDirectory : \(home)")
say("  passwd 家目录   : \(real)")
say("  沙盒生效        : \(sandboxed ? "是" : "否")")

// 反向对照：读**真实**家目录。沙盒里这一条必须失败 —— 否则「沙盒生效」判据本身失效。
let homeReadable: Bool
do {
    _ = try FileManager.default.contentsOfDirectory(atPath: real)
    homeReadable = true
} catch {
    homeReadable = false
}
say("  能否列出真实家目录 : \(homeReadable ? "能" : "不能（沙盒里应如此）")")

// 容器可写性：沙盒下 HOME 指向容器，写应成功。
let containerWritable: Bool
do {
    let probe = URL(fileURLWithPath: home).appendingPathComponent("writable-probe.txt")
    try "ok".write(to: probe, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: probe)
    containerWritable = true
} catch {
    containerWritable = false
}
say("  容器可写        : \(containerWritable ? "是" : "否")")

// ─────────────────────────────────────────────────────────────
// 1. USB 通路 —— S1-c 的**辅助判据**（不需要手机就能跑）
// ─────────────────────────────────────────────────────────────
//
// 为什么要有这一节：S1-c 的真判据是「沙盒里 adb 能不能看见**真机**」，而那必须有手机。
// 但**权限通路**可以提前单独验掉：`adb` 在 macOS 上走 libusb，libusb 走 IOKit。
// 沙盒里若连 `IOUSBHostDevice` 都枚举不到，S1-c 几乎必然失败 —— 不用等手机就知道。
//
// 对照组就是 ControlProbe（**不沙盒**）：它的数才是「这台机器上本来有几个 USB 设备」。
// 两个数必须放在一起看 —— 单看沙盒那个数，0 既可能是权限不够，也可能是这台机器真没插东西。
//
// ⚠️ 这条只是**辅助**：枚举得到 ≠ adb 一定打得开设备（打开还要额外一步授权）。
//    所以它过了也**不把 S1-c 判成 PASS**。
func usbDeviceSummary() -> (ok: Bool, count: Int, names: [String]) {
    func hex4(_ value: Int) -> String {
        let digits = "0123456789abcdef"
        let clamped = max(0, min(value, 0xFFFF))
        var out = ""
        for shift in stride(from: 12, through: 0, by: -4) {
            let nibble = (clamped >> shift) & 0xF
            out.append(Array(digits)[nibble])
        }
        return out
    }

    // `IOServiceGetMatchingServices` 会**吃掉** matching 字典的引用，不用自己放。
    guard let matching = IOServiceMatching("IOUSBHostDevice") else { return (false, -1, []) }
    var iterator: io_iterator_t = 0
    let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
    guard kr == KERN_SUCCESS else { return (false, Int(kr), []) }
    defer { IOObjectRelease(iterator) }

    var names: [String] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
        var props: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = props?.takeRetainedValue() as? [String: Any] {
            let vid = dict["idVendor"] as? Int ?? -1
            let pid = dict["idProduct"] as? Int ?? -1
            let product = dict["USB Product Name"] as? String
            let vendor = dict["USB Vendor Name"] as? String
            let label = product ?? vendor ?? "(无名)"
            names.append("\(label) [\(hex4(vid)):\(hex4(pid))]")
        }
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
    return (true, names.count, names)
}

let usb = usbDeviceSummary()

say()
say("── USB 通路（辅助判据：adbd → libusb → IOKit）")
if !usb.ok {
    say("  IOKit 枚举          : **被拒**（kern_return = \(usb.count)）—— device.usb 没生效？")
} else {
    say("  IOKit 枚举          : 成功，可见 \(usb.count) 个 IOUSBHostDevice")
    for name in usb.names.prefix(8) { say("        \(name)") }
    if usb.names.count > 8 { say("        …另有 \(usb.names.count - 8) 个") }
}
// 给 shell 一个稳定的机器可读行：脚本要拿它与对照组比。
say("USB-COUNT: \(usb.ok ? usb.count : -1)")

// ─────────────────────────────────────────────────────────────
// 2. 找包内的 adb
// ─────────────────────────────────────────────────────────────

let bundleResources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/adb")
let besideExecutable = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Contents/Resources/adb")

let adbURL = FileManager.default.isExecutableFile(atPath: bundleResources.path)
    ? bundleResources
    : besideExecutable
let adbPath = adbURL.path
let adbPresent = FileManager.default.isExecutableFile(atPath: adbPath)

say()
say("── adb")
say("  期望位置        : \(adbPath)")
say("  存在且可执行    : \(adbPresent ? "是" : "否")")

guard adbPresent else {
    say()
    say("S1-a 执行包内 adb        : **FAIL**（找不到 adb，探针打包有问题，不是沙盒结论）")
    exit(2)
}

// ─────────────────────────────────────────────────────────────
// 3. 执行 adb（自定义端口，别去动用户自己的 5037 server）
// ─────────────────────────────────────────────────────────────

let port = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "15037"

say()
say("── 执行（-P \(port)，刻意避开用户自己的 5037）")

let version = run(adbPath, ["-P", port, "version"])
say("  [1] adb version      退出码 \(version.code)\(version.timedOut ? "（超时）" : "")")
for line in version.out.split(separator: "\n").prefix(3) { say("        \(line)") }
if !version.err.isEmpty {
    for line in version.err.split(separator: "\n").prefix(3) { say("        stderr: \(line)") }
}

let devices = run(adbPath, ["-P", port, "devices", "-l"])
say("  [2] adb devices -l   退出码 \(devices.code)\(devices.timedOut ? "（超时）" : "")")
for line in devices.out.split(separator: "\n").prefix(6) { say("        \(line)") }
if !devices.err.isEmpty {
    for line in devices.err.split(separator: "\n").prefix(4) { say("        stderr: \(line)") }
}

// 收工：别把自己起的 server 留在后台（MAS 审核条款 2.4.5(iii) 也要求不残留进程）。
let kill = run(adbPath, ["-P", port, "kill-server"])
say("  [3] adb kill-server  退出码 \(kill.code)")

// ─────────────────────────────────────────────────────────────
// 4. 结论
// ─────────────────────────────────────────────────────────────

let serials: [String] = devices.out
    .split(separator: "\n")
    .dropFirst()
    .compactMap { line in
        let parts = line.split(separator: " ").filter { !$0.isEmpty }
        return parts.count >= 2 ? String(parts[0]) : nil
    }
let emulators = serials.filter { $0.hasPrefix("emulator-") }
let physical = serials.filter { !$0.hasPrefix("emulator-") }

say()
say("── 设备分类")
say("  模拟器（走 TCP，不经过 USB）: \(emulators.isEmpty ? "无" : emulators.joined(separator: ", "))")
say("  真机（可能走 USB）          : \(physical.isEmpty ? "无" : physical.joined(separator: ", "))")

// S1-a：沙盒里能不能执行包内的 adb
let s1a = version.ok && !devices.timedOut
// S1-b：adb server 能不能在沙盒里起来（能列出设备就说明 server 通了）
let s1b = devices.out.contains("List of devices attached")
// S1-c：只有**真机**出现才能回答 USB 那条
let s1c: String
if !s1a {
    s1c = "无法判定（S1-a 已经失败）"
} else if !physical.isEmpty {
    s1c = "PASS（列出真机：\(physical.joined(separator: ", "))）"
} else if !emulators.isEmpty {
    s1c = "**未验证** —— 只看到模拟器，它走 TCP，USB 通路根本没被走过"
} else {
    s1c = "**未验证** —— 没有任何设备连着；请插上真机并确认 USB 调试已授权后重跑"
}

let usbVerdict: String
if !usb.ok {
    usbVerdict = "**枚举被拒** —— device.usb 没生效，S1 到此为止"
} else if usb.count == 0 {
    usbVerdict = "枚举成功但 0 个 —— 要先与对照组对比再下结论"
} else {
    usbVerdict = "通路成立（枚举到 \(usb.count) 个；设备级**打开**仍需真机）"
}

say()
say("════ S1 结论 · \(sandboxed ? "沙盒版" : "对照组（**未沙盒** —— 它的 PASS 只证明探针本身没坏）")")
say("  S1-a 可执行包内 adb         : \(s1a ? "PASS" : "FAIL")")
say("  S1-b adb server 起得来      : \(s1b ? "PASS" : "FAIL")")
say("  S1-c 经 USB 看见真机        : \(s1c)")
say("  S1-c′ USB 通路（辅助判据）  : \(usbVerdict)")
say("  判据自检：沙盒真的生效了吗  : \(sandboxed ? "是" : "**否**")")
if sandboxed && homeReadable {
    say("  ⚠️ 沙盒已生效但真实家目录仍可列 —— 判据需要复核，先别信上面的 PASS")
}
// 机器可读行：外壳脚本靠它们汇总，不去猜上面那些对齐全角空格的文本。
// 只输出**结论**（PASS / FAIL / 分类），不输出路径与设备名 —— 这行会进日志。
say("MACHINE S1-a=\(s1a ? "PASS" : "FAIL")")
say("MACHINE S1-b=\(s1b ? "PASS" : "FAIL")")
say("MACHINE S1-c=\(physical.isEmpty ? (emulators.isEmpty ? "NO-DEVICE" : "EMULATOR-ONLY") : "PHYSICAL")")
say("MACHINE sandbox=\(sandboxed ? "yes" : "no")")
say("SPIKE-SANDBOX-ADB done")

exit(s1a ? 0 : 1)
