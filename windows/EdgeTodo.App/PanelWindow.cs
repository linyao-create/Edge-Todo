using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using ShapePath = System.Windows.Shapes.Path;
using System.Windows.Threading;

namespace EdgeTodo;

/**
 * 屏幕边缘悬浮待办与随记主面板窗口，负责收起/展开交互、毛玻璃联动、列表增量渲染及拖拽排序。
 */
public sealed class PanelWindow : Window
{
    private const double CardWidth = 320;
    private const double MaxCardHeight = 380;
    private const double ShadowLeft = 0;
    private const double ShadowTop = 26;
    private const double ShadowRight = 30;
    private const double ShadowBottom = 32;
    private const double CollapsedWidth = 14;
    private const double CollapsedHeight = 86;

    private readonly PanelHost _host;
    private readonly MonitorInfo _monitor;
    private readonly EdgeInteractionController _interaction;
    private readonly Grid _root;
    private readonly Border _card;
    private readonly Border _innerGlassBorder;
    private readonly DropShadowEffect _cardShadow;
    private readonly Grid _handle;
    private readonly Border _handleCapsule;
    private readonly DockPanel _body;
    private readonly StackPanel _header;
    private readonly StackPanel _rows;
    private readonly Border _completedDivider;
    private readonly ScrollViewer _scroll;
    private readonly TextBlock _date;
    private readonly TextBlock _error;
    private readonly TextBlock _archive;
    private readonly Border _underline;
    private readonly TranslateTransform _underlineTransform;
    private readonly Button _today;
    private readonly Button _notes;
    private readonly Button _pin;
    private readonly Border _pinPlate;
    private readonly ShapePath _pinIcon;
    private readonly Button _tableButton;
    private readonly TextBlock _notesCount;
    private readonly TextBlock _notesLimitHint;
    private readonly DispatcherTimer _headerTools;
    private readonly Dictionary<Guid, CompletionPlacement.Hold> _completionHolds = [];
    private readonly Dictionary<Guid, RowView> _views = [];
    private readonly AcrylicBackdrop _backdrop = new();

    private TodoCategory _category;
    private Guid _draftId = Guid.NewGuid();
    private Guid? _draftAfter;
    private Guid? _focusId;
    private string? _loadErrorText;
    private string? _actionErrorText;
    private bool _pinned;
    private bool _menuOpen;
    private bool _dragHeldOpen;
    private RowView? _draggingRow;
    private List<Guid> _dragOrder = [];
    internal Popup? OpenPopup;
    private IntPtr _previousForeground;
    private bool _rendering;
    private readonly bool _ownsHotkey;
    private IntPtr _hwnd;

    public string Device => _monitor.Device;
    internal CountdownManager Countdowns => _host.Countdowns;
    internal bool IsGlassMode => _pinned && AcrylicBackdrop.IsTransparencyEnabled();

    /**
     * 为指定显示器创建边缘待办面板窗口。
     * @param {PanelHost} host 面板宿主协调器
     * @param {MonitorInfo} monitor 目标显示器信息与 DPI
     * @param {bool} ownsHotkey 是否由该窗口注册全局快捷键
     */
    public PanelWindow(PanelHost host, MonitorInfo monitor, bool ownsHotkey)
    {
        _host = host;
        _monitor = monitor;
        _ownsHotkey = ownsHotkey;
        _category = host.Selection.Category;
        _pinned = host.Selection.IsPinned(monitor.Device);
        _interaction = new EdgeInteractionController(new WpfScheduler(Dispatcher));
        _interaction.SetPinned(_pinned);
        _interaction.StateChanged += state => Dispatcher.Invoke(() => ApplyState(state == EdgePanelState.Expanded));

        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        Topmost = true;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        FontFamily = new FontFamily("Microsoft YaHei UI");
        Title = "一角";

        _rows = new StackPanel { Background = Brushes.Transparent };
        _completedDivider = new Border
        {
            Height = 0.8,
            Background = Theme.PanelBorder,
            Margin = new Thickness(6, 6, 6, 6),
            SnapsToDevicePixels = true
        };
        _notesLimitHint = new TextBlock
        {
            Text = "随记已满 20 条，整理后可继续添加。",
            FontSize = 12,
            Foreground = Theme.Placeholder,
            Margin = new Thickness(32, 6, 6, 4)
        };

        _date = new TextBlock
        {
            FontSize = 11,
            Foreground = Theme.Date,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(9, 0, 9, 0)
        };
        _error = new TextBlock
        {
            FontSize = 12,
            Foreground = Brushes.IndianRed,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(9, 0, 9, 4)
        };
        _archive = new TextBlock
        {
            FontSize = 11.5,
            Foreground = Theme.Freeze(0xC4, 0x6B, 0x12),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(9, 0, 9, 4),
            Visibility = Visibility.Collapsed
        };

        _underlineTransform = new TranslateTransform(_category == TodoCategory.Today ? 22 : 98, 0);
        _underline = new Border
        {
            Width = 32,
            Height = 1.2,
            Background = Theme.Underline,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 2),
            RenderTransform = _underlineTransform,
            IsHitTestVisible = false
        };

