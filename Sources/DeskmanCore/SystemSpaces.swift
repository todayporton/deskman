import CoreGraphics

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ c: Int32) -> CFArray
@_silgen_name("CGSGetActiveSpace") private func CGSGetActiveSpace(_ c: Int32) -> Int

public enum SystemSpaces {
    public static func current() -> [Space] {
        let c = CGSMainConnectionID()
        let raw = CGSCopyManagedDisplaySpaces(c) as? [[String: Any]] ?? []
        return SpaceParser.parse(raw, activeID: CGSGetActiveSpace(c))
    }
}
