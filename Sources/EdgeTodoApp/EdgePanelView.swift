import AppKit
import SwiftUI

enum SavedLinkMenuAction: String, CaseIterable {
    case open = "打开网页"
    case delete = "删除链接"
}

struct EdgePanelView: View {
    @ObservedObject var controller: EdgePanelWindowController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredRowID: UUID?
    @State private var hoveredLinkTitleID: UUID?
    @State private var isCollapsedHandleHovered = false
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var dragOrder: [UUID] = []
    @State private var draggedID: UUID?
    @State private var controlFrames: [UUID: [CGRect]] = [:]
    @State private var clockFrames: [UUID: [CGRect]] = [:]

    private var displayedRows: [Todo] {
        let rows = controller.visibleRows
        guard !dragOrder.isEmpty else { return rows }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let ordered = dragOrder.compactMap { byID[$0] }
        let ids = Set(dragOrder)
        return ordered + rows.filter { !ids.contains($0.id) }
    }


    @State private var selectedCountdownID: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
            if controller.isExpanded {
                VStack(alignment: .leading, spacing: EdgePanelLayout.spacing) {
                    header
                        .frame(height: EdgePanelLayout.headerHeight, alignment: .topLeading)
                    if let error = controller.saveError {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                            .lineLimit(2)
                            .frame(height: 32, alignment: .topLeading)
                    }
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(displayedRows) { todo in
                                    if controller.selectedCategory == .today && todo.id == displayedRows.first(where: \.isCompleted)?.id {
                                        Rectangle().fill(PanelTheme.panelBorder)
                                            .frame(height: 0.5)
                                            .padding(.horizontal, 3)
                                            .padding(.vertical, 6)
                                            .accessibilityHidden(true)
                                    }
                                    row(todo).id(todo.id)
                                }
                            }
                            .onPreferenceChange(TaskRowFrames.self) { rowFrames = $0 }
                            .onPreferenceChange(TaskControlFrames.self) { controlFrames = $0 }
                            .onPreferenceChange(TaskClockFrames.self) { clockFrames = $0 }
                            .padding(.trailing, controller.selectedCategory == .today ? 10 : 20)
                            .background(SlimOverlayScrollerInstaller())
                            .background { interactionRouter }
                        }
                        .frame(height: controller.listViewportHeight)
                        .clipped()

