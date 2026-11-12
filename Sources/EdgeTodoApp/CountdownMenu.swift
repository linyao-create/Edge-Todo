import AppKit
import SwiftUI

struct CountdownMenu: View {
    let todoID: UUID
    @ObservedObject var manager: CountdownManager
    let dismiss: () -> Void
    @State private var mode: Mode = .menu
    @State private var minutes = ""
    @State private var showError = false
    @FocusState private var focused: Bool
    private enum Mode { case menu, presets, custom }
    private let textColor = Color(red: 81/255, green: 75/255, blue: 93/255)
    private let accent = Color(red: 116/255, green: 109/255, blue: 153/255)
    private let subtle = Color(red: 119/255, green: 113/255, blue: 126/255)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = manager.timer(for: todoID)?.status(at: context.date)
            VStack(alignment: .leading, spacing: 1) {
                if mode == .custom {
                    HStack(spacing: 4) {
                        Button { mode = .presets; showError = false } label: {
                            Image(systemName: "arrow.left").font(.system(size: 12)).frame(width: 22, height: 27)
                        }.buttonStyle(.plain).foregroundStyle(subtle).accessibilityLabel("返回快捷时长")
                        TextField("25", text: $minutes).textFieldStyle(.plain).font(.system(size: 12))
                            .frame(width: 41, height: 27).focused($focused)
                            .onChange(of: minutes) { _, value in
                                guard (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
                                minutes = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(5)); showError = false
                            }
                            .onSubmit(startCustom).accessibilityLabel("自定义分钟数")
                        Text("分钟").font(.system(size: 11)).foregroundStyle(subtle)
                        Spacer(minLength: 0)
                        Button("开始", action: startCustom).buttonStyle(.plain).font(.system(size: 11))
                            .padding(.horizontal, 8).padding(.vertical, 6).foregroundStyle(.white)
                            .background(accent, in: RoundedRectangle(cornerRadius: 6))
                    }.padding(.vertical, 1).onAppear { DispatchQueue.main.async { focused = true } }
                    if showError { Text("请输入 1 至 10080 的整数分钟。").font(.system(size: 10)).foregroundStyle(Color(red: 162/255, green: 86/255, blue: 100/255)).padding(.horizontal, 5) }
                } else if mode == .presets || state == nil {
                    HStack(spacing: 1) { item("15 分钟") { start(900) }; item("30 分钟") { start(1800) } }
                    HStack(spacing: 1) { item("1 小时") { start(3600) }; item("3 小时") { start(10800) } }
                    Rectangle().fill(Color(red: 239/255, green: 237/255, blue: 243/255)).frame(height: 1).padding(.horizontal, 4).padding(.vertical, 3)
                    item("自定义…") { minutes = ""; showError = false; mode = .custom }
                } else {
                    if state == .running { item("暂停") { manager.pause(for: todoID) } }
                    if state == .paused { item("继续", icon: "play.fill") { manager.resume(for: todoID) } }
                    item(state == .expired ? "再设一轮" : "重新设置") { mode = .presets }
                    item("取消计时", danger: true) { manager.set(nil, for: todoID); dismiss() }
                }
            }
            .padding(5).frame(width: CountdownMenuLayout.size.width, alignment: .topLeading)
            .background(Color(red: 251/255, green: 251/255, blue: 253/255), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(red: 229/255, green: 226/255, blue: 235/255), lineWidth: 1))
            .shadow(color: Color(red: 43/255, green: 40/255, blue: 67/255).opacity(0.09), radius: 12, x: 0, y: 3)
        }
    }
    private func startCustom() {
        guard let n = Int(minutes), (1...10080).contains(n) else { showError = true; return }
        start(Double(n) * 60)
    }
    private func start(_ seconds: TimeInterval) { manager.start(seconds, for: todoID); dismiss() }
    private func item(_ title: String, icon: String? = nil, danger: Bool = false, action: @escaping () -> Void) -> some View {
        CountdownMenuItem(title: title, icon: icon, color: danger ? Color(red: 135/255, green: 106/255, blue: 116/255) : textColor, action: action)
    }
}

private struct CountdownMenuItem: View {
    let title: String
    let icon: String?
    let color: Color
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: 8)) }
                Text(title).font(.system(size: 12))
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 7)
                .foregroundStyle(color).background(hovered ? Color(red: 241/255, green: 239/255, blue: 246/255) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}
