//
// SessionLaunch.swift
// TecolotSessionDirectory
//
// The description of a new session. The app (or the bridge on a remote
// host) builds it from the profile; the helper reads it as JSON.
//

import Foundation
import TecolotWire

public struct SessionTheme: Codable, Hashable, Sendable {
    /// The first 16 ANSI colors.
    public var palette: [WireRGBCodable]
    public var foreground: WireRGBCodable
    public var background: WireRGBCodable
    public var cursor: WireRGBCodable?

    public init(palette: [WireRGBCodable], foreground: WireRGBCodable,
                background: WireRGBCodable, cursor: WireRGBCodable? = nil) {
        self.palette = palette
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
    }
}

/// `WireRGB` with a Codable form for JSON control payloads.
public struct WireRGBCodable: Codable, Hashable, Sendable {
    public var r: UInt16
    public var g: UInt16
    public var b: UInt16

    public init(r: UInt16, g: UInt16, b: UInt16) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(_ rgb: WireRGB) { self.init(r: rgb.red, g: rgb.green, b: rgb.blue) }
    public var wire: WireRGB { WireRGB(red: r, green: g, blue: b) }
}

public struct SessionLaunch: Codable, Hashable, Sendable {
    public var executable: String
    /// Arguments after argv[0].
    public var arguments: [String]
    /// argv[0]; for example "-zsh" for a login shell. Nil uses `executable`.
    public var argv0: String?
    /// The complete environment as "NAME=value" entries.
    public var environment: [String]
    public var workingDirectory: String?
    public var columns: Int
    public var rows: Int
    public var cellWidth: Int
    public var cellHeight: Int
    public var scrollback: Int
    public var termName: String
    /// `CursorStyle` case index (see `WireCursor.style`).
    public var cursorStyle: UInt8
    public var featureReport: String?
    public var theme: SessionTheme?
    /// Free-form values for the session browser (profile name, and so on).
    public var labels: [String: String]
    /// Kitty graphics: the decoded bytes kept for each screen (0 turns the
    /// protocol off). Nil keeps SwiftTerm's default.
    public var kittyGraphicsStorageLimit: UInt32?
    /// Kitty graphics: `KittyGraphicsConfiguration.LocalMediaPolicy` bits.
    public var kittyGraphicsLocalMedia: UInt8?

    public init(executable: String, arguments: [String] = [], argv0: String? = nil,
                environment: [String], workingDirectory: String? = nil,
                columns: Int = 80, rows: Int = 24, cellWidth: Int = 0, cellHeight: Int = 0,
                scrollback: Int = 100_000, termName: String = "xterm-256color",
                cursorStyle: UInt8 = 0, featureReport: String? = nil,
                theme: SessionTheme? = nil, labels: [String: String] = [:],
                kittyGraphicsStorageLimit: UInt32? = nil, kittyGraphicsLocalMedia: UInt8? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.argv0 = argv0
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.columns = columns
        self.rows = rows
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.scrollback = scrollback
        self.termName = termName
        self.cursorStyle = cursorStyle
        self.featureReport = featureReport
        self.theme = theme
        self.labels = labels
        self.kittyGraphicsStorageLimit = kittyGraphicsStorageLimit
        self.kittyGraphicsLocalMedia = kittyGraphicsLocalMedia
    }
}