                        .onChange(of: controller.focusRequest) { _, _ in
                            if let id = controller.focusedRowID { proxy.scrollTo(id) }
                        }
                        .onChange(of: controller.captureScrollRequest) { _, _ in
                            if let id = controller.capturedRowID, controller.selectedCategory == .notes {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                }
                .padding(.leading, EdgePanelLayout.horizontalPadding)
                .padding(.trailing, EdgePanelLayout.horizontalPadding)
                .padding(.top, EdgePanelLayout.topPadding)
                .padding(.bottom, EdgePanelLayout.bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if controller.isExpanded {
                Rectangle().fill(PanelTheme.panel)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: controller.isExpanded ? EdgePanelLayout.cornerRadius : 0))
        .shadow(
            color: controller.isExpanded ? PanelTheme.panelShadow : .clear,
            radius: controller.isExpanded ? 38 : 0,
            x: 0,
            y: controller.isExpanded ? 15 : 0
        )
        .overlay {
            if controller.isExpanded {
                RoundedRectangle(cornerRadius: EdgePanelLayout.cornerRadius)
                    .strokeBorder(PanelTheme.panelBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .trailing) {
            if !controller.isExpanded {
                Color.clear
                    .frame(width: EdgePanelLayout.collapsedHandleWidth, height: 86)
                    .overlay(alignment: .trailing) {
                        Capsule()
                            .fill(isCollapsedHandleHovered ? CollapsedHandleStyle.hoverFill : CollapsedHandleStyle.restingFill)
                            .frame(
                                width: isCollapsedHandleHovered ? CollapsedHandleStyle.hoverWidth : CollapsedHandleStyle.restingWidth,
                                height: isCollapsedHandleHovered ? CollapsedHandleStyle.hoverHeight : CollapsedHandleStyle.restingHeight
                            )
                            .padding(.trailing, CollapsedHandleStyle.trailingInset)
                    }
                    .contentShape(Rectangle())
                    .onHover { isCollapsedHandleHovered = $0 }
                    .animation(reduceMotion ? nil : .easeInOut(duration: CollapsedHandleStyle.animationDuration), value: isCollapsedHandleHovered)
            }
        }
        .onChange(of: controller.isExpanded) { _, expanded in if !expanded { selectedCountdownID = nil } }
        .onChange(of: controller.selectedCategory) { _, _ in selectedCountdownID = nil }
        .onHover { hovering in
            if hovering { controller.pointerEntered() } else { controller.pointerExited() }
        }
    }

    private var interactionRouter: some View {
        let eligibleIDs = Set(controller.todos.filter {
            $0.category == .today && !$0.isCompleted && $0.isVisible(at: controller.currentDate)
        }.map(\.id))
        return TaskInteractionRouter(rows: rowFrames, controls: controlFrames, clocks: clockFrames, eligible: eligibleIDs,
            onMove: { id, point in
                if let todo = controller.todos.first(where: { $0.id == id }) { updateDrag(todo: todo, point: point) }
            }, onFinish: { id in
                if let todo = controller.todos.first(where: { $0.id == id }) { finishDrag(todo: todo) }
                else { cancelDrag() }
            }, onCancel: { cancelDrag() }).allowsHitTesting(false)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(TodoCategory.allCases, id: \.self) { category in
                        CategoryTabButton(category: category,
                            isSelected: controller.selectedCategory == category) {
                            controller.selectCategory(category)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .overlay(alignment: .bottomLeading) {
                    Rectangle().fill(PanelTheme.underline)
                        .frame(width: 32, height: 1)
                        .offset(x: controller.selectedCategory == .today ? 24 : 100)
                        .animation(reduceMotion ? nil : .timingCurve(0.2, 0.75, 0.2, 1, duration: 0.28), value: controller.selectedCategory)
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 0)
                PinPanelButton(controller: controller)
                ArchiveTableButton(action: controller.openArchive)
            }
            .frame(height: 37)
            HStack {
                if controller.selectedCategory == .today {
                    HStack(spacing: 3) {
                        Text(controller.currentDate, format: .dateTime.month(.twoDigits).day(.twoDigits).locale(Locale(identifier: "zh_CN")))
                        Text(controller.currentDate, format: .dateTime.weekday(.wide).locale(Locale(identifier: "zh_CN")))
                    }
                } else {
                    Text("随记")
                }
                Spacer(minLength: 2)
                if let sync = controller.archiveSync { ArchiveSyncWarning(sync: sync) }
            }
            .font(.system(size: 11)).foregroundStyle(PanelTheme.date)
            .padding(.horizontal, 3)
            .frame(height: 29)
        }
    }

    private func row(_ todo: Todo) -> some View {
        let hasContent = !TodoEditingBehavior.shouldDeleteRow(text: todo.text)
        let isSaved = controller.todos.contains { $0.id == todo.id }
        let isHovered = hoveredRowID == todo.id
        return HStack(alignment: .top, spacing: 9) {
            Group {
                if !isSaved {
                    Color.clear.frame(width: 17, height: 21)
                        .overlay {
                            Text("+")
                                .font(.system(size: 15))
                                .foregroundStyle(todo.category == .today ? PanelTheme.todayPlaceholder :
                                (controller.focusedRowID == todo.id
                                    ? PanelTheme.inputPlusFocused : (isHovered ? PanelTheme.placeholder : PanelTheme.inputPlus)))
                        }
                } else if todo.category == .notes {
                    Color.clear.frame(width: 17, height: 21)
                        .overlay(alignment: .topLeading) {
                            Circle().fill(PanelTheme.bullet)
                                .frame(width: 5, height: 5).padding(.leading, 5).padding(.top, 7)
                        }
                } else {
                    Button { controller.toggleCompletion(todoID: todo.id) } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(todo.isCompleted ? PanelTheme.checkboxCompleted : .clear)
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(todo.isCompleted ? PanelTheme.checkboxCompleted : PanelTheme.checkbox, lineWidth: 1.4)
                            if todo.isCompleted {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                            }
                        }
                        .frame(width: 15, height: 15).contentShape(Rectangle())
                        .frame(width: 17, height: 21, alignment: .topLeading).padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: TaskControlFrames.self, value: [todo.id: [geometry.frame(in: .global)]])
                    })
                    .accessibilityLabel(todo.isCompleted ? "标记为未完成" : "标记为已完成")
                }
            }
            .padding(.top, 0)
            if isSaved, let link = SavedLinkNote(text: todo.text) {
                savedLinkContent(todo: todo, link: link, isHovered: isHovered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: TaskControlFrames.self, value: [todo.id: [geometry.frame(in: .global)]])
                    })
            } else {
                InlineTextEditor(text: todo.text, isCompleted: todo.isCompleted && todo.category == .today,
                    focusRequest: controller.focusedRowID == todo.id ? controller.focusRequest : 0,
                    focusAtEndRequest: controller.focusedRowID == todo.id ? controller.focusAtEndRequest : 0,
                    onBeginEditing: { controller.beginEditing(todoID: todo.id) },
                    onTextChange: { controller.updateEditingText(todoID: todo.id, text: $0) },
                    onSubmit: { controller.submitRow(todoID: todo.id) },
                    onEmptyDelete: { controller.deleteEmptyRow(todoID: todo.id) },
                    onEndEditing: { controller.endEditing(todoID: todo.id) },
                    emptyPlaceholder: !isSaved && todo.category == .today ? "写下一件待办…" : nil,
                    routesTaskCursor: isSaved && todo.category == .today && !todo.isCompleted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) {
                        if !isSaved && todo.category != .today && controller.focusedRowID != todo.id {
                            Text(todo.category == .today ? "写下一件待办…" : "写下一条随记…")
                                .font(.system(size: 13))
                                .foregroundStyle(isHovered ? PanelTheme.tab : PanelTheme.placeholder)
                                .allowsHitTesting(false)
                        }
                    }
            }
            if hasContent && todo.category == .notes {
                MoveActionButton(title: todo.category.moveTitle, isVisible: isHovered) {
                    controller.moveItem(todoID: todo.id)
                }
                .frame(width: 44, height: 21, alignment: .topTrailing)
                .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.16), value: isHovered)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
                .accessibilityLabel("移到\(todo.category.destination.title)")
            } else if hasContent && isSaved && todo.category == .today && !todo.isCompleted {
                CountdownButton(todoID: todo.id, isHovered: isHovered, manager: controller.countdowns,
                    selectedID: $selectedCountdownID, pointerEntered: controller.pointerEntered, pointerExited: controller.pointerExited,
                    menuVisibilityChanged: { controller.countdownMenuVisibilityChanged($0, for: todo.id) })
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TaskClockFrames.self, value: [todo.id: [geometry.frame(in: .global)]])
                })
            }
        }
        .padding(.vertical, isSaved ? 5 : 3)
        .frame(minHeight: isSaved ? 34 : 30, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(!isSaved
                    ? (controller.focusedRowID == todo.id ? PanelTheme.inputFocusedBackground : .clear)
                    : (isHovered ? PanelTheme.rowHover : .clear))
                // A shared hoveredRowID makes the logical state exclusive. Disable
                // interpolation only on saved-row backgrounds so a previous row
                // cannot remain visible while the next row appears.
                .transaction { transaction in
                    if isSaved { transaction.animation = nil }
                }
        }
        .animation(isSaved || reduceMotion ? nil : .easeInOut(duration: 0.16), value: isHovered)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: TaskRowFrames.self, value: [todo.id: geometry.frame(in: .global)])
        })
        .opacity(draggedID == todo.id ? 0.82 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredRowID = todo.id }
            else if hoveredRowID == todo.id { hoveredRowID = nil }
        }
    }

    private func updateDrag(todo: Todo, point: CGPoint) {
        if draggedID == nil {
            draggedID = todo.id
            dragOrder = controller.visibleRows.filter { row in
                row.category == .today && !row.isCompleted && controller.todos.contains { $0.id == row.id }
            }.map(\.id)
            controller.holdPanelOpen(true)
        }
        guard draggedID == todo.id,
              let from = dragOrder.firstIndex(of: todo.id),
              let target = dragOrder.first(where: { id in
                  guard id != todo.id, let frame = rowFrames[id] else { return false }
                  return point.y >= frame.minY && point.y < frame.maxY
              }),
              let to = dragOrder.firstIndex(of: target) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            dragOrder.remove(at: from); dragOrder.insert(todo.id, at: to)
        }
    }

    private func finishDrag(todo: Todo) {
        if draggedID == todo.id && !dragOrder.isEmpty { controller.reorderActiveToday(dragOrder) }
        cancelDrag()
    }

    private func cancelDrag() {
        draggedID = nil; dragOrder = []; controller.holdPanelOpen(false)
    }

    private func savedLinkContent(todo: Todo, link: SavedLinkNote, isHovered: Bool) -> some View {
        let titleIsHovered = hoveredLinkTitleID == todo.id
        let sourceImage = link.sourceIcon.flatMap { $0.pngData }.flatMap { NSImage(data: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 2) {
                Button { controller.openSavedLink(link) } label: {
                    HStack(alignment: .top, spacing: 5) {
                        if let sourceImage {
                            Image(nsImage: sourceImage)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: 14, height: 14)
                                .padding(.top, 2)
                                .accessibilityHidden(true)
                        }
                        Text(link.title)
                            .font(.system(size: 14, weight: .medium))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .underline(titleIsHovered)
                    }
                    .foregroundStyle(titleIsHovered ? PanelTheme.linkHover : PanelTheme.link)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .onHover { hoveredLinkTitleID = $0 ? todo.id : nil }
                .pointingHandOnHover()
                .accessibilityLabel("打开网页：\(link.title)，来源网站：\(link.domain)")
                .accessibilityHint("按 Return 打开网页；右键可删除链接")
                .help(sourceImage == nil ? "打开网页网页" : link.domain)

                Button { controller.deleteSavedLink(todoID: todo.id) } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PanelTheme.icon)
                .opacity(isHovered ? 1 : 0)
                .animation(.easeInOut(duration: 0.16), value: isHovered)
                .allowsHitTesting(isHovered)
                .accessibilityHidden(!isHovered)
                .accessibilityLabel("删除链接")
                .help("删除这条链接")
                .pointingHandOnHover()
            }

            if sourceImage == nil {
                Text(link.domain)
                    .font(.system(size: 11))
                    .foregroundStyle(PanelTheme.domain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(link.domain)
                    .accessibilityLabel("来源网站：\(link.domain)")
            }
        }
        .frame(minHeight: 28, alignment: .topLeading)
        .contextMenu {
            ForEach(SavedLinkMenuAction.allCases, id: \.self) { action in
                Button(action.rawValue) {
                    switch action {
                    case .open: controller.openSavedLink(link)
                    case .delete: controller.deleteSavedLink(todoID: todo.id)
                    }
                }
            }
        }
    }

}

