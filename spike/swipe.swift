// 検証用。スワイプ合成で切り替わるか、何 ms かかるかを測る。ホストでは実行しない。
// 使い方: swipe <right|left> <回数> [gapMs] [yabai]
// 合成の手法は InstantSpaceSwitcher (MIT) の iss_post_dock_swipe を参考にした。
import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ c: Int32) -> CFArray

func layout() -> (current: String, order: [String]) {
    let raw = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
    guard let d = raw.first else { return ("?", []) }
    let current = (d["Current Space"] as? [String: Any])?["uuid"] as? String ?? "?"
    let order = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["uuid"] as? String }
    return (current, order)
}

func field(_ n: UInt32) -> CGEventField { unsafeBitCast(n, to: CGEventField.self) }

func post(phase: Int64, sign: Double, progress: Double, velocity: Double) {
    guard let e = CGEvent(source: nil) else { fatalError("CGEvent") }
    e.setIntegerValueField(field(55), value: 30)
    e.setIntegerValueField(field(110), value: 23)
    e.setIntegerValueField(field(132), value: phase)
    e.setDoubleValueField(field(124), value: sign * progress)
    e.setIntegerValueField(field(123), value: 1)
    e.setDoubleValueField(field(129), value: sign * velocity)
    e.setDoubleValueField(field(130), value: sign * velocity)
    e.post(tap: .cgSessionEventTap)
}

let args = CommandLine.arguments
guard args.count >= 3, let count = Int(args[2]) else {
    print("usage: swipe <right|left> <count> [gapMs] [yabai]")
    exit(64)
}
let sign: Double = args[1] == "right" ? 1 : -1
let gapMs = args.count > 3 ? Int(args[3]) ?? 0 : 0
let yabaiStyle = args.contains("yabai")

let before = layout()
let startIndex = before.order.firstIndex(of: before.current) ?? -1
print("AXIsProcessTrusted:", AXIsProcessTrusted())
print("before: index \(startIndex + 1)/\(before.order.count) \(before.current)")

let started = Date()
for i in 0..<count {
    if yabaiStyle {
        post(phase: 1, sign: sign, progress: 1, velocity: 9999)
        post(phase: 4, sign: sign, progress: 1, velocity: 9999)
    } else {
        post(phase: 1, sign: sign, progress: 0.000016, velocity: 2000)
        post(phase: 2, sign: sign, progress: 0.000016, velocity: 2000)
        post(phase: 4, sign: sign, progress: 0.000016, velocity: 2000)
    }
    if gapMs > 0, i < count - 1 { usleep(UInt32(gapMs) * 1000) }
}
let posted = Date().timeIntervalSince(started) * 1000

// 現在地が変わった最後の時刻を 1.5 秒間記録する
var last = before.current
var lastChange: Double?
var path: [Int] = []
while Date().timeIntervalSince(started) < 1.5 {
    let now = layout()
    if now.current != last {
        last = now.current
        lastChange = Date().timeIntervalSince(started) * 1000
        path.append((now.order.firstIndex(of: now.current) ?? -2) + 1)
    }
    usleep(2000)
}
print(String(format: "posted in %.1f ms", posted))
print("visited:", path)
if let lastChange {
    print(String(format: "settled at %.0f ms", lastChange))
} else {
    print("no change")
}
let final = layout()
print("after: index \((final.order.firstIndex(of: final.current) ?? -2) + 1)/\(final.order.count)")
