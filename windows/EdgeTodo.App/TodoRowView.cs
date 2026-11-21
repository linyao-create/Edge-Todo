using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace EdgeTodo;

/**
 * 单条待办或随记的数据视图模型。
 */
public sealed class TodoRow
{
    public required Guid Id { get; init; }
    public required string Text { get; set; }
    public required TodoCategory Category { get; init; }
    public bool Completed { get; set; }
    public bool Saved { get; init; }
    public SavedLinkNote? Link { get; init; }

    /**
     * 从存储实体构建列表行数据模型。
     * @param {Todo} todo 存储的待办实体
     * @param {bool} saved 是否已持久化
     * @returns {TodoRow} 行数据模型
     */
    public static TodoRow From(Todo todo, bool saved) => new()
    {
        Id = todo.Id,
        Text = todo.Text,
        Category = todo.Category,
        Completed = todo.IsCompleted,
        Saved = saved,
        Link = saved ? SavedLinkNote.Parse(todo.Text) : null
    };

    /**
     * 创建未保存的空草稿行模型。
     * @param {Guid} id 草稿唯一标识
     * @param {TodoCategory} category 所属分类
     * @returns {TodoRow} 草稿行数据模型
     */
    public static TodoRow Draft(Guid id, TodoCategory category) => new()
    {
        Id = id,
        Text = "",
        Category = category,
        Saved = false
    };
}

/**
 * 单行待办或随记控件：负责行内悬停高亮、整行透明命中、链接标题编辑、复选框动画、倒计时弹窗触发及拖拽排序。
 */
public sealed class RowView : Grid
{
    private readonly PanelWindow _window;
    private readonly Border _surface;
    private readonly Grid _dock = new() { Background = Brushes.Transparent };
    private TodoRow _row;
    private readonly Border _marker;
    private TextBlock? _plusMark;
    private ScaleTransform? _checkboxScale;
    private Border? _checkboxBox;
    private Path? _checkmarkPath;
    private readonly TextBlock? _placeholder;
    private TextBox? _linkTitle;
    private TextBlock? _linkDisplay;
    private TextBlock? _linkDomain;
    private string _titleBeforeEdit = "";
    private Button? _trashButton;
    private Border? _moveButton;
    private Button? _clockButton;
    private TextBlock? _clockLabel;
    private Path? _clockMark;
    private Border? _clockPlate;
    private Popup? _clockPopup;
    private FrameworkElement? _rightActionHost;
    private bool _silent;
    private bool _isHovered;
    private bool _isDragging;
    private Point _dragStartInWindow;
    private bool _dragPending;

    public TextBox? Editor { get; }
    public TodoRow Model => _row;
    public bool KeepsText => Editor?.IsKeyboardFocused == true || _linkTitle?.IsKeyboardFocused == true;
    public bool IsComposing => (Editor is not null && Ime.IsComposing(Editor)) || (_linkTitle is not null && Ime.IsComposing(_linkTitle));

    /**
     * 初始化单行视图并绑定编辑、悬停、操作按钮与拖拽交互。
     * @param {PanelWindow} window 所属主面板窗口
     * @param {TodoRow} row 绑定的行数据模型
     */
    public RowView(PanelWindow window, TodoRow row)
    {
        _window = window;
        _row = row;

        // 整行设置透明背景，确保鼠标在文字与右侧按钮之间的空白区域移动时不会穿透触发 MouseLeave
        Background = Brushes.Transparent;
        Margin = new Thickness(0, 1, 0, 1);

        _surface = new Border
        {
            CornerRadius = new CornerRadius(7),
            Background = Brushes.Transparent,
            Padding = new Thickness(6, row.Saved ? 5 : 3, 6, row.Saved ? 5 : 3),
            MinHeight = row.Saved ? 34 : 30
        };

        _dock.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _dock.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _dock.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _marker = new Border
        {
            Width = 17,
            Height = 21,
            Margin = new Thickness(0, 0, 9, 0),
            VerticalAlignment = VerticalAlignment.Top,
            Background = Brushes.Transparent
        };
        Grid.SetColumn(_marker, 0);
        _dock.Children.Add(_marker);

        FrameworkElement fill;
        if (row.Link is SavedLinkNote link)
        {
            fill = LinkBody(link);
        }
        else
        {
            Editor = BuildTextEditor(row, out _placeholder);
            var stack = new Grid { Background = Brushes.Transparent };
            stack.Children.Add(_placeholder!);
            stack.Children.Add(Editor);
            fill = stack;
        }

        Grid.SetColumn(fill, 1);
        _dock.Children.Add(fill);
        RebuildRightActions(row);
        AttachContextMenu();

        if (!row.Saved)
        {
            _marker.MouseLeftButtonDown += (_, e) => { FocusAtEnd(); e.Handled = true; };
        }

        _surface.Child = _dock;
        Children.Add(_surface);

        PaintMarker();
        UpdateSurfaceAppearance();

        MouseEnter += (_, _) =>
        {
            _isHovered = true;
            UpdateHoverState();
        };
        MouseLeave += (_, _) =>
        {
            _isHovered = false;
            UpdateHoverState();
        };

        PreviewMouseMove += OnRowMouseMove;
        MouseLeftButtonDown += OnRowMouseDown;
        MouseLeftButtonUp += OnRowMouseUp;
        LostMouseCapture += (_, _) =>
        {
            if (!_dragPending && !_isDragging) return;
            var wasDragging = _isDragging;
            CancelDrag();
            if (wasDragging) _window.EndRowDrag(commit: false);
        };
    }