struct MoveActionButton: NSViewRepresentable {
    let title: String
    let isVisible: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> MoveActionNativeButton {
        MoveActionNativeButton()
    }

    func updateNSView(_ button: MoveActionNativeButton, context: Context) {
        button.title = title
        button.actionHandler = action
        button.actionIsVisible = isVisible
        button.isEnabled = isVisible
    }
}

@MainActor
final class MoveActionNativeButton: NSButton {
    var actionHandler: (() -> Void)?
    var actionIsVisible = false {
        didSet {
            guard oldValue != actionIsVisible else { return }
            if let window { window.invalidateCursorRects(for: self) }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryPushIn)
        alignment = .right
        font = .systemFont(ofSize: 10)
        contentTintColor = PanelTheme.moveNS
        target = self
        action = #selector(activate)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if actionIsVisible {
            addCursorRect(visibleRect, cursor: .pointingHand)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if actionIsVisible { NSCursor.pointingHand.set() }
        else { super.cursorUpdate(with: event) }
    }

    @objc private func activate() {
        guard actionIsVisible else { return }
        actionHandler?()
    }
}

private struct ArchiveSyncWarning: View {
    @ObservedObject var sync: ArchiveSyncCoordinator

    private var warning: String? {
        switch sync.status {
        case "正在连接飞书…", "已保存到每日档案": nil
        case let status where status.contains("稍后重试"): "飞书同步稍后重试"
        case let status where status.contains("损坏"): "飞书同步异常"
        default: sync.status
        }
    }