        _today = CreateTab("今日待办", null, () => Select(TodoCategory.Today));
        _notesCount = new TextBlock
        {
            FontSize = 9.5,
            Foreground = Theme.Date,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(57, 1, 0, 0),
            IsHitTestVisible = false
        };
        _notes = CreateTab("随记", null, () => Select(TodoCategory.Notes));

        _pinIcon = Marks.Pin(Theme.Icon);
        _pin = CreateHeaderIconButton(_pinIcon, out _pinPlate, 28, 8, TogglePin, () => _pinned, "固定面板");
        _tableButton = CreateHeaderIconButton(Marks.Notebook(Theme.Icon), out _, 31, 10, OpenArchive, () => false, "打开飞书每日档案表格");

        _headerTools = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        _headerTools.Tick += (_, _) =>
        {
            _headerTools.Stop();
            ApplyHeaderTools(false, animate: true);
        };

        var tabs = new Grid { Height = 37, Background = Brushes.Transparent, Margin = new Thickness(6, 0, 6, 0) };
        tabs.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });
        tabs.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(76) });
        tabs.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        tabs.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        tabs.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_today, 0);
        Grid.SetColumn(_notes, 1);
        Grid.SetColumn(_notesCount, 1);
        Grid.SetColumnSpan(_notesCount, 2);
        Grid.SetColumn(_pin, 3);
        Grid.SetColumn(_tableButton, 4);
        tabs.Children.Add(_today);
        tabs.Children.Add(_notes);
        tabs.Children.Add(_notesCount);
        Grid.SetColumnSpan(_underline, 2);
        tabs.Children.Add(_underline);
        tabs.Children.Add(_pin);
        tabs.Children.Add(_tableButton);

        var dateRow = new Grid { Height = 29, Background = Brushes.Transparent };
        dateRow.Children.Add(_date);

        _header = new StackPanel { Background = Brushes.Transparent };
        _header.Children.Add(tabs);
        _header.Children.Add(dateRow);
        _header.MouseEnter += (_, _) =>
        {
            _headerTools.Stop();
            ApplyHeaderTools(true, animate: true);
        };
        _header.MouseLeave += (_, _) =>
        {
            if (!_header.IsMouseOver) _headerTools.Start();
        };
        ApplyHeaderTools(false, animate: false);

        DockPanel.SetDock(_header, Dock.Top);
        DockPanel.SetDock(_error, Dock.Top);
        DockPanel.SetDock(_archive, Dock.Top);

        _scroll = SlimScrollViewer.Create(_rows, CloseOpenPopups);
        _scroll.Padding = new Thickness(0, 0, 11, 2);

        _body = new DockPanel { Margin = new Thickness(11, 18, 5, 14), LastChildFill = true, Background = Brushes.Transparent };
        _body.Children.Add(_header);
        _body.Children.Add(_error);
        _body.Children.Add(_archive);
        _body.Children.Add(_scroll);

        _innerGlassBorder = new Border
        {
            CornerRadius = new CornerRadius(17),
            Margin = new Thickness(1),
            BorderBrush = Theme.GlassInnerHighlight,
            BorderThickness = new Thickness(0.5),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed
        };

        var cardHost = new Grid();
        cardHost.Children.Add(_innerGlassBorder);
        cardHost.Children.Add(_body);

        _cardShadow = new DropShadowEffect
        {
            BlurRadius = 18,
            ShadowDepth = 4,
            Direction = 270,
            Opacity = 0.10,
            RenderingBias = RenderingBias.Quality,
            Color = Color.FromRgb(0x2B, 0x28, 0x43)
        };

        _card = new Border
        {
            Width = CardWidth,
            CornerRadius = new CornerRadius(18),
            Background = Theme.Panel,
            BorderBrush = Theme.PanelBorder,
            BorderThickness = new Thickness(1),
            Margin = new Thickness(ShadowLeft, ShadowTop, ShadowRight, ShadowBottom),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            Effect = _cardShadow,
            Child = cardHost
        };
        _card.MouseEnter += (_, _) => _interaction.PointerEntered();
        _card.MouseLeave += (_, _) => CheckPointerExit();

        _handleCapsule = new Border
        {
            Width = 7,
            Height = 52,
            CornerRadius = new CornerRadius(3.5),
            Background = Theme.Handle,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center
        };
        _handle = new Grid
        {
            Width = CollapsedWidth,
            Height = CollapsedHeight,
            Background = Brushes.Transparent,
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Center,
            Cursor = Cursors.Hand
        };
        _handle.Children.Add(_handleCapsule);
        _handle.MouseEnter += (_, _) =>
        {
            _handleCapsule.Background = Theme.HandleHover;
            _interaction.PointerEntered();
        };
        _handle.MouseLeave += (_, _) =>
        {
            _handleCapsule.Background = Theme.Handle;
            if (_interaction.State == EdgePanelState.Collapsed) _interaction.PointerExited();
        };
        _handle.MouseLeftButtonDown += (_, _) =>
        {
            if (_interaction.State == EdgePanelState.Collapsed) _interaction.Reveal();
        };

        _root = new Grid { Background = Brushes.Transparent };
        _root.Children.Add(_card);
        _root.Children.Add(_handle);
        Content = _root;

        PreviewKeyDown += OnPreviewKey;
        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            var style = Native.GetWindowLong(_hwnd, Native.GwlExStyle);
            Native.SetWindowLong(_hwnd, Native.GwlExStyle, style | Native.WsExToolWindow);
            if (_ownsHotkey)
            {
                HwndSource.FromHwnd(_hwnd)?.AddHook(HotkeyHook);
                Native.RegisterHotKey(_hwnd, 1, Native.ModControl | Native.ModShift, 0x4F);
            }
            ApplyState(_pinned);
            if (_pinned) _interaction.Reveal();
        };
        Closed += (_, _) =>
        {
            _backdrop.Close();
            if (_ownsHotkey && _hwnd != IntPtr.Zero) Native.UnregisterHotKey(_hwnd, 1);
        };
        ApplyState(false);
    }

    /**
     * 展开面板；如果指定了随记标识则切换到随记标签并滚动到该条目。
     * @param {Guid?} noteId 要定位的随记条目标识
     */
    public void Reveal(Guid? noteId)
    {
        if (noteId is Guid id)
        {
            Select(TodoCategory.Notes);
            _focusId = null;
        }
        _interaction.Reveal();
        if (noteId is Guid target)
        {
            Dispatcher.BeginInvoke(() =>
            {
                if (_views.TryGetValue(target, out var row)) row.BringIntoView();
            });
        }
    }

    /**
     * 每秒时钟推进：刷新面板上运行中的倒计时与日期跨天更新。
     */
    public void Tick()
    {
        if (_interaction.State != EdgePanelState.Expanded) return;
        foreach (var row in _views.Values) row.RefreshClock();
        if (DateTime.UtcNow.Second % 30 == 0) UpdateDate();
    }

    /**
     * 重新同步并刷新当前面板数据。
     */
    public void Reload() => Render(force: false);

    internal void SetArchiveWarning(string? warning)
    {
        _archive.Text = warning ?? "";
        _archive.Visibility = string.IsNullOrEmpty(warning) ? Visibility.Collapsed : Visibility.Visible;
    }

    internal Rect GetCardBoundsInDevicePixels()
    {
        if (!IsLoaded || _card.Visibility != Visibility.Visible || _card.ActualWidth <= 0 || _card.ActualHeight <= 0)
            return Rect.Empty;
        var origin = _card.PointToScreen(new Point(0, 0));
        var far = _card.PointToScreen(new Point(_card.ActualWidth, _card.ActualHeight));
        return new Rect(origin, far);
    }

    private void ApplyState(bool expanded)
    {
        if (expanded && _card.Visibility == Visibility.Visible)
        {
            Place(true);
            return;
        }
        if (!expanded)
        {
            CloseOpenPopups();
            CancelActiveDrag();
            ClearTextSelection();
            Keyboard.ClearFocus();
            if (_previousForeground != IntPtr.Zero && _previousForeground != _hwnd)
                Native.SetForegroundWindow(_previousForeground);
            _previousForeground = IntPtr.Zero;
            _draftId = Guid.NewGuid();
            _draftAfter = null;
            _focusId = null;
            _menuOpen = false;
            _dragHeldOpen = false;
            _interaction.SetHeldOpen(false);
            _backdrop.HideBackdrop();
        }

        // 展开态下让根容器背景为 null，保证卡片外围 36px 空气阴影区不拦截鼠标事件
        _root.Background = expanded ? null : Brushes.Transparent;
        _card.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        _handle.Visibility = expanded ? Visibility.Collapsed : Visibility.Visible;
        if (expanded) Render(force: true);
        Place(expanded);
    }

    private void Place(bool expanded)
    {
        var scale = _monitor.Dpi / 96.0;
        if (scale <= 0) scale = 1;
        var workHeight = _monitor.Height / scale;

        if (!expanded)
        {
            Width = CollapsedWidth;
            Height = CollapsedHeight;
            _backdrop.HideBackdrop();
            if (_hwnd == IntPtr.Zero) return;
            var pxW = (int)Math.Round(CollapsedWidth * scale);
            var pxH = (int)Math.Round(CollapsedHeight * scale);
            var pxY = _monitor.Top + (_monitor.Height - pxH) / 2;
            Native.SetWindowPos(_hwnd, Native.Topmost, _monitor.Left, pxY, pxW, pxH, Native.SwpNoActivate);
            return;
        }

        var cardHeight = Math.Min(MaxCardHeight, Math.Max(120, workHeight - 32));
        _card.Height = cardHeight;
        var totalDipW = CardWidth + ShadowLeft + ShadowRight;
        var totalDipH = cardHeight + ShadowTop + ShadowBottom;
        Width = totalDipW;
        Height = totalDipH;

        if (_hwnd == IntPtr.Zero) return;
        var totalPxW = (int)Math.Round(totalDipW * scale);
        var totalPxH = (int)Math.Round(totalDipH * scale);
        var cardPxW = (int)Math.Round(CardWidth * scale);
        var cardPxH = (int)Math.Round(cardHeight * scale);
        var cardPxY = _monitor.Top + (_monitor.Height - cardPxH) / 2;
        var winPxY = cardPxY - (int)Math.Round(ShadowTop * scale);

        Native.SetWindowPos(_hwnd, Native.Topmost, _monitor.Left, winPxY, totalPxW, totalPxH, Native.SwpNoActivate);

        if (IsGlassMode)
            _backdrop.SyncBelow(_hwnd, _monitor.Left + (int)Math.Round(ShadowLeft * scale), cardPxY, cardPxW, cardPxH, scale);
        else
            _backdrop.HideBackdrop();
    }

    private void Render(bool force)
    {
        if (_rendering) return;
        _rendering = true;
        try
        {
            RenderCore(force);
        }
        finally
        {
            _rendering = false;
        }
    }

    private void RenderCore(bool force)
    {
        var rows = VisibleRows();
        UpdateChrome();

        var editing = _views.Values.Any(view => view.IsComposing || view.KeepsText);
        if (!force && editing)
        {
            foreach (var row in rows)
                if (_views.TryGetValue(row.Id, out var view)) view.Sync(row, view.KeepsText);
            return;
        }

        // 增量同步行控件集合：保留已有实例、移除已删除项、按序重新排列，避免滚动位置归零或悬停闪烁
        var desiredIds = rows.Select(r => r.Id).ToHashSet();
        var staleIds = _views.Keys.Where(id => !desiredIds.Contains(id)).ToList();
        foreach (var staleId in staleIds)
        {
            if (_views.TryGetValue(staleId, out var staleView))
            {
                staleView.CloseClockPopup();
                _rows.Children.Remove(staleView);
                _views.Remove(staleId);
            }
        }

        var orderedChildren = new List<UIElement>(rows.Count + 2);
        var dividerInserted = false;
        var limitReached = _category == TodoCategory.Notes && NotesCount() >= TodoStore.NotesLimit;

        foreach (var row in rows)
        {
            if (_category == TodoCategory.Today && row.Completed && !dividerInserted)
            {
                dividerInserted = true;
                orderedChildren.Add(_completedDivider);
            }

            if (!row.Saved && limitReached)
            {
                orderedChildren.Add(_notesLimitHint);
                continue;
            }

            if (_views.TryGetValue(row.Id, out var existing) && (existing.Model.Link is not null) == (row.Link is not null))
            {
                existing.Sync(row, existing.KeepsText);
                orderedChildren.Add(existing);
            }
            else
            {
                if (_views.TryGetValue(row.Id, out var oldView))
                {
                    oldView.CloseClockPopup();
                    _rows.Children.Remove(oldView);
                    _views.Remove(row.Id);
                }
                var created = new RowView(this, row);
                _views[row.Id] = created;
                orderedChildren.Add(created);
            }
        }

        var structureMatches = _rows.Children.Count == orderedChildren.Count
            && orderedChildren.Select((el, i) => ReferenceEquals(_rows.Children[i], el)).All(match => match);

        if (!structureMatches)
        {
            // 先从不在新列表中的位置安全移除，再按需调整顺序，尽量不打断正在聚焦的子控件
            for (var i = _rows.Children.Count - 1; i >= 0; i--)
            {
                if (!orderedChildren.Contains(_rows.Children[i]))
                    _rows.Children.RemoveAt(i);
            }

            for (var targetIdx = 0; targetIdx < orderedChildren.Count; targetIdx++)
            {
                var desired = orderedChildren[targetIdx];
                if (targetIdx < _rows.Children.Count && ReferenceEquals(_rows.Children[targetIdx], desired))
                    continue;
                _rows.Children.Remove(desired);
                _rows.Children.Insert(targetIdx, desired);
            }
        }

        if (_focusId is Guid focus && _views.TryGetValue(focus, out var focused))
        {
            _focusId = null;
            focused.FocusAtEnd();
            focused.BringIntoView();
        }
    }

    private int NotesCount()
    {
        try { return TodoStore.NotesCount(_host.Store.Load()); }
        catch { return 0; }
    }

    private List<TodoRow> VisibleRows()
    {
        List<Todo> stored;
        var loadSucceeded = false;
        try
        {
            stored = _host.Store.Load().ToList();
            _loadErrorText = null;
            loadSucceeded = true;
        }
        catch (Exception ex)
        {
            stored = [];
            _loadErrorText = "读取失败：" + ex.Message;
        }

        var visible = stored.Where(todo => todo.Category == _category && todo.IsVisible(DateTime.UtcNow)).ToList();
        if (_category == TodoCategory.Today)
            visible = visible.Where(todo => !todo.IsCompleted).Concat(visible.Where(todo => todo.IsCompleted)).ToList();

        var models = visible.Select(todo => TodoRow.From(todo, saved: true)).ToList();

        if (_draggingRow is not null && _dragOrder.Count > 0 && _category == TodoCategory.Today)
        {
            var byId = models.ToDictionary(m => m.Id);
            var activeSet = _dragOrder.ToHashSet();
            var reordered = _dragOrder.Where(byId.ContainsKey).Select(id => byId[id]).ToList();
            var remaining = models.Where(m => !activeSet.Contains(m.Id)).ToList();
            models = reordered.Concat(remaining).ToList();
        }

        if (!models.Any(row => row.Id == _draftId))
        {
            var draft = TodoRow.Draft(_draftId, _category);
            if (_category == TodoCategory.Today)
                models.Insert(models.FindIndex(row => row.Completed) is var index and >= 0 ? index : models.Count, draft);
            else if (_draftAfter is Guid after && models.FindIndex(row => row.Id == after) is var afterIndex and >= 0)
                models.Insert(afterIndex + 1, draft);
            else
                models.Add(draft);
        }

        if (_category == TodoCategory.Today && _completionHolds.Count > 0)
        {
            models = CompletionPlacement.Apply(models, row => row.Id, _completionHolds);
            foreach (var model in models)
                if (_completionHolds.TryGetValue(model.Id, out var hold)) model.Completed = hold.WasCompleted;
        }

        if (loadSucceeded)
            _host.Countdowns.RetainActive();
        return models;
    }

    private void UpdateChrome()
    {
        _today.Foreground = _category == TodoCategory.Today ? Theme.SelectedTab : (_today.IsMouseOver ? Theme.HoveredTab : Theme.Tab);
        _notes.Foreground = _category == TodoCategory.Notes ? Theme.SelectedTab : (_notes.IsMouseOver ? Theme.HoveredTab : Theme.Tab);
        _today.FontWeight = _category == TodoCategory.Today ? FontWeights.SemiBold : FontWeights.Normal;
        _notes.FontWeight = _category == TodoCategory.Notes ? FontWeights.SemiBold : FontWeights.Normal;

        var targetX = _category == TodoCategory.Today ? 22.0 : 98.0;
        if (Math.Abs(_underlineTransform.X - targetX) > 0.5)
        {
            var slide = new DoubleAnimation(targetX, TimeSpan.FromMilliseconds(260))
            {
                EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut }
            };
            _underlineTransform.BeginAnimation(TranslateTransform.XProperty, slide);
        }

        UpdatePinVisual();
        ApplyPinnedMaterial();

        try
        {
            _notesCount.Text = $"{TodoStore.NotesCount(_host.Store.Load())}/{TodoStore.NotesLimit}";
        }
        catch (Exception)
        {
            _notesCount.Text = "";
        }

        var visibleError = _actionErrorText ?? _loadErrorText;
        _error.Text = visibleError ?? "";
        _error.Visibility = visibleError is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateDate();
    }

    private void UpdatePinVisual()
    {
        var active = _pinned || _pin.IsMouseOver;
        _pinPlate.Background = active ? Theme.IconPlate : Brushes.Transparent;
        _pinIcon.Stroke = active ? Theme.IconHover : Theme.Icon;
        _pin.ToolTip = _pinned ? "取消固定" : "固定面板";
        if (!_headerTools.IsEnabled)
            ApplyHeaderTools(_header.IsMouseOver, animate: false);
    }

    private void UpdateDate()
    {
        var local = DateTime.Now;
        _date.Text = _category == TodoCategory.Today
            ? $"{local:MM'/'dd} {System.Globalization.CultureInfo.GetCultureInfo("zh-CN").DateTimeFormat.GetDayName(local.DayOfWeek)}"
            : "随记：上限 20 条";
    }

    private void Select(TodoCategory category)
    {
        if (category == _category) return;
        CloseOpenPopups();
        CancelActiveDrag();
        _actionErrorText = null;
        _draftId = Guid.NewGuid();
        _draftAfter = null;
        _category = category;
        _host.Selection.Select(category);
        Render(force: true);
    }

    private void TogglePin()
    {
        _pinned = !_pinned;
        _host.Selection.SetPinned(_pinned, _monitor.Device);
        _interaction.SetPinned(_pinned);
        UpdateChrome();
        Place(_interaction.State == EdgePanelState.Expanded);
        if (!_pinned && !CursorInsideCard()) _interaction.PointerExited();
    }

    private void OpenArchive()
    {
        var directory = Path.GetDirectoryName(_host.Store.FilePath) ?? "";
        if (!ArchiveSettings.TryLoad(directory, out var settings, out var loadError))
        {
            MessageBox.Show(loadError ?? "飞书配置损坏，请让 AI 重新检查配置。", "飞书配置异常", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (settings is not null && ArchiveLinks.TryTableUrl(settings.Table, settings.Document, out var url, out _))
        {
            Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
            return;
        }
        MessageBox.Show("请告诉你的 AI：帮我连接一角和我的飞书。", "连接飞书", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    internal void OnText(TodoRow row, string text)
    {
        try
        {
            var saved = _host.Store.Load().Any(todo => todo.Id == row.Id);
            if (!saved && TodoEditing.ShouldDeleteRow(text)) return;
            _actionErrorText = null;
            _host.Store.SaveDraft(row.Id, text, _category, allowInsert: !saved, insertAfter: _draftAfter);
            _host.Broadcast();
        }
        catch (TodoStoreException ex) when (ex.Message.Contains("不存在") || ex.Message.Contains("已满"))
        {
            _actionErrorText = ex.Message.Contains("已满") ? ex.Message : "保存失败：" + ex.Message;
            Render(force: true);
        }
        catch (TodoStoreException)
        {
        }
        catch (Exception ex)
        {
            _actionErrorText = "保存失败：" + ex.Message;
            Render(force: true);
        }
    }

    internal void OnSubmit(TodoRow row)
    {
        if (TodoEditing.ShouldDeleteRow(row.Text)) return;
        _actionErrorText = null;
        var origin = row.Id;
        _draftId = Guid.NewGuid();
        _draftAfter = _category == TodoCategory.Notes ? origin : null;
        _focusId = _draftId;
        Render(force: true);
    }

    internal void OnEmptyDelete(TodoRow row)
    {
        try
        {
            _actionErrorText = null;
            var rows = VisibleRows();
            var index = rows.FindIndex(item => item.Id == row.Id);
            var previous = index > 0 ? rows[index - 1].Id : _draftId;
            if (row.Saved) _host.Store.Delete(row.Id);
            if (_draftId == row.Id) { _draftId = Guid.NewGuid(); _draftAfter = null; }
            if (_draftAfter == row.Id) _draftAfter = previous;
            _focusId = previous;
            _host.Broadcast();
        }
        catch (TodoStoreException ex)
        {
            _actionErrorText = "删除失败：" + ex.Message;
            Render(force: true);
        }
    }

    internal void OnToggle(TodoRow row)
    {
        try
        {
            _actionErrorText = null;
            var index = VisibleRows().FindIndex(item => item.Id == row.Id);
            if (index >= 0) _completionHolds[row.Id] = new CompletionPlacement.Hold(index, row.Completed);
            _host.Store.UpdateCompletion(row.Id, !row.Completed);
            if (!row.Completed && _draftId == row.Id) { _draftId = Guid.NewGuid(); _draftAfter = null; }
            _host.Broadcast();
            var id = row.Id;
            var clock = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(180) };
            clock.Tick += (_, _) =>
            {
                clock.Stop();
                _completionHolds.Remove(id);
                Render(force: false);
            };
            clock.Start();
        }
        catch (TodoStoreException ex)
        {
            _completionHolds.Remove(row.Id);
            _actionErrorText = "更新状态失败：" + ex.Message;
            Render(force: true);
        }
    }

    /**
     * 将待办或随记移动到目标分类，遇到随记已满等异常时保留原条目并展示错误提示而不闪退。
     * @param {TodoRow} row 待移动的行模型
     */
    internal void OnMove(TodoRow row)
    {
        try
        {
            _actionErrorText = null;
            _host.Store.Move(row.Id, row.Category.Destination());
            if (_draftId == row.Id) { _draftId = Guid.NewGuid(); _draftAfter = null; }
            _focusId = _draftId;
            _host.Broadcast();
        }
        catch (TodoStoreException ex)
        {
            _actionErrorText = ex.Message.Contains("已满") ? ex.Message : "移动失败：" + ex.Message;
            Render(force: true);
            CaptureToast.Show(_actionErrorText, error: true);
        }
    }

    internal void OnDeleteLink(TodoRow row)
    {
        try
        {
            _actionErrorText = null;
            _host.Store.Delete(row.Id);
            if (_draftAfter == row.Id) _draftAfter = null;
            _host.Broadcast();
        }
        catch (TodoStoreException ex)
        {
            _actionErrorText = "删除失败：" + ex.Message;
            Render(force: true);
        }
    }

    internal void OpenLink(Uri url)
    {
        var edge = EdgeExecutable();
        if (edge is not null) Process.Start(new ProcessStartInfo(edge, "\"" + url.AbsoluteUri + "\"") { UseShellExecute = false });
        else Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
    }

    internal void BeginRowDrag(RowView row)
    {
        _draggingRow = row;
        _dragOrder = VisibleRows()
            .Where(r => r.Saved && r.Category == TodoCategory.Today && !r.Completed)
            .Select(r => r.Id)
            .ToList();
        _dragHeldOpen = true;
        _interaction.SetHeldOpen(true);
    }

    internal void UpdateRowDrag(Point pointInWindow)
    {
        if (_draggingRow is null || _dragOrder.Count < 2) return;
        var from = _dragOrder.IndexOf(_draggingRow.Model.Id);
        if (from < 0) return;

        var pointInRows = TranslatePoint(pointInWindow, _rows);
        Guid? targetId = null;
        foreach (var id in _dragOrder)
        {
            if (id == _draggingRow.Model.Id || !_views.TryGetValue(id, out var candidate)) continue;
            var topLeft = candidate.TranslatePoint(new Point(0, 0), _rows);
            if (pointInRows.Y >= topLeft.Y && pointInRows.Y < topLeft.Y + candidate.ActualHeight)
            {
                targetId = id;
                break;
            }
        }

        if (targetId is not Guid target) return;
        var to = _dragOrder.IndexOf(target);
        if (to < 0 || to == from) return;

        _dragOrder.RemoveAt(from);
        _dragOrder.Insert(to, _draggingRow.Model.Id);
        Render(force: false);
    }

    internal void EndRowDrag(bool commit)
    {
        var order = _dragOrder.ToList();
        _draggingRow = null;
        _dragOrder.Clear();
        _dragHeldOpen = false;
        _interaction.SetHeldOpen(_menuOpen);

        if (commit && order.Count > 1)
        {
            try
            {
                _host.Store.ReorderActiveToday(order);
                _host.Broadcast();
            }
            catch (TodoStoreException ex)
            {
                _actionErrorText = "保存顺序失败：" + ex.Message;
                Render(force: true);
            }
        }
        else
        {
            Render(force: false);
        }

        if (!_pinned && !_menuOpen && !CursorInsideCard())
            _interaction.PointerExited();
    }

    private void CancelActiveDrag()
    {
        if (_draggingRow is null) return;
        _draggingRow.CancelDrag();
        EndRowDrag(commit: false);
    }

    private static string? EdgeExecutable()
    {
        foreach (var root in new[] { Environment.SpecialFolder.ProgramFilesX86, Environment.SpecialFolder.ProgramFiles })
        {
            var path = Path.Combine(Environment.GetFolderPath(root), "Microsoft", "Edge", "Application", "msedge.exe");
            if (File.Exists(path)) return path;
        }
        return null;
    }

    private void ApplyHeaderTools(bool revealed, bool animate)
    {
        var pinOpacity = revealed ? 1.0 : (_pinned ? 0.65 : 0.0);
        var tableOpacity = revealed ? 1.0 : 0.0;
        _pin.IsHitTestVisible = revealed || _pinned;
        _tableButton.IsHitTestVisible = revealed;

        SetHeaderButtonOpacity(_pin, pinOpacity, animate);
        SetHeaderButtonOpacity(_tableButton, tableOpacity, animate);
    }

    private static void SetHeaderButtonOpacity(UIElement target, double to, bool animate)
    {
        if (!animate)
        {
            target.BeginAnimation(OpacityProperty, null);
            target.Opacity = to;
            return;
        }
        var anim = new DoubleAnimation(to, TimeSpan.FromMilliseconds(120))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }
        };
        target.BeginAnimation(OpacityProperty, anim);
    }

    private void ApplyPinnedMaterial()
    {
        if (_pinned && _card.Visibility == Visibility.Visible)
        {
            if (AcrylicBackdrop.IsTransparencyEnabled())
            {
                _card.Background = Theme.GlassOverlay;
                _card.BorderBrush = Theme.GlassBorder;
                _card.BorderThickness = new Thickness(0.5);
                _innerGlassBorder.Visibility = Visibility.Visible;
                // 固定毛玻璃态由 DWM 原生提供柔和圆角阴影，关闭 WPF 离屏阴影彻底杜绝直角矩形边痕
                _card.Effect = null;
            }
            else
            {
                _card.Background = Theme.Panel;
                _card.BorderBrush = Theme.Freeze(0x58, 0x56, 0x6F, 28);
                _card.BorderThickness = new Thickness(1);
                _innerGlassBorder.Visibility = Visibility.Collapsed;
                _cardShadow.BlurRadius = 16;
                _cardShadow.ShadowDepth = 4;
                _cardShadow.Opacity = 0.08;
                _card.Effect = _cardShadow;
            }
        }
        else
        {
            _card.Background = Theme.Panel;
            _card.BorderBrush = Theme.PanelBorder;
            _card.BorderThickness = new Thickness(1);
            _innerGlassBorder.Visibility = Visibility.Collapsed;
            _cardShadow.BlurRadius = 18;
            _cardShadow.ShadowDepth = 4;
            _cardShadow.Opacity = 0.10;
            _card.Effect = _cardShadow;
        }
    }

    internal void Hold(bool held)
    {
        _menuOpen = held;
        _interaction.SetHeldOpen(held || _dragHeldOpen);
        if (!held && !_dragHeldOpen && !CursorInsideCard()) _interaction.PointerExited();
    }

    internal void ActivateForTyping()
    {
        var current = Native.GetForegroundWindow();
        if (current != IntPtr.Zero && current != _hwnd) _previousForeground = current;
        Activate();
    }

    private void CloseOpenPopups()
    {
        if (OpenPopup is not null && OpenPopup.IsOpen)
            OpenPopup.IsOpen = false;
    }

    private void ClearTextSelection()
    {
        foreach (var view in _views.Values) view.ClearSelection();
    }

    private void CheckPointerExit()
    {
        if (_menuOpen || _dragHeldOpen || CursorInsideCard()) return;
        ClearTextSelection();
        _interaction.PointerExited();
    }

    private bool CursorInsideCard()
    {
        if (!IsLoaded || _card.Visibility != Visibility.Visible || _card.ActualWidth <= 0 || _card.ActualHeight <= 0 || !Native.GetCursorPos(out var point))
            return false;
        var origin = _card.PointToScreen(new Point(0, 0));
        var far = _card.PointToScreen(new Point(_card.ActualWidth, _card.ActualHeight));
        return point.X >= origin.X && point.X < far.X && point.Y >= origin.Y && point.Y < far.Y;
    }

    private void OnPreviewKey(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            if (_draggingRow is not null)
            {
                CancelActiveDrag();
                e.Handled = true;
                return;
            }
            if (OpenPopup is not null && OpenPopup.IsOpen)
            {
                OpenPopup.IsOpen = false;
                e.Handled = true;
                return;
            }
            if (!_pinned && _interaction.State == EdgePanelState.Expanded)
            {
                _interaction.CancelAll();
                e.Handled = true;
            }
        }
    }

    private IntPtr HotkeyHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WmHotkey)
        {
            _host.Reveal(null);
            handled = true;
        }
        return IntPtr.Zero;
    }

    private static Button CreateTab(string title, UIElement? badge, Action action)
    {
        var label = new TextBlock
        {
            Text = title,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };
        var content = new Grid { ClipToBounds = false };
        content.Children.Add(label);
        if (badge is not null) content.Children.Add(badge);

        var button = new Button
        {
            Content = content,
            Width = 76,
            Height = 26,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            FontSize = 12.5,
            Cursor = Cursors.Hand,
            Focusable = false,
            FocusVisualStyle = null,
            OverridesDefaultStyle = true,
            Padding = new Thickness(0),
            ClipToBounds = false
        };
        var template = new ControlTemplate(typeof(Button));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Stretch);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Stretch);
        template.VisualTree = presenter;
        button.Template = template;
        button.Click += (_, _) => action();
        button.MouseEnter += (_, _) =>
        {
            if (button.FontWeight != FontWeights.SemiBold) button.Foreground = Theme.HoveredTab;
        };
        button.MouseLeave += (_, _) =>
        {
            if (button.FontWeight != FontWeights.SemiBold) button.Foreground = Theme.Tab;
        };
        return button;
    }

    private static Button CreateHeaderIconButton(ShapePath mark, out Border plate, double plateSize, double cornerRadius, Action action, Func<bool> isActive, string tooltip)
    {
        var localPlate = new Border
        {
            Width = plateSize,
            Height = plateSize,
            CornerRadius = new CornerRadius(cornerRadius),
            Background = Brushes.Transparent,
            Child = mark
        };
        plate = localPlate;
        var button = new Button
        {
            Content = localPlate,
            Width = 34,
            Height = 32,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand,
            Focusable = false,
            FocusVisualStyle = null,
            OverridesDefaultStyle = true,
            ToolTip = tooltip
        };
        var template = new ControlTemplate(typeof(Button));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        template.VisualTree = presenter;
        button.Template = template;
        button.Click += (_, _) => action();
        button.MouseEnter += (_, _) =>
        {
            localPlate.Background = Theme.IconPlate;
            mark.Stroke = Theme.IconHover;
        };
        button.MouseLeave += (_, _) =>
        {
            var active = isActive();
            localPlate.Background = active ? Theme.IconPlate : Brushes.Transparent;
            mark.Stroke = active ? Theme.IconHover : Theme.Icon;
        };
        return button;
    }
}

