// 确定「复现设备端折叠规则」的 Swift 配方。
//
// 候选：
//   A. lowercased() + NFC                    ← 现在的实现
//   B. folding(options: .caseInsensitive) + NFC
//   C. folding(options: [.caseInsensitive, .diacriticInsensitive])   ← 预期过宽
//
// 目标：ß~ss ✓、ﬁ~fi ✓、Kelvin~k ✓、Angstrom~å ✓、σ~ς ✓；
//       而 Ａ~A ✗、ⓞ~o ✗、é~e ✗、ﬁ~f ✗（后四条是「不能折叠」的边界）。
import Foundation

func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

let recipes: [(String, (String) -> String)] = [
    ("A lowercased+NFC", { nfc($0.lowercased()) }),
    ("B folding(caseInsensitive)+NFC", { nfc($0.folding(options: .caseInsensitive, locale: nil)) }),
    ("C folding(+diacritic)+NFC", { nfc($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }),
    ("D folding(+width)+NFC", { nfc($0.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)) }),
]

// (a, b, 应当等价？, 说明)
let cases: [(String, String, Bool, String)] = [
    ("\u{00DF}", "ss", true, "ß ~ ss（完整折叠）"),
    ("\u{FB01}", "fi", true, "ﬁ ~ fi（完整折叠）"),
    ("\u{212A}", "k", true, "KELVIN ~ k（完整折叠）"),
    ("\u{212B}", "\u{00C5}", true, "ANGSTROM ~ Å（完整折叠）"),
    ("\u{03C3}", "\u{03C2}", true, "σ ~ ς（完整折叠）"),
    ("\u{0130}", "i\u{0307}", true, "İ ~ i+dot（完整折叠）"),
    ("A", "\u{FF21}", false, "A vs 全角Ａ（不能折叠）"),
    ("o", "\u{24DE}", false, "o vs ⓞ（不能折叠）"),
    ("caf\u{00E9}", "cafe", false, "é vs e（不能折叠）"),
    ("cafe\u{0301}", "caf\u{00E9}", true, "NFD é ~ NFC é（NFC 归一化，必须等价）"),
]

func pad(_ s: String, _ n: Int) -> String {
    var out = s
    // 用字素簇数对齐（中文/emoji 才不会把表格挤歪）
    let width = s.count
    if width < n { out += String(repeating: " ", count: n - width) }
    return out
}

print(pad("配方", 36) + cases.map { pad(String($0.3.prefix(8)), 10) }.joined())
print()

for (name, fold) in recipes {
    var wrong = 0
    var cells: [String] = []
    for (a, b, shouldFold, _) in cases {
        let got = fold(a) == fold(b)
        if got != shouldFold { wrong += 1 }
        cells.append(got == shouldFold ? "✓" : "✗")
    }
    let line = pad(name, 36) + cells.map { pad($0, 10) }.joined()
        + "  错 \(wrong) 项" + (wrong == 0 ? "  ← 与设备端实测一致" : "")
    print(line)
}

print()
print(String(repeating: "=", count: 96))
print("各配方对关键字符的实际输出")
print(String(repeating: "=", count: 96))
for (name, fold) in recipes {
    print(name)
    for probe in ["\u{00DF}.txt", "\u{FB01}le.txt", "\u{212A}.txt", "A.txt", "\u{FF21}.txt",
                  "caf\u{00E9}.txt", "cafe\u{0301}.txt"] {
        print("   \(probe.debugDescription) → \(fold(probe).debugDescription)")
    }
}
