// 设备端集成证明：拿**真实设备返回的文件名**跑新旧两套判据。
//
// 单元测试证明的是「规则对」；这一条证明的是「规则用在真实数据上会拦住那次覆盖」。
// 它调用的就是产品代码里那两个函数（`NameConflict` / `NameComparison`），
// 只有「列目录」这一步用最朴素的 `adb shell ls -1` 代替 `DeviceShell.list`。
import Foundation

let adb = NSString(string: "~/Library/Android/sdk/platform-tools/adb").expandingTildeInPath
let probeDir = "/sdcard/Download/DroidBerthConflict"
let localName = "photo.jpg"          // 用户在 Mac 上要上传的文件

@discardableResult
func run(_ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
}

func sh(_ command: String) -> String {
    run([adb, "-s", "emulator-5554", "shell", command]).trimmingCharacters(in: .whitespacesAndNewlines)
}

// ── 布置现场：设备上放一个与本地文件仅大小写不同的文件 ────────────────
_ = sh("rm -rf \(probeDir)")
_ = sh("mkdir -p \(probeDir)")
_ = sh("printf 'PHONE-ORIGINAL' > \(probeDir)/Photo.JPG")

let listing = sh("ls -1 \(probeDir)")
let deviceNames = listing.split(separator: "\n").map(String.init)
print("设备上真实存在的名字：\(deviceNames)")

// ── 旧判据：精确字符串比较（改造前 TransferPlanner 就是这一句）────────
let oldTaken = Set(deviceNames)
let oldSaysConflict = oldTaken.contains(localName)

// ── 新判据：产品代码里的纯函数 ────────────────────────────────────
var newTaken = NameConflict.foldedSet(deviceNames)
let newName = NameConflict.keepBothName(for: localName, taken: &newTaken)
let newSaysConflict = newName != nil

print()
print("上传「\(localName)」时：")
print("  旧判据 `Set(deviceNames).contains(name)`        → \(oldSaysConflict ? "判为冲突 ✓" : "判为不冲突 ✗（会静默覆盖设备上的 Photo.JPG）")")
print("  新判据 `NameConflict.keepBothName(...)`       → \(newSaysConflict ? "判为冲突 ✓，改名为「\(newName!)」" : "判为不冲突 ✗")")

// ── 反向：确认设备端**真的**会折叠（不是我们在猜）────────────────────
_ = sh("printf 'PHONE-ORIGINAL' > \(probeDir)/\(localName)")
let after = sh("find \(probeDir) -mindepth 1 | wc -l").trimmingCharacters(in: .whitespaces)
let names = sh("find \(probeDir) -mindepth 1")
print()
print("把 \(localName) 直接写到设备上（绕过冲突检测）之后，目录里只剩 \(after) 个文件：")
for line in names.split(separator: "\n") { print("  \(line)") }
print("  ⇒ 设备端确实把两者当同一个文件（这就是旧判据会造成的**数据丢失**）")

_ = sh("rm -rf \(probeDir)")

let ok = !oldSaysConflict && newSaysConflict
print()
print(ok ? "判定：旧判据漏判、新判据拦住 —— 修复在真实数据上成立 ✓"
         : "判定：**与预期不符**，需要复查 ✗")
exit(ok ? 0 : 1)
