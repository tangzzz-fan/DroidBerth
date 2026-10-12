import Darwin
import Foundation

// 「退出时该不该收掉 adb server」的判据（E8 / Guideline 2.4.5(iii)）。
//
// 它挡的是**第七种形态**的缺陷：**只在「退出那一刻」生效、错了没有任何反馈**的判断。
// （前六种见各自的文件头。）
//
// 两个方向都是静默的：
//
//   判成「永远不收」⇒ 机器上留一个 adb server 进程。本地毫无症状 ——
//                    要等到 App Review 说「退出后仍有进程」才知道；
//   判成「永远收」  ⇒ 把**用户 Android Studio 的** server 杀掉。他看到的是「设备突然掉了」，
//                    会去怀疑手机或数据线，而不会想到是我们。
//
// 两种都不可能靠手跑发现：要验前者得先把 5037 清空（那是用户正在用的 server），
// 要验后者得先把别人的 server 摆上去。所以把**状态迁移**与**判据**拆出来直接喂 ——
// `ADBServerOwnership` 因此刻意零项目依赖（它只 import Foundation / Darwin）。
//
// 跑法（不需要 Rust / adb，约 2 秒）：
//
//     mkdir -p /tmp/owncheck && cp scripts/check-adb-server-ownership.swift /tmp/owncheck/main.swift
//     swiftc -O -o /tmp/owncheck/run \
//       -target arm64-apple-macos14.0 \
//       -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
//       -swift-version 6 -strict-concurrency=complete \
//       macos/Sources/DroidBerth/Support/ADBServerOwnership.swift \
//       /tmp/owncheck/main.swift && /tmp/owncheck/run
//
// 注意 **必须叫 `main.swift`**（顶层代码只允许在这个文件名里）。

var failures: [String] = []

@MainActor
func check(_ label: String, _ got: Bool, _ want: Bool) {
    if got != want { failures.append("\(label)  期望 \(want)，实际 \(got)") }
}

// ── ① 判据本身：只有「我们起的」才收 ────────────────────────────────────────
// `.unknown` 那条最要紧：它表示「还没探测过」，把「不知道」当成「是我们的」就是
// 无脑 kill-server —— 那正是这里要避免的错。
check("unknown（还没探测）⇒ 不收", ADBServerOwnership.shouldShutdown(.unknown), false)
check("ours ⇒ 收", ADBServerOwnership.shouldShutdown(.ours), true)
check("foreign（复用别人的）⇒ 不收", ADBServerOwnership.shouldShutdown(.foreign), false)

// ── ①b 端口来源：必须跟着 `ANDROID_ADB_SERVER_PORT` 走 ───────────────────
// 不跟的后果是**判据与事实不符**：adb 命令走那个端口，我们却去探 5037 ——
// 探到的多半是用户的 server，于是判成 `.foreign`、**永远不收**。
// （实测就是靠它把「该收时收」测出来的：把 app 指到 15037，就不必碰用户 5037 上那个。）
check("没设环境变量 ⇒ 5037", ADBServerOwnership.port(fromEnvironment: nil) == 5037, true)
check("设了合法端口 ⇒ 用它", ADBServerOwnership.port(fromEnvironment: "15037") == 15037, true)
check("空串 ⇒ 退回 5037", ADBServerOwnership.port(fromEnvironment: "") == 5037, true)
check("非数字 ⇒ 退回 5037", ADBServerOwnership.port(fromEnvironment: "adb") == 5037, true)
check("0 不是有效端口 ⇒ 退回 5037", ADBServerOwnership.port(fromEnvironment: "0") == 5037, true)
check("超出 UInt16 ⇒ 退回 5037", ADBServerOwnership.port(fromEnvironment: "99999") == 5037, true)

// ── ② 状态迁移：探测结果 → 归属 ──────────────────────────────────────────
let idle = ADBServerOwnership()
check("初始是 unknown", idle.owner == .unknown, true)

let fresh = ADBServerOwnership()
fresh.record(serverWasListening: false)
check("探测到没人监听 ⇒ ours（接下来是我们拉起来的）", fresh.owner == .ours, true)
check("……于是退出时会收", ADBServerOwnership.shouldShutdown(fresh.owner), true)

let reused = ADBServerOwnership()
reused.record(serverWasListening: true)
check("探测到已有监听 ⇒ foreign（我们只是复用）", reused.owner == .foreign, true)
check("……于是退出时不收（那可能是用户的 Android Studio）",
      ADBServerOwnership.shouldShutdown(reused.owner), false)

// ── ③ 中途重启 server ⇒ 归属变成我们 ──────────────────────────────────────
// `ADBRecovery.restartServer()` 是**无条件** kill + start：不管之前 5037 上是谁的
// server，那一下都已经把它带走了，所以之后必须记成 ours —— 否则我们会把
// 「用户那个已经被我们杀掉、又由我们重建的 server」留在机器上。
let restarted = ADBServerOwnership()
restarted.record(serverWasListening: true)
restarted.markRestarted()
check("重启过 ⇒ 从 foreign 变 ours", restarted.owner == .ours, true)
check("……于是退出时要收", ADBServerOwnership.shouldShutdown(restarted.owner), true)

// ── ④ 收过之后回到 unknown（不许收第二次）────────────────────────────────
let released = ADBServerOwnership()
released.record(serverWasListening: false)
released.markReleased()
check("收过 ⇒ 回到 unknown", released.owner == .unknown, true)
check("……再问一次就不再收", ADBServerOwnership.shouldShutdown(released.owner), false)

// ── ⑤ 端口探测的**两个方向**都要可达 ─────────────────────────────────────
// 这条不是走过场：`isListening` 若恒为 true，归属永远是 `.foreign` ⇒ **永远不收**
// （看起来完全正常）；恒为 false 则永远是 `.ours` ⇒ **杀掉别人的 server**。
// 所以自己起一个监听 socket 来验 true 那一半 —— 不依赖机器上有没有 adb server。
func makeListener() -> (descriptor: Int32, port: UInt16)? {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return nil }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0                                  // 让内核挑一个空闲端口
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0, listen(descriptor, 1) == 0 else {
        close(descriptor)
        return nil
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(descriptor, $0, &length)
        }
    }
    return (descriptor, UInt16(bigEndian: actual.sin_port))
}

check("端口 0（内核不会把它分给任何人）⇒ false", ADBServerOwnership.isListening(port: 0), false)

if let listener = makeListener() {
    check("自己起的监听 ⇒ true（true 分支确实可达）",
          ADBServerOwnership.isListening(port: listener.port), true)
    close(listener.descriptor)
    check("把它关掉之后 ⇒ false（回到没人监听）",
          ADBServerOwnership.isListening(port: listener.port), false)
} else {
    failures.append("守卫没能在本机起监听 socket —— 上面两条测试没跑成")
}

// ─────────────────────────────────────────────────────────────

if failures.isEmpty {
    print("ALL OK")
    print("覆盖：判据三态 · **端口来源解析**（含四种非法取值）· 探测→归属两条路径 · "
          + "中途重启夺回归属 · 收过不重复收 · 端口探测的两个方向（自建监听 socket，不依赖机器上有没有 adb）")
} else {
    for failure in failures { print("  ✗ \(failure)") }
    print("FAIL —— \(failures.count) 条不符合预期。")
    exit(1)
}
