//
//  ProfileColor.swift
//  Tecolot
//
//  A value-type, Codable color used by themes and profiles. SwiftTerm's
//  `Color` is a reference type and not Codable, so the models store this
//  wrapper and bridge at the point of application.
//
import Foundation
import SwiftTerm

public struct ProfileColor: Codable, Hashable, Sendable {
    /// Red component, 0...65535 (matches SwiftTerm.Color depth)
    public var red: UInt16
    /// Green component, 0...65535
    public var green: UInt16
    /// Blue component, 0...65535
    public var blue: UInt16

    public init (red: UInt16, green: UInt16, blue: UInt16) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init (_ color: SwiftTerm.Color) {
        self.init (red: color.red, green: color.green, blue: color.blue)
    }

    /// Parses "#rgb", "#rrggbb", "#rrrrggggbbbb" or "rgb:rr/gg/bb" style specifications
    public init? (hex: String) {
        guard let parsed = SwiftTerm.Color.parse (hex) else {
            return nil
        }
        self.init (parsed)
    }

    /// The color as a SwiftTerm terminal color
    public var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color (red: red, green: green, blue: blue)
    }

    /// "#rrggbb" when the color is losslessly 8-bit per channel, the lossless
    /// X11 "rgb:rrrr/gggg/bbbb" form otherwise
    public var hexString: String {
        if red % 257 == 0 && green % 257 == 0 && blue % 257 == 0 {
            return String (format: "#%02x%02x%02x", red / 257, green / 257, blue / 257)
        }
        return String (format: "rgb:%04x/%04x/%04x", red, green, blue)
    }

    // Codable: encode as a single, human-editable color string
    public init (from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer ()
        let spec = try container.decode (String.self)
        guard let color = ProfileColor (hex: spec) else {
            throw DecodingError.dataCorruptedError (in: container, debugDescription: "Invalid color specification: \(spec)")
        }
        self = color
    }

    public func encode (to encoder: Encoder) throws {
        var container = encoder.singleValueContainer ()
        try container.encode (hexString)
    }
}
