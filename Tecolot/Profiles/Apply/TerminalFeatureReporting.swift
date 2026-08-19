//
//  TerminalFeatureReporting.swift
//  Tecolot
//
//  iTerm2 terminal feature reporting for the capabilities that SwiftTerm and
//  the Tecolot host implement together.
//

enum TerminalFeatureReporting {
    /// The value for TERM_FEATURES and OSC 1337 Capabilities reports.
    ///
    /// Advertised features:
    /// - T3: both 24-bit color forms
    /// - Cw: writable clipboard
    /// - Lr: left and right margins
    /// - M: SGR mouse reporting
    /// - Sc7: cursor styles 0 through 6
    /// - U and Uw17: basic Unicode with Unicode 17 width data
    /// - Ts3: title stacks and title setting
    /// - B, F, Gs, Sy, H, Sx, and P: bracketed paste, focus reporting,
    ///   strikethrough, synchronized output, hyperlinks, Sixel, and progress
    static let featureString = "T3CwLrMSc7UUw17Ts3BFGsSyHSxP"
}
