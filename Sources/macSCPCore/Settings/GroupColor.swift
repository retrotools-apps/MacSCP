import Foundation

/// An opaque sRGB group identifier. Text and status colors remain semantic.
public struct GroupColor: Hashable, Sendable, Codable {
    public let rgb: UInt32

    public init(rgb: UInt32) { self.rgb = rgb & 0xFFFFFF }

    public init?(hex: String) {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(rgb: rgb)
    }

    public var hex: String { String(format: "#%06X", rgb) }
    public var red: Double { Double((rgb >> 16) & 255) / 255 }
    public var green: Double { Double((rgb >> 8) & 255) / 255 }
    public var blue: Double { Double(rgb & 255) / 255 }

    /// Automatic child hues can follow a chromatic parent; neutral parents
    /// leave the existing automatic hierarchy spacing in control.
    public var hue: Double? {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard delta > 0 else { return nil }
        let sector: Double
        if maximum == red { sector = (green - blue) / delta }
        else if maximum == green { sector = (blue - red) / delta + 2 }
        else { sector = (red - green) / delta + 4 }
        return (sector / 6 + 1).truncatingRemainder(dividingBy: 1)
    }

    public var relativeLuminance: Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let value = Self(hex: hex) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid sRGB group color")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// Perceptual OKLab distance avoids treating unequal RGB channel changes
    /// as equally visible when deciding which unused swatch can be replaced.
    public func distance(to other: Self) -> Double {
        func lab(_ color: Self) -> (Double, Double, Double) {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        }
        let a = lab(self), b = lab(other)
        return sqrt(pow(a.0 - b.0, 2) + pow(a.1 - b.1, 2) + pow(a.2 - b.2, 2))
    }
}

public enum GroupColorPalette {
    /// The original 24 pastel hues (saturation 0.5, brightness 0.9), encoded
    /// in sRGB so custom colors and presets share the same storage format.
    public static let defaults: [GroupColor] = [
        0xE67373, 0xE68F73, 0xE6AC73, 0xE6C973,
        0xE6E673, 0xC9E673, 0xACE673, 0x8FE673,
        0x73E673, 0x73E68F, 0x73E6AC, 0x73E6C9,
        0x73E6E6, 0x73C9E6, 0x73ACE6, 0x738FE6,
        0x7373E6, 0x8F73E6, 0xAC73E6, 0xC973E6,
        0xE673E6, 0xE673C9, 0xE673AC, 0xE6738F,
    ].map { GroupColor(rgb: $0) }

    /// Replace only a perceptually close, unused color. Otherwise append;
    /// neither a dissimilar swatch nor a group already using it is changed.
    public static func adding(_ color: GroupColor, to palette: [GroupColor], used: Set<GroupColor>) -> [GroupColor] {
        guard !palette.contains(color) else { return palette }
        var result = palette
        if let index = palette.indices.filter({ !used.contains(palette[$0]) })
            .min(by: { palette[$0].distance(to: color) < palette[$1].distance(to: color) }),
           palette[index].distance(to: color) < 0.06 {
            result[index] = color
        } else {
            result.append(color)
        }
        return result
    }
}
