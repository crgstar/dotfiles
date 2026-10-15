// Meltype の入力ソースを数える / 選び直す。
//   swift input-sources.swift count     # Meltype.Japanese の件数を出力 (正常なら 1)
//   swift input-sources.swift reselect  # ABC に切り替えてから Meltype に戻す
// why: 入力ソースの重複は設定 plist (AppleEnabledInputSources) には現れず、
//      TIS の一覧にだけ現れるため、TIS を直接引く。
import Carbon
import Foundation

let target = "io.github.yksr-melt.inputmethod.Meltype.Japanese"

func sourceID(_ s: TISInputSource) -> String {
    guard let v = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "" }
    return Unmanaged<CFString>.fromOpaque(v).takeUnretainedValue() as String
}

let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
let meltype = sources.filter { sourceID($0) == target }

switch CommandLine.arguments.dropFirst().first {
case "count":
    print(meltype.count)
case "reselect":
    guard let abc = sources.first(where: { sourceID($0) == "com.apple.keylayout.ABC" }),
          let melt = meltype.first else {
        fputs("ABC か Meltype が有効な入力ソースにありません\n", stderr)
        exit(1)
    }
    // why: 選択中のソースを選び直してもアプリ側の接続は張り直されない。一度離れる必要がある。
    TISSelectInputSource(abc)
    Thread.sleep(forTimeInterval: 1.0)
    TISSelectInputSource(melt)
    Thread.sleep(forTimeInterval: 0.5)
    let current = sourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
    print("current:", current)
    exit(current == target ? 0 : 1)
default:
    fputs("usage: input-sources.swift count|reselect\n", stderr)
    exit(2)
}
