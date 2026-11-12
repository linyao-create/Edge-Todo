import AppKit
import SwiftUI

/// Colors are taken from the approved navigation-A HTML/CSS prototype.
enum PanelTheme {
    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    static let panel = Color(nsColor: rgb(0xfbfbfd))
    static let panelBorder = Color(nsColor: rgb(0x58566f)).opacity(0.17)
    static let panelShadow = Color(nsColor: rgb(0x2b2843)).opacity(0.13)
    static let textNS = rgb(0x292832)
    static let completedNS = rgb(0x77737f)
    static let caretNS = rgb(0x34333f)
    static let date = Color(nsColor: rgb(0x6e6a79))
    static let todayPlaceholderNS = rgb(0xc8c3d0)
    static let todayPlaceholder = Color(nsColor: todayPlaceholderNS)
    static let placeholder = Color(nsColor: rgb(0x898391))
    static let selectedTab = Color(nsColor: rgb(0x302c3d))
    static let tab = Color(nsColor: rgb(0x726d7c))
    static let hoveredTab = Color(nsColor: rgb(0x514b5d))
    static let underline = Color(nsColor: rgb(0x746d99))
    static let icon = Color(nsColor: rgb(0x777384))
    static let iconHover = Color(nsColor: rgb(0x5c568c))
    static let iconHoverBackground = Color(nsColor: rgb(0xeeedf5))
    static let inputPlus = Color(nsColor: rgb(0xa09baa))
    static let inputPlusFocused = Color(nsColor: rgb(0x7167a2))
    static let inputBackground = Color(nsColor: rgb(0xf7f6fa))
    static let inputHoveredBackground = Color(nsColor: rgb(0xf4f3f8))
    static let inputFocusedBackground = Color(nsColor: rgb(0xf1f0f7))
    static let rowHover = Color(nsColor: rgb(0xf3f2f8))
    static let bullet = Color(nsColor: rgb(0xa8a3ba))
    static let checkbox = Color(nsColor: rgb(0xb8b5c8))
    static let checkboxCompleted = Color(nsColor: rgb(0x8177bc))
    static let link = Color(nsColor: rgb(0x393549))
    static let linkHover = Color(nsColor: rgb(0x6c60a6))
    static let domain = Color(nsColor: rgb(0x6f6a7b))
    static let moveNS = rgb(0x827a9a)
    static let scrollThumbNS = rgb(0xbbb8ca)
    static let handle = Color(nsColor: rgb(0x85819d))
    static let handleHover = Color(nsColor: rgb(0x6d659d))
}
