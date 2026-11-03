// 検証用。スワイプ合成で切り替わるか、何 ms かかるかを測る。ホストでは実行しない。
// 使い方: swipe <right|left> <回数> [gapMs] [yabai|raycast|hid]
// 合成の手法は InstantSpaceSwitcher (MIT) の iss_post_dock_swipe を参考にした。
// raycast: Raycast 2.10.1 の macOS 26 以前の形式（逆アセンブルで読んだもの）。
// hid: Raycast 2.10.1 の macOS 27 以降の形式。ここでは macOS 26 でも動くかを試す。
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

/// 付随イベント（種別 29）。Raycast は DockControl の直後に送っている。
func postCompanion() {
    guard let c = CGEvent(source: nil) else { fatalError("CGEvent") }
    c.setIntegerValueField(field(55), value: 29)
    c.post(tap: .cgSessionEventTap)
}

func postRaycast(phase: Int64, sign: Double) {
    guard let e = CGEvent(source: nil) else { fatalError("CGEvent") }
    e.setIntegerValueField(field(55), value: 30)
    e.setIntegerValueField(field(110), value: 23)
    e.setIntegerValueField(field(132), value: phase)
    e.setIntegerValueField(field(135), value: sign > 0 ? 1 : -2147483647)
    e.setIntegerValueField(field(123), value: 1)
    e.setDoubleValueField(field(119), value: 0)
    e.setDoubleValueField(field(129), value: sign * 999999)
    e.setDoubleValueField(field(130), value: 0)
    e.setDoubleValueField(field(139), value: 1.401298464324817e-45)
    e.post(tap: .cgSessionEventTap)
    postCompanion()
}

func appendLE<T: FixedWidthInteger>(_ v: T, _ d: inout Data) {
    withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
}

func ioFixed(_ v: Double) -> Int32 {
    let f = Int32((v * 65536).rounded(.towardZero))
    return f == 0 && v != 0 ? (v > 0 ? 1 : -1) : f
}

func hidPayload(phase: Int64, progress: Double) -> Data {
    var d = Data()
    appendLE(mach_absolute_time(), &d)
    appendLE(UInt64(0), &d)
    appendLE(UInt32(0), &d)
    appendLE(UInt32(0), &d)
    appendLE(UInt32(1), &d)
    appendLE(UInt32(40), &d)
    appendLE(UInt32(23), &d)
    appendLE(UInt32(truncatingIfNeeded: phase) << 24, &d)
    d.append(contentsOf: [0, 0, 0, 0])
    appendLE(ioFixed(0.1), &d)
    appendLE(Int32(0), &d)
    appendLE(Int32(0), &d)
    appendLE(Int32(0), &d)
    appendLE(UInt16(1), &d)
    appendLE(UInt16(3), &d)
    appendLE(ioFixed(progress), &d)
    return d
}

func postHID(phase: Int64, sign: Double) {
    let natural = CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                            kCFPreferencesAnyApplication) as? Bool ?? true
    let direction = sign * (natural ? -1 : 1)
    let p = direction * 0.000016
    guard let e = CGEvent(source: nil) else { fatalError("CGEvent") }
    e.setIntegerValueField(field(55), value: 30)
    e.setIntegerValueField(field(110), value: 23)
    e.setIntegerValueField(field(132), value: phase)
    e.setIntegerValueField(field(134), value: phase)
    e.setIntegerValueField(field(135), value: Int64(Int32(bitPattern: Float(p).bitPattern)))
    e.setIntegerValueField(field(123), value: 1)
    e.setIntegerValueField(field(115), value: 0)
    e.setDoubleValueField(field(124), value: p)
    e.setDoubleValueField(field(125), value: 0.1)
    e.setDoubleValueField(field(126), value: 0)
    if phase == 4 { e.setDoubleValueField(field(129), value: direction * 9999) }
    e.setDoubleValueField(field(130), value: 0)
    e.setDoubleValueField(field(138), value: 3)
    e.setDoubleValueField(field(169), value: Double(mach_absolute_time()))
    var data = e.data! as Data
    let payload = hidPayload(phase: phase, progress: p)
    withUnsafeBytes(of: UInt16(payload.count).bigEndian) { data.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt16(4205).bigEndian) { data.append(contentsOf: $0) }
    data.append(payload)
    guard let rebuilt = CGEvent(withDataAllocator: nil, data: data as CFData) else { fatalError("rebuild") }
    rebuilt.post(tap: .cgSessionEventTap)
    postCompanion()
}

let args = CommandLine.arguments
guard args.count >= 3, let count = Int(args[2]) else {
    print("usage: swipe <right|left> <count> [gapMs] [yabai|raycast|hid]")
    exit(64)
}
let sign: Double = args[1] == "right" ? 1 : -1
let gapMs = args.count > 3 ? Int(args[3]) ?? 0 : 0
let yabaiStyle = args.contains("yabai")
let raycastStyle = args.contains("raycast")
let hidStyle = args.contains("hid")

let before = layout()
let startIndex = before.order.firstIndex(of: before.current) ?? -1
print("AXIsProcessTrusted:", AXIsProcessTrusted())
print("before: index \(startIndex + 1)/\(before.order.count) \(before.current)")

let started = Date()
for i in 0..<count {
    if raycastStyle {
        for phase: Int64 in [1, 2, 4] { postRaycast(phase: phase, sign: sign) }
    } else if hidStyle {
        for phase: Int64 in [1, 2, 4] { postHID(phase: phase, sign: sign) }
    } else if yabaiStyle {
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
