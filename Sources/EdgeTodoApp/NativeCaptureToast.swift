import AppKit
import SwiftUI

enum NativeCaptureToastPlacement {
    static func frame(pointer: CGPoint, visibleFrame: CGRect, size: CGSize) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        let x = min(max(pointer.x - width / 2, visibleFrame.minX), visibleFrame.maxX - width)
        let below = pointer.y - 7 - height
        let y = min(max(below, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
final class NativeCaptureToast {
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    func show(message: String, isError: Bool, anchor: CGPoint) {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main else { return }
        let width: CGFloat = isError ? 300 : 200
        let height: CGFloat = isError ? 72 : 60
        let frame = NativeCaptureToastPlacement.frame(pointer: anchor, visibleFrame: screen.visibleFrame, size: CGSize(width: width, height: height))
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: NativeCaptureToastView(message: message, isError: isError))
        panel = window
        window.orderFrontRegardless()
        dismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(isError ? 4500 : 2500)) } catch { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}

private struct NativeCaptureToastView: View {
    let message: String
    let isError: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 14, weight: .medium))
            Text(message).font(.system(size: 12, weight: .medium)).lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isError ? Color(red: 0.62, green: 0.40, blue: 0.43) : PanelTheme.tab)
        .padding(.horizontal, 13).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.97)))
        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
        .padding(9)
        .accessibilityElement(children: .combine)
    }
}
