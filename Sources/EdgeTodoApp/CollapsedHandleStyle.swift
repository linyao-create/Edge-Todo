import SwiftUI

enum CollapsedHandleStyle {
    static let restingWidth: CGFloat = 7
    static let restingHeight: CGFloat = 52
    static let hoverWidth: CGFloat = restingWidth
    static let hoverHeight: CGFloat = restingHeight
    static let trailingInset: CGFloat = 0
    static let animationDuration: TimeInterval = 0.22

    static let restingFill = PanelTheme.handle
    static let hoverFill = Color(red: 128/255, green: 122/255, blue: 157/255)
}
