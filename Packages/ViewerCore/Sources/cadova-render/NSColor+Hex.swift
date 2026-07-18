import AppKit

extension NSColor {
    convenience init?(cadovaRenderHex hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let intValue = UInt32(value, radix: 16) else { return nil }
        let red = CGFloat((intValue >> 16) & 0xFF) / 255
        let green = CGFloat((intValue >> 8) & 0xFF) / 255
        let blue = CGFloat(intValue & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}
