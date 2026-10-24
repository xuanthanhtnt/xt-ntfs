import SwiftUI
import AppKit

extension Color {
    /// A color that follows the current light/dark appearance.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

enum Theme {
    // Sidebar (navy, as in the reference design)
    static let sidebarTop = Color.dynamic(light: Color.rgb(64, 72, 116), dark: Color.rgb(38, 42, 66))
    static let sidebarBottom = Color.dynamic(light: Color.rgb(48, 54, 90), dark: Color.rgb(28, 31, 50))
    static let sidebarFooter = Color.dynamic(light: Color.rgb(44, 49, 82), dark: Color.rgb(24, 27, 44))
    static let sidebarSelection = Color.white.opacity(0.13)
    static let sidebarHover = Color.white.opacity(0.06)
    static let sidebarText = Color.white
    static let sidebarSecondary = Color.white.opacity(0.68)
    static let sidebarSection = Color.white.opacity(0.48)

    // Detail pane
    static let detailBackground = Color.dynamic(light: Color.rgb(232, 232, 234), dark: Color.rgb(40, 40, 44))
    static let toolbarBackground = Color.dynamic(light: Color.rgb(245, 245, 247), dark: Color.rgb(50, 50, 55))
    static let card = Color.dynamic(light: Color.rgb(220, 220, 224), dark: Color.rgb(58, 58, 64))
    static let cardText = Color.primary
    static let divider = Color.dynamic(light: Color.rgb(200, 200, 205), dark: Color.rgb(70, 70, 76))

    // Accents
    static let accent = Color.dynamic(light: Color.rgb(64, 110, 214), dark: Color.rgb(98, 146, 255))
    static let mountBlue = Color.dynamic(light: Color.rgb(70, 120, 210), dark: Color.rgb(110, 155, 240))
    static let verifyGreen = Color.dynamic(light: Color.rgb(40, 150, 100), dark: Color.rgb(70, 190, 130))
    static let erasePink = Color.dynamic(light: Color.rgb(214, 96, 140), dark: Color.rgb(236, 120, 162))
    static let startupBlue = Color.dynamic(light: Color.rgb(60, 90, 170), dark: Color.rgb(120, 150, 230))

    static let statusRW = Color(nsColor: Color.rgb(86, 196, 108))
    static let statusRO = Color(nsColor: Color.rgb(222, 150, 70))
    static let statusOff = Color.white.opacity(0.3)

    static let badgeNTFS = Color(nsColor: Color.rgb(58, 120, 220))
    static let badgeMac = Color(nsColor: Color.rgb(212, 92, 160))
    static let badgeOther = Color(nsColor: Color.rgb(120, 128, 150))

    // Usage categories
    static let catApps = Color(nsColor: Color.rgb(239, 96, 88))
    static let catAudio = Color(nsColor: Color.rgb(250, 177, 60))
    static let catVideo = Color(nsColor: Color.rgb(168, 112, 230))
    static let catImages = Color(nsColor: Color.rgb(84, 190, 120))
    static let catDocs = Color(nsColor: Color.rgb(70, 170, 220))
    static let catOther = Color(nsColor: Color.rgb(96, 136, 214))
    static let barTrack = Color.dynamic(light: Color.rgb(208, 208, 214), dark: Color.rgb(70, 70, 78))
}