/**
 * 中文输入法组合状态检测辅助类，避免在拼音选词未提交时误触发提交或字符拦截。
 */
internal static class Ime
{
    public static bool IsComposing(Visual visual)
    {
        if (PresentationSource.FromVisual(visual) is not HwndSource source) return false;
        var context = ImmGetContext(source.Handle);
        if (context == IntPtr.Zero) return false;
        try
        {
            return ImmGetCompositionString(context, 0x0008, IntPtr.Zero, 0) > 0;
        }
        finally
        {
            ImmReleaseContext(source.Handle, context);
        }
    }

    [System.Runtime.InteropServices.DllImport("imm32.dll")]
    private static extern IntPtr ImmGetContext(IntPtr hwnd);

    [System.Runtime.InteropServices.DllImport("imm32.dll")]
    private static extern bool ImmReleaseContext(IntPtr hwnd, IntPtr context);

    [System.Runtime.InteropServices.DllImport("imm32.dll")]
    private static extern int ImmGetCompositionString(IntPtr context, int index, IntPtr buffer, int length);
}

/**
 * 基于 WPF Dispatcher 的延迟任务调度器。
 */
internal sealed class WpfScheduler(Dispatcher dispatcher) : IEdgeScheduler
{
    public IDisposable Schedule(TimeSpan delay, Action action)
    {
        var source = new CancellationTokenSource();
        _ = Run(delay, action, source.Token);
        return source;
    }

    private async Task Run(TimeSpan delay, Action action, CancellationToken token)
    {
        try
        {
            await Task.Delay(delay, token);
            await dispatcher.InvokeAsync(action);
        }
        catch (TaskCanceledException)
        {
        }
    }
}
