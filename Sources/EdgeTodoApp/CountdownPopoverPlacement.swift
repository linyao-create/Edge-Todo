import CoreGraphics

enum CountdownMenuLayout {
    static let size = CGSize(width: 168, height: 104)
}

enum CountdownPopoverPlacement {
    static func frame(panel: CGSize, anchor: CGRect, menu: CGSize, gap: CGFloat = 8, inset: CGFloat = 8) -> CGRect {
        let maxY = max(inset, panel.height - menu.height - inset)
        let below = anchor.maxY + gap
        let above = anchor.minY - menu.height - gap
        let desired: CGFloat
        if below <= maxY { desired = below }
        else if above >= inset { desired = above }
        else { desired = (panel.height - inset - anchor.maxY) >= (anchor.minY - inset) ? below : above }
        let maxX = max(inset, panel.width - menu.width - inset)
        let x = min(maxX, max(inset, anchor.maxX - menu.width))
        return CGRect(x: x, y: min(maxY, max(inset, desired)), width: menu.width, height: menu.height)
    }
    static func screenFrame(panel: CGRect, anchor: CGRect, screen: CGRect, menu: CGSize,
                            gap: CGFloat = 8, inset: CGFloat = 12, referenceHeight: CGFloat? = nil) -> CGRect {
        let localAnchor = CGRect(x: anchor.minX - panel.minX, y: panel.maxY - anchor.maxY, width: anchor.width, height: anchor.height)
        let referenceSize = CGSize(width: menu.width, height: max(menu.height, referenceHeight ?? menu.height))
        let reference = frame(panel: panel.size, anchor: localAnchor, menu: referenceSize, gap: gap, inset: inset)
        let isAbove = reference.maxY <= localAnchor.minY
        let desiredY = isAbove ? localAnchor.minY - menu.height - gap : localAnchor.maxY + gap
        let maxY = max(inset, panel.height - menu.height - inset)
        let local = CGRect(x: reference.minX, y: min(maxY, max(inset, desiredY)), width: menu.width, height: menu.height)
        return CGRect(x: panel.minX + local.minX, y: panel.maxY - local.maxY, width: local.width, height: local.height)
    }
}
