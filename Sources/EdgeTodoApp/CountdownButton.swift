import SwiftUI

struct CountdownButton: View {
    let todoID: UUID
    let isHovered: Bool
    @ObservedObject var manager: CountdownManager
    @Binding var selectedID: UUID?
    let pointerEntered: () -> Void
    let pointerExited: () -> Void
    let menuVisibilityChanged: (Bool) -> Void
    private let running = Color(red: 113/255, green: 103/255, blue: 153/255)
    private let paused = Color(red: 153/255, green: 148/255, blue: 161/255)
    private let expired = Color(red: 153/255, green: 92/255, blue: 104/255)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let timer = manager.timer(for: todoID)
            let state = timer?.status(at: context.date)
            Button { selectedID = selectedID == todoID ? nil : todoID } label: {
                HStack(spacing: 4) {
                    CountdownStatusIcon(state: state).frame(width: 14, height: 14)
                    if let timer {
                        Text(state == .expired ? "已到时" : Self.formatted(timer.remaining(at: context.date)))
                            .font(.system(size: 12)).monospacedDigit()
                    }
                }
                .foregroundStyle(state == .paused ? paused : state == .expired ? expired : running)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(selectedID == todoID ? Color(red: 236/255, green: 234/255, blue: 244/255) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
                .frame(minWidth: 31, minHeight: 21, alignment: .topTrailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .opacity(timer == nil && !isHovered && selectedID != todoID ? 0 : 1)
            .allowsHitTesting(timer != nil || isHovered || selectedID == todoID)
            .accessibilityHidden(timer == nil && !isHovered && selectedID != todoID)
            .accessibilityLabel(state == .paused ? "已暂停，管理倒计时" : state == .expired ? "已到时，管理倒计时" : timer == nil ? "设置倒计时" : "管理倒计时")
            .background(CountdownFloatingPresenter(todoID: todoID, selectedID: $selectedID, manager: manager,
                pointerEntered: pointerEntered, pointerExited: pointerExited, menuVisibilityChanged: menuVisibilityChanged))
        }
    }
    static func formatted(_ remaining: TimeInterval) -> String {
        let seconds = max(0, Int(ceil(remaining))), hours = seconds / 3600, mins = seconds % 3600 / 60, secs = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, mins, secs) : String(format: "%02d:%02d", mins, secs)
    }
}

private struct CountdownStatusIcon: View {
    let state: Countdown.Status?
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 20
            var path = Path()
            if state == .paused {
                path.move(to: CGPoint(x: 7.2 * scale, y: 5.2 * scale)); path.addLine(to: CGPoint(x: 7.2 * scale, y: 14.8 * scale))
                path.move(to: CGPoint(x: 12.8 * scale, y: 5.2 * scale)); path.addLine(to: CGPoint(x: 12.8 * scale, y: 14.8 * scale))
            } else {
                path.addEllipse(in: CGRect(x: 3.5 * scale, y: 4 * scale, width: 13 * scale, height: 13 * scale))
                path.move(to: CGPoint(x: 8 * scale, y: 1.8 * scale)); path.addLine(to: CGPoint(x: 12 * scale, y: 1.8 * scale))
                path.move(to: CGPoint(x: 10 * scale, y: 7 * scale)); path.addLine(to: CGPoint(x: 10 * scale, y: 10.8 * scale))
                if state == .expired {
                    path.move(to: CGPoint(x: 10 * scale, y: 13.5 * scale)); path.addLine(to: CGPoint(x: 10.01 * scale, y: 13.5 * scale))
                } else { path.addLine(to: CGPoint(x: 12.7 * scale, y: 12.3 * scale)) }
            }
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: (state == .paused ? 2.2 : 1.5) * scale, lineCap: .round, lineJoin: .round))
        }.accessibilityHidden(true)
    }
}