    private TextBox BuildTextEditor(TodoRow row, out TextBlock placeholder)
    {
        var editor = new TextBox
        {
            Text = row.Text,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            FontSize = 14,
            Padding = new Thickness(0),
            Margin = new Thickness(0, 1, 0, 0),
            CaretBrush = Theme.Caret,
            SelectionBrush = Theme.Freeze(0x81, 0x77, 0xBC),
            SelectionOpacity = 0.25,
            Foreground = row.Completed ? Theme.Completed : Theme.Text,
            VerticalAlignment = VerticalAlignment.Top
        };
        if (row.Completed) editor.TextDecorations = TextDecorations.Strikethrough;

        placeholder = new TextBlock
        {
            Text = row.Category == TodoCategory.Today ? "写下一件待办…" : "写下一条随记…",
            Foreground = row.Category == TodoCategory.Today ? Theme.TodayPlaceholder : Theme.Placeholder,
            FontSize = 13,
            IsHitTestVisible = false,
            Visibility = row.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed,
            Margin = new Thickness(2, 2, 0, 0),
            VerticalAlignment = VerticalAlignment.Top
        };

        TextCompositionManager.AddTextInputHandler(editor, (_, _) =>
        {
            if (!Ime.IsComposing(editor)) CommitText();
        });
        editor.TextChanged += (_, _) =>
        {
            if (_silent || Ime.IsComposing(editor)) return;
            CommitText();
        };
        editor.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.ImeProcessed || Ime.IsComposing(editor)) return;
            if (e.Key == Key.Enter && Keyboard.Modifiers != ModifierKeys.Shift)
            {
                _window.OnSubmit(_row);
                e.Handled = true;
            }
            else if ((e.Key == Key.Back || e.Key == Key.Delete) && editor.Text.Length == 0)
            {
                _window.OnEmptyDelete(_row);
                e.Handled = true;
            }
        };
        editor.GotFocus += (_, _) =>
        {
            if (_placeholder is not null && _row.Category != TodoCategory.Today)
                _placeholder.Visibility = Visibility.Collapsed;
            UpdateSurfaceAppearance();
            PaintMarker();
            _window.ActivateForTyping();
        };
        editor.LostFocus += (_, _) =>
        {
            CommitText();
            if (_placeholder is not null)
                _placeholder.Visibility = editor.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            UpdateSurfaceAppearance();
            PaintMarker();
            Dispatcher.BeginInvoke(() =>
            {
                if (Keyboard.FocusedElement is TextBox) return;
                if (!_window.IsKeyboardFocusWithin) _window.Reload();
            }, DispatcherPriority.Background);
        };
        return editor;
    }

    private void RebuildRightActions(TodoRow row)
    {
        if (_rightActionHost is not null)
        {
            _dock.Children.Remove(_rightActionHost);
            _rightActionHost = null;
        }
        _trashButton = null;
        _moveButton = null;
        _clockButton = null;
        _clockLabel = null;
        _clockMark = null;
        _clockPlate = null;

        var hasContent = !TodoEditing.ShouldDeleteRow(row.Text);
        if (!row.Saved || !hasContent) return;

        var host = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Top,
            HorizontalAlignment = HorizontalAlignment.Right,
            Background = Brushes.Transparent,
            Margin = new Thickness(4, 0, 0, 0)
        };
        Grid.SetColumn(host, 2);

        if (row.Link is not null)
        {
            _trashButton = BuildTrashButton();
            host.Children.Add(_trashButton);
        }

        if (row.Category == TodoCategory.Notes)
        {
            _moveButton = BuildMoveButton();
            host.Children.Add(_moveButton);
        }
        else if (row.Category == TodoCategory.Today && !row.Completed)
        {
            _clockButton = BuildClockButton(out _clockLabel);
            host.Children.Add(_clockButton);
        }

        if (host.Children.Count > 0)
        {
            _rightActionHost = host;
            _dock.Children.Add(host);
        }
    }

    /**
     * 将焦点放到本行输入框末尾。
     */
    public void FocusAtEnd()
    {
        if (Editor is null) return;
        Editor.Focus();
        Editor.Select(Editor.Text.Length, 0);
    }

    /**
     * 清除输入框内选中的文本高亮。
     */
    public void ClearSelection()
    {
        if (Editor is null || Editor.SelectionLength == 0) return;
        Editor.Select(Editor.CaretIndex, 0);
    }

    /**
     * 关闭本行已打开的倒计时气泡菜单。
     */
    public void CloseClockPopup()
    {
        if (_clockPopup is not null && _clockPopup.IsOpen)
            _clockPopup.IsOpen = false;
    }

    /**
     * 增量同步行数据到已有视图，避免清空整张列表造成的闪烁与滚动条复位。
     * @param {TodoRow} row 最新的行数据模型
     * @param {bool} keepText 是否保留当前正在输入中的文本内容
     */
    public void Sync(TodoRow row, bool keepText)
    {
        var wasCompleted = _row.Completed;
        var hadContent = !TodoEditing.ShouldDeleteRow(_row.Text);
        var hasContent = !TodoEditing.ShouldDeleteRow(row.Text);
        var wasSaved = _row.Saved;
        _row = row;

        if (wasSaved != row.Saved)
            _surface.Padding = new Thickness(6, row.Saved ? 5 : 3, 6, row.Saved ? 5 : 3);

        if (Editor is not null && !keepText && !IsComposing)
        {
            if (Editor.Text != row.Text)
            {
                _silent = true;
                Editor.Text = row.Text;
                _silent = false;
            }
            Editor.Foreground = row.Completed ? Theme.Completed : Theme.Text;
            Editor.TextDecorations = row.Completed ? TextDecorations.Strikethrough : null;
            if (_placeholder is not null)
                _placeholder.Visibility = Editor.Text.Length == 0 && (row.Category == TodoCategory.Today || !Editor.IsKeyboardFocused)
                    ? Visibility.Visible
                    : Visibility.Collapsed;
        }

        if (_linkTitle is not null && !keepText && !Ime.IsComposing(_linkTitle) && row.Link is SavedLinkNote link)
        {
            if (_linkTitle.Text != link.Title)
            {
                _silent = true;
                _linkTitle.Text = link.Title;
                _silent = false;
            }
            if (_linkDisplay is not null)
            {
                _linkDisplay.Text = link.Title;
                _linkDisplay.Foreground = row.Completed ? Theme.Completed : Theme.Link;
                _linkDisplay.TextDecorations = row.Completed ? TextDecorations.Strikethrough : null;
            }
            if (_linkDomain is not null)
                _linkDomain.Foreground = row.Completed ? Theme.TodayPlaceholder : Theme.Domain;
        }

        if (wasCompleted != row.Completed || hadContent != hasContent || wasSaved != row.Saved)
        {
            RebuildRightActions(row);
            UpdateHoverState();
        }

        PaintMarker(animateCompletion: wasCompleted != row.Completed);
        RefreshClock();
        UpdateSurfaceAppearance();
    }

    /**
     * 刷新本行倒计时剩余时间与状态图标。
     */
    public void RefreshClock()
    {
        if (_clockLabel is null) return;
        var timer = _window.Countdowns.Timer(_row.Id);
        var status = timer?.Status(DateTime.UtcNow);
        var brush = status == CountdownStatus.Paused ? Theme.ClockPaused
            : status == CountdownStatus.Expired ? Theme.ClockExpired
            : Theme.ClockRunning;

        _clockLabel.Text = timer is null ? "" : status == CountdownStatus.Expired ? "已到时" : Countdown.Format(timer.Remaining(DateTime.UtcNow));
        _clockLabel.Margin = timer is null ? new Thickness(0) : new Thickness(4, 0, 0, 0);
        _clockLabel.Foreground = brush;

        if (_clockMark is not null)
        {
            var next = Marks.Clock(brush, status);
            _clockMark.Data = next.Data;
            _clockMark.Stroke = brush;
            _clockMark.StrokeThickness = next.StrokeThickness;
        }

        if (_clockButton is not null)
        {
            var shouldShow = timer is not null || _isHovered || _clockPopup?.IsOpen == true;
            _clockButton.Visibility = shouldShow ? Visibility.Visible : Visibility.Collapsed;
            SetOpacity(_clockButton, shouldShow ? 1 : 0, 0);
        }
    }

    private void CommitText()
    {
        if (Editor is null || _silent || IsComposing) return;
        _row.Text = Editor.Text;
        if (_placeholder is not null)
            _placeholder.Visibility = Editor.Text.Length == 0 && (_row.Category == TodoCategory.Today || !Editor.IsKeyboardFocused)
                ? Visibility.Visible
                : Visibility.Collapsed;
        _window.OnText(_row, Editor.Text);
    }

    private void PaintMarker(bool animateCompletion = false)
    {
        _marker.MouseLeftButtonDown -= Toggle;

        if (!_row.Saved)
        {
            var focused = Editor?.IsKeyboardFocused == true;
            var plusColor = _row.Category == TodoCategory.Today
                ? Theme.TodayPlaceholder
                : (focused ? Theme.PlusFocused : (_isHovered ? Theme.Placeholder : Theme.Plus));
            if (_plusMark is null)
            {
                _plusMark = new TextBlock
                {
                    Text = "+",
                    FontSize = 15,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center
                };
            }
            _plusMark.Foreground = plusColor;
            _marker.Child = _plusMark;
            _marker.Cursor = Cursors.IBeam;
            return;
        }

        if (_row.Category == TodoCategory.Notes)
        {
            _marker.Child = new Ellipse
            {
                Width = 5,
                Height = 5,
                Fill = Theme.Bullet,
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(5, 7, 0, 0)
            };
            _marker.Cursor = Cursors.Arrow;
            return;
        }

        if (_checkboxBox is null)
        {
            _checkboxScale = new ScaleTransform(1, 1);
            _checkmarkPath = Marks.Checkmark(Brushes.White);
            _checkmarkPath.HorizontalAlignment = HorizontalAlignment.Center;
            _checkmarkPath.VerticalAlignment = VerticalAlignment.Center;
            _checkboxBox = new Border
            {
                Width = 15,
                Height = 15,
                Margin = new Thickness(0, 2, 0, 0),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                CornerRadius = new CornerRadius(5),
                BorderThickness = new Thickness(1.4),
                RenderTransformOrigin = new Point(0.5, 0.5),
                RenderTransform = _checkboxScale,
                Child = _checkmarkPath
            };
        }

        _checkboxBox.BorderBrush = _row.Completed ? Theme.CheckboxDone : Theme.Checkbox;
        _checkboxBox.Background = _row.Completed ? Theme.CheckboxDone : Brushes.Transparent;
        if (_checkmarkPath is not null)
            _checkmarkPath.Opacity = _row.Completed ? 1 : 0;

        if (animateCompletion && _checkboxScale is not null)
        {
            var pulse = new DoubleAnimationUsingKeyFrames();
            pulse.KeyFrames.Add(new EasingDoubleKeyFrame(1.12, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(80))));
            pulse.KeyFrames.Add(new EasingDoubleKeyFrame(1.0, KeyTime.FromTimeSpan(TimeSpan.FromMilliseconds(180))));
            _checkboxScale.BeginAnimation(ScaleTransform.ScaleXProperty, pulse);
            _checkboxScale.BeginAnimation(ScaleTransform.ScaleYProperty, pulse);
        }

        _marker.Child = _checkboxBox;
        _marker.Cursor = Cursors.Hand;
        _marker.MouseLeftButtonDown += Toggle;
    }

    private void Toggle(object sender, MouseButtonEventArgs e)
    {
        _window.OnToggle(_row);
        e.Handled = true;
    }

    private void UpdateHoverState()
    {
        UpdateSurfaceAppearance();

        if (!_row.Saved && _row.Category != TodoCategory.Today)
            PaintMarker();

        if (_trashButton is not null)
        {
            SetOpacity(_trashButton, _isHovered ? 1 : 0, 140);
            _trashButton.IsHitTestVisible = _isHovered;
        }

        if (_moveButton is not null)
        {
            SetOpacity(_moveButton, _isHovered ? 1 : 0, 140);
            _moveButton.IsHitTestVisible = _isHovered;
        }

        if (_clockButton is not null)
        {
            var hasTimer = _window.Countdowns.Timer(_row.Id) is not null;
            var keepVisible = hasTimer || _isHovered || _clockPopup?.IsOpen == true;
            if (keepVisible)
            {
                _clockButton.Visibility = Visibility.Visible;
                SetOpacity(_clockButton, 1, 140);
            }
            else
            {
                _clockButton.Visibility = Visibility.Collapsed;
                SetOpacity(_clockButton, 0, 0);
            }
        }
    }

    private void UpdateSurfaceAppearance()
    {
        if (_isDragging)
        {
            _surface.Background = _window.IsGlassMode ? Theme.RowHoverGlass : Theme.RowHover;
            Opacity = 0.82;
            return;
        }
        Opacity = 1;

        if (!_row.Saved)
        {
            var focused = Editor?.IsKeyboardFocused == true;
            _surface.Background = focused ? Theme.InputFocusedBackground : Brushes.Transparent;
            return;
        }

        if (_isHovered || _clockPopup?.IsOpen == true)
        {
            _surface.Background = _window.IsGlassMode && _row.Category == TodoCategory.Today
                ? Theme.RowHoverGlass
                : Theme.RowHover;
        }
        else
        {
            _surface.Background = Brushes.Transparent;
        }
    }

    private static void SetOpacity(UIElement target, double to, int durationMs)
    {
        if (durationMs <= 0)
        {
            target.BeginAnimation(OpacityProperty, null);
            target.Opacity = to;
            return;
        }
        var anim = new DoubleAnimation(to, TimeSpan.FromMilliseconds(durationMs))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }
        };
        target.BeginAnimation(OpacityProperty, anim);
    }

    private Border BuildMoveButton()
    {
        var button = new Border
        {
            MinWidth = 44,
            Height = 21,
            Padding = new Thickness(4, 0, 0, 0),
            Opacity = _isHovered ? 1 : 0,
            IsHitTestVisible = _isHovered,
            Background = Brushes.Transparent,
            Cursor = Cursors.Hand,
            VerticalAlignment = VerticalAlignment.Top,
            Child = new TextBlock
            {
                Text = _row.Category.MoveTitle(),
                FontSize = 10.5,
                Foreground = Theme.Move,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        button.MouseLeftButtonDown += (_, e) =>
        {
            _window.OnMove(_row);
            e.Handled = true;
        };
        return button;
    }

    private Button BuildTrashButton()
    {
        var mark = Marks.Trash(Theme.Icon);
        var plate = new Border
        {
            Width = 22,
            Height = 21,
            CornerRadius = new CornerRadius(5),
            Background = Brushes.Transparent,
            Child = mark
        };
        var button = FlatButton(plate);
        button.Width = 22;
        button.Height = 21;
        button.Opacity = _isHovered ? 1 : 0;
        button.IsHitTestVisible = _isHovered;
        button.ToolTip = "删除这条链接";
        button.MouseEnter += (_, _) =>
        {
            plate.Background = Theme.IconPlate;
            mark.Stroke = Theme.IconHover;
        };
        button.MouseLeave += (_, _) =>
        {
            plate.Background = Brushes.Transparent;
            mark.Stroke = Theme.Icon;
        };
        button.Click += (_, _) => _window.OnDeleteLink(_row);
        return button;
    }

    private Button BuildClockButton(out TextBlock label)
    {
        label = new TextBlock
        {
            FontSize = 12,
            FontFamily = new FontFamily("Segoe UI, Microsoft YaHei UI"),
            Foreground = Theme.ClockRunning,
            VerticalAlignment = VerticalAlignment.Center
        };
        Typography.SetNumeralAlignment(label, FontNumeralAlignment.Tabular);

        _clockMark = Marks.Clock(Theme.ClockRunning, null);
        var stack = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(_clockMark);
        stack.Children.Add(label);

        _clockPlate = new Border
        {
            CornerRadius = new CornerRadius(5),
            Padding = new Thickness(5, 3, 5, 3),
            MinWidth = 26,
            MinHeight = 21,
            Background = Brushes.Transparent,
            Child = stack
        };

        var button = FlatButton(_clockPlate);
        button.Visibility = Visibility.Collapsed;
        button.Opacity = 0;
        button.VerticalAlignment = VerticalAlignment.Top;
        button.ToolTip = "设置倒计时";

        var popup = new Popup
        {
            PlacementTarget = button,
            Placement = PlacementMode.Custom,
            StaysOpen = false,
            AllowsTransparency = true,
            CustomPopupPlacementCallback = PlaceCountdownPopup
        };
        _clockPopup = popup;

        popup.Opened += (_, _) =>
        {
            _window.OpenPopup = popup;
            _window.Hold(true);
            if (_clockPlate is not null) _clockPlate.Background = Theme.ClockPlate;
            UpdateSurfaceAppearance();
        };
        popup.Closed += (_, _) =>
        {
            if (_window.OpenPopup == popup) _window.OpenPopup = null;
            if (_clockPlate is not null) _clockPlate.Background = Brushes.Transparent;
            _window.Hold(false);
            RefreshClock();
            UpdateSurfaceAppearance();
        };
        button.Click += (_, _) =>
        {
            if (popup.IsOpen)
            {
                popup.IsOpen = false;
                return;
            }
            _window.ActivateForTyping();
            _window.Hold(true);
            Dispatcher.BeginInvoke(() =>
            {
                popup.Child = CountdownMenuView.Create(_window.Countdowns, _row.Id, () => popup.IsOpen = false, RefreshClock);
                popup.IsOpen = true;
            }, DispatcherPriority.Input);
        };

        RefreshClock();
        return button;
    }

    private CustomPopupPlacement[] PlaceCountdownPopup(Size popupSize, Size targetSize, Point offset)
    {
        var margin = CountdownMenuView.ShadowMargin;
        var menuWidth = popupSize.Width - margin * 2;
        var menuHeight = popupSize.Height - margin * 2;
        var cardBounds = _window.GetCardBoundsInDevicePixels();
        if (cardBounds.Width <= 0 || _clockButton is null)
        {
            return [new CustomPopupPlacement(new Point(targetSize.Width - popupSize.Width + margin, targetSize.Height + 4 - margin), PopupPrimaryAxis.Horizontal)];
        }

        var source = PresentationSource.FromVisual(_clockButton);
        var scale = source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        if (scale <= 0) scale = 1.0;

        var targetTopLeftPx = _clockButton.PointToScreen(new Point(0, 0));
        var targetTopLeftDip = new Point(targetTopLeftPx.X / scale, targetTopLeftPx.Y / scale);
        var cardBottomDip = cardBounds.Bottom / scale;
        var cardLeftDip = cardBounds.Left / scale;
        var cardRightDip = cardBounds.Right / scale;

        var gap = 4.0;
        var inset = 8.0;
        var spaceBelow = cardBottomDip - inset - (targetTopLeftDip.Y + targetSize.Height + gap);
        var placeAbove = spaceBelow < menuHeight;

        var y = placeAbove
            ? -menuHeight - gap - margin
            : targetSize.Height + gap - margin;

        var desiredLeftDip = targetTopLeftDip.X + targetSize.Width - menuWidth;
        var minLeftDip = cardLeftDip + inset;
        var maxLeftDip = Math.Max(minLeftDip, cardRightDip - menuWidth - inset);
        var clampedLeftDip = Math.Min(maxLeftDip, Math.Max(minLeftDip, desiredLeftDip));
        var x = (clampedLeftDip - targetTopLeftDip.X) - margin;

        return [new CustomPopupPlacement(new Point(x, y), PopupPrimaryAxis.Horizontal)];
    }

    private static Button FlatButton(object content)
    {
        var button = new Button
        {
            Content = content,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            Cursor = Cursors.Hand,
            Focusable = false,
            FocusVisualStyle = null,
            OverridesDefaultStyle = true
        };
        var template = new ControlTemplate(typeof(Button));
        var presenter = new FrameworkElementFactory(typeof(ContentPresenter));
        presenter.SetValue(HorizontalAlignmentProperty, HorizontalAlignment.Center);
        presenter.SetValue(VerticalAlignmentProperty, VerticalAlignment.Center);
        template.VisualTree = presenter;
        button.Template = template;
        return button;
    }

    private FrameworkElement LinkBody(SavedLinkNote link)
    {
        _linkDisplay = new TextBlock
        {
            Text = link.Title,
            FontSize = 14,
            FontWeight = FontWeights.Medium,
            Foreground = _row.Completed ? Theme.Completed : Theme.Link,
            TextDecorations = _row.Completed ? TextDecorations.Strikethrough : null,
            TextWrapping = TextWrapping.Wrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            LineHeight = 19,
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            MaxHeight = 57,
            Cursor = Cursors.IBeam,
            ToolTip = "点击修改标题"
        };
        _linkTitle = new TextBox
        {
            Text = link.Title,
            Visibility = Visibility.Collapsed,
            AcceptsReturn = false,
            TextWrapping = TextWrapping.Wrap,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            FontSize = 14,
            FontWeight = FontWeights.Medium,
            Padding = new Thickness(0),
            CaretBrush = Theme.Caret,
            SelectionBrush = Theme.Freeze(0x81, 0x77, 0xBC),
            SelectionOpacity = 0.25,
            Foreground = Theme.Link,
            FocusVisualStyle = null
        };

        _linkDisplay.MouseLeftButtonDown += (_, e) =>
        {
            _titleBeforeEdit = _linkTitle.Text;
            _linkDisplay.Visibility = Visibility.Collapsed;
            _linkTitle.Visibility = Visibility.Visible;
            _window.ActivateForTyping();
            _linkTitle.Focus();
            _linkTitle.Select(_linkTitle.Text.Length, 0);
            e.Handled = true;
        };
        _linkTitle.TextChanged += (_, _) => CommitLinkTitle();
        _linkTitle.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.ImeProcessed || Ime.IsComposing(_linkTitle)) return;
            if (e.Key == Key.Enter)
            {
                CommitLinkTitle();
                Keyboard.ClearFocus();
                e.Handled = true;
            }
            else if (e.Key == Key.Escape)
            {
                _silent = true;
                _linkTitle.Text = _titleBeforeEdit;
                _silent = false;
                CommitLinkTitle();
                Keyboard.ClearFocus();
                e.Handled = true;
            }
        };
        _linkTitle.LostFocus += (_, _) =>
        {
            CommitLinkTitle();
            _linkTitle.Visibility = Visibility.Collapsed;
            if (_linkDisplay is not null)
            {
                _linkDisplay.Text = _linkTitle.Text;
                _linkDisplay.Visibility = Visibility.Visible;
            }
            Dispatcher.BeginInvoke(() =>
            {
                if (Keyboard.FocusedElement is TextBox) return;
                if (!_window.IsKeyboardFocusWithin) _window.Reload();
            }, DispatcherPriority.Background);
        };

        var titleHost = new Grid { Background = Brushes.Transparent };
        titleHost.Children.Add(_linkDisplay);
        titleHost.Children.Add(_linkTitle);

        var stack = new StackPanel { Background = Brushes.Transparent };
        stack.Children.Add(TitleRow(link, titleHost));

        if (link.SourceIcon is not SavedLinkSource source || SiteIcons.Get(source) is null)
        {
            _linkDomain = new TextBlock
            {
                Text = link.Domain,
                FontSize = 11,
                Foreground = _row.Completed ? Theme.TodayPlaceholder : Theme.Domain,
                Margin = new Thickness(0, 2, 0, 0),
                Cursor = Cursors.Hand,
                HorizontalAlignment = HorizontalAlignment.Left,
                ToolTip = "在 Edge 中打开网页"
            };
            _linkDomain.MouseEnter += (_, _) =>
            {
                if (!_row.Completed && _linkDomain is not null)
                {
                    _linkDomain.Foreground = Theme.LinkHover;
                    _linkDomain.TextDecorations = TextDecorations.Underline;
                }
            };
            _linkDomain.MouseLeave += (_, _) =>
            {
                if (_linkDomain is not null)
                {
                    _linkDomain.Foreground = _row.Completed ? Theme.TodayPlaceholder : Theme.Domain;
                    _linkDomain.TextDecorations = null;
                }
            };
            _linkDomain.MouseLeftButtonDown += (_, e) =>
            {
                _window.OpenLink(link.Url);
                e.Handled = true;
            };
            stack.Children.Add(_linkDomain);
        }

        var menu = new ContextMenu();
        menu.Opened += (_, _) =>
        {
            menu.Items.Clear();
            var openItem = new MenuItem { Header = "在 Edge 中打开" };
            openItem.Click += (_, _) => _window.OpenLink(link.Url);
            menu.Items.Add(openItem);
            if (_row.Saved && _row.Category == TodoCategory.Today)
            {
                var moveItem = new MenuItem { Header = "移到随记" };
                moveItem.Click += (_, _) => _window.OnMove(_row);
                menu.Items.Add(moveItem);
            }
            var deleteItem = new MenuItem { Header = "删除链接" };
            deleteItem.Click += (_, _) => _window.OnDeleteLink(_row);
            menu.Items.Add(deleteItem);
        };
        stack.ContextMenu = menu;
        return stack;
    }

    /**
     * 为普通文本待办行挂接右键菜单，支持在今日待办空白区域或文本框右键直接触发「移到随记」。
     */
    private void AttachContextMenu()
    {
        if (_row.Link is not null) return;
        var rowMenu = new ContextMenu();
        ContextMenu = rowMenu;
        ContextMenuOpening += (_, e) =>
        {
            if (!_row.Saved || _row.Category != TodoCategory.Today || TodoEditing.ShouldDeleteRow(_row.Text))
            {
                e.Handled = true;
                return;
            }
            rowMenu.Items.Clear();
            var moveItem = new MenuItem { Header = "移到随记" };
            moveItem.Click += (_, _) => _window.OnMove(_row);
            rowMenu.Items.Add(moveItem);
        };

        if (Editor is not null)
        {
            var editorMenu = new ContextMenu();
            Editor.ContextMenu = editorMenu;
            Editor.ContextMenuOpening += (_, _) =>
            {
                editorMenu.Items.Clear();
                editorMenu.Items.Add(new MenuItem { Command = ApplicationCommands.Cut, Header = "剪切" });
                editorMenu.Items.Add(new MenuItem { Command = ApplicationCommands.Copy, Header = "复制" });
                editorMenu.Items.Add(new MenuItem { Command = ApplicationCommands.Paste, Header = "粘贴" });
                if (_row.Saved && _row.Category == TodoCategory.Today && !TodoEditing.ShouldDeleteRow(_row.Text))
                {
                    editorMenu.Items.Add(new Separator());
                    var moveItem = new MenuItem { Header = "移到随记" };
                    moveItem.Click += (_, _) => _window.OnMove(_row);
                    editorMenu.Items.Add(moveItem);
                }
            };
        }
    }

    private void CommitLinkTitle()
    {
        if (_linkTitle is null || _silent || Ime.IsComposing(_linkTitle) || _row.Link is not SavedLinkNote link) return;
        var edited = _linkTitle.Text.Replace("\r", " ").Replace("\n", " ").Trim();
        var lines = link.OriginalText.Replace("\r", "").Trim().Split('\n');
        var address = lines[^1].Trim();
        var next = edited.Length == 0 ? address : edited + "\n" + address;
        if (next == _row.Text) return;
        _row.Text = next;
        _window.OnText(_row, next);
    }

    private FrameworkElement TitleRow(SavedLinkNote link, FrameworkElement title)
    {
        var row = new Grid { Background = Brushes.Transparent };
        var image = link.SourceIcon is SavedLinkSource source ? SiteIcons.Get(source) : null;
        if (image is null)
        {
            row.Children.Add(title);
            return row;
        }
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = new Image
        {
            Source = image,
            Width = 14,
            Height = 14,
            Margin = new Thickness(0, 2.5, 5, 0),
            Cursor = Cursors.Hand,
            VerticalAlignment = VerticalAlignment.Top,
            ToolTip = "在 Edge 中打开网页"
        };
        RenderOptions.SetBitmapScalingMode(icon, BitmapScalingMode.HighQuality);
        icon.MouseLeftButtonDown += (_, e) =>
        {
            _window.OpenLink(link.Url);
            e.Handled = true;
        };
        Grid.SetColumn(title, 1);
        row.Children.Add(icon);
        row.Children.Add(title);
        return row;
    }

    private bool CanDragSort => _row.Saved && _row.Category == TodoCategory.Today && !_row.Completed;

    private bool IsPointOverInteractiveControl(DependencyObject? source)
    {
        while (source is not null && source != this)
        {
            if (source == _marker || source == _rightActionHost || source == Editor || source == _linkTitle || source == _linkDisplay || source == _linkDomain)
                return true;
            if (source is Image || source is Button)
                return true;
            source = VisualTreeHelper.GetParent(source);
        }
        return false;
    }

    private void OnRowMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (!CanDragSort || e.ChangedButton != MouseButton.Left) return;
        if (IsPointOverInteractiveControl(e.OriginalSource as DependencyObject)) return;

        _dragPending = true;
        _dragStartInWindow = e.GetPosition(_window);
        CaptureMouse();
        e.Handled = true;
    }

    private void OnRowMouseMove(object sender, MouseEventArgs e)
    {
        if (_dragPending || _isDragging)
        {
            var current = e.GetPosition(_window);
            if (_dragPending && (current - _dragStartInWindow).Length >= 6)
            {
                _dragPending = false;
                _isDragging = true;
                Keyboard.ClearFocus();
                UpdateSurfaceAppearance();
                _window.BeginRowDrag(this);
            }
            if (_isDragging)
            {
                Cursor = Cursors.SizeNS;
                _window.UpdateRowDrag(e.GetPosition(_window));
            }
            return;
        }

        if (!CanDragSort)
        {
            ClearValue(CursorProperty);
            return;
        }

        Cursor = IsPointOverInteractiveControl(e.OriginalSource as DependencyObject) ? null : Cursors.SizeAll;
    }

    private void OnRowMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragPending && !_isDragging) return;
        var wasDragging = _isDragging;
        _dragPending = false;
        _isDragging = false;
        if (IsMouseCaptured) ReleaseMouseCapture();
        ClearValue(CursorProperty);
        UpdateSurfaceAppearance();
        if (wasDragging) _window.EndRowDrag(commit: true);
        e.Handled = true;
    }

    /**
     * 取消当前行正在进行的拖拽排序操作（例如按 Esc 键）。
     */
    public void CancelDrag()
    {
        if (!_dragPending && !_isDragging) return;
        _dragPending = false;
        _isDragging = false;
        if (IsMouseCaptured) ReleaseMouseCapture();
        ClearValue(CursorProperty);
        UpdateSurfaceAppearance();
    }
}