    var body: some View {
        if let warning {
            Label(warning, systemImage: "exclamationmark.circle")
                .lineLimit(1).minimumScaleFactor(0.8)
                .foregroundStyle(Color.orange)
                .help(sync.status)
        }
    }
}

private struct PinPanelButton: View {
    @ObservedObject var controller: EdgePanelWindowController
    @State private var hovering = false
    var body: some View {
        Button { controller.togglePinned() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(controller.isPinned || hovering ? PanelTheme.iconHoverBackground : .clear)
                    .frame(width: 28, height: 28)
                Image(systemName: "pin")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(controller.isPinned || hovering ? PanelTheme.iconHover : PanelTheme.icon)
            }
            .frame(width: 30, height: EdgePanelLayout.archiveButtonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(controller.isPinned ? "取消固定" : "固定面板")
        .accessibilityLabel(controller.isPinned ? "取消固定面板" : "固定面板")
        .accessibilityValue(controller.isPinned ? "已固定" : "未固定")
        .accessibilityIdentifier("pin-panel-button")
    }
}

private struct ArchiveTableButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? PanelTheme.iconHoverBackground : .clear)
                    .frame(width: 31, height: 31)
                NotebookIcon()
                    .stroke(isHovering ? PanelTheme.iconHover : PanelTheme.icon, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 17, height: 17)
            }
            .frame(width: EdgePanelLayout.archiveButtonWidth, height: EdgePanelLayout.archiveButtonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: EdgePanelLayout.archiveButtonWidth, height: EdgePanelLayout.archiveButtonHeight)
        .onHover { isHovering = $0 }
        .help("打开飞书每日档案表格")
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel("打开每日档案表格")
        .accessibilityHint("直接打开飞书每日档案多维表格")
        .accessibilityIdentifier("archive-table-button")
    }
}

private struct NotebookIcon: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width / 20, y: rect.minY + y * rect.height / 20)
        }
        p.addRoundedRect(in: CGRect(x: rect.minX + 5.2 * rect.width / 20, y: rect.minY + 2.8 * rect.height / 20,
            width: 11.6 * rect.width / 20, height: 14.4 * rect.height / 20), cornerSize: CGSize(width: 1.3 * rect.width / 20, height: 1.3 * rect.height / 20))
        for (x1, y1, x2, y2) in [(12.8, 2.8, 12.8, 17.2), (12.8, 6.4, 16.8, 6.4), (12.8, 10.0, 16.8, 10.0), (12.8, 13.6, 16.8, 13.6), (3.5, 5.2, 6.3, 5.2), (3.5, 8.4, 6.3, 8.4), (3.5, 11.6, 6.3, 11.6), (3.5, 14.8, 6.3, 14.8)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            p.move(to: point(x1, y1)); p.addLine(to: point(x2, y2))
        }
        return p
    }
}

private struct CategoryTabButton: View {
    let category: TodoCategory
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(category.title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? PanelTheme.selectedTab : (isHovering ? PanelTheme.hoveredTab : PanelTheme.tab))
                .frame(width: 76, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(category.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TaskRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
