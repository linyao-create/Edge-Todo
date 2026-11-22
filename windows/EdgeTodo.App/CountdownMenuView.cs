using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace EdgeTodo;

/**
 * 倒计时快捷设置与状态管理气泡菜单，复刻原版 Mac 极简浮层样式。
 */
internal static class CountdownMenuView
{
    public const double MenuWidth = 168;
    public const double ShadowMargin = 12;

    /**
     * 创建倒计时气泡菜单视图（外层已预留阴影呼吸边距以防被透明窗口裁剪）。
     * @param {CountdownManager} manager 倒计时管理器
     * @param {Guid} id 关联待办条目的唯一标识
     * @param {Action} close 关闭菜单的回调
     * @param {Action} refresh 刷新对应行倒计时显示的回调
     * @returns {FrameworkElement} 可直接作为 Popup.Child 的根元素
     */
    public static FrameworkElement Create(CountdownManager manager, Guid id, Action close, Action refresh)
    {
        var shell = new Border
        {
            Width = MenuWidth,
            Background = Theme.Panel,
            BorderBrush = Theme.Freeze(0xE5, 0xE2, 0xEB),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(5),
            Margin = new Thickness(ShadowMargin),
            Effect = new DropShadowEffect
            {
                BlurRadius = 12,
                ShadowDepth = 3,
                Direction = 270,
                Opacity = 0.11,
                Color = Color.FromRgb(0x2B, 0x28, 0x43)
            }
        };

        void Render(string mode)
        {
            var timer = manager.Timer(id);
            var status = timer?.Status(DateTime.UtcNow);
            shell.Child = mode switch
            {
                "custom" => Custom(manager, id, close, refresh, () => Render("presets")),
                "presets" => Presets(manager, id, close, refresh, () => Render("custom")),
                _ when timer is null => Presets(manager, id, close, refresh, () => Render("custom")),
                _ => Controls(manager, id, status, close, refresh, () => Render("presets"), () => Render("controls"))
            };
        }

        Render("auto");
        return shell;
    }

    private static UIElement Presets(CountdownManager manager, Guid id, Action close, Action refresh, Action custom)
    {
        var menu = new StackPanel();
        menu.Children.Add(Pair(
            Choice("15 分钟", () => Start(manager, id, 900, close, refresh)),
            Choice("30 分钟", () => Start(manager, id, 1800, close, refresh))));
        menu.Children.Add(Pair(
            Choice("1 小时", () => Start(manager, id, 3600, close, refresh)),
            Choice("3 小时", () => Start(manager, id, 10800, close, refresh))));
        menu.Children.Add(new Border
        {
            Height = 1,
            Background = Theme.Freeze(0xEF, 0xED, 0xF3),
            Margin = new Thickness(4, 3, 4, 3)
        });
        menu.Children.Add(Choice("自定义…", custom));
        return menu;
    }

    private static UIElement Controls(CountdownManager manager, Guid id, CountdownStatus? status, Action close, Action refresh, Action presets, Action again)
    {
        var menu = new StackPanel();
        if (status == CountdownStatus.Running)
            menu.Children.Add(Choice("暂停", () => { manager.Pause(id); refresh(); again(); }));
        if (status == CountdownStatus.Paused)
            menu.Children.Add(Choice("继续", () => { manager.Resume(id); refresh(); again(); }));
        menu.Children.Add(Choice(status == CountdownStatus.Expired ? "再设一轮" : "重新设置", presets));
        menu.Children.Add(Choice("取消计时", () => { manager.Set(null, id); refresh(); close(); }, danger: true));
        return menu;
    }

    private static UIElement Custom(CountdownManager manager, Guid id, Action close, Action refresh, Action back)
    {
        var menu = new StackPanel();
        var minutes = new TextBox
        {
            Width = 39,
            Height = 25,
            FontSize = 12,
            Foreground = Theme.Text,
            CaretBrush = Theme.Caret,
            VerticalContentAlignment = VerticalAlignment.Center,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Padding = new Thickness(4, 0, 4, 0)
        };
        var placeholder = new TextBlock
        {
            Text = "25",
            FontSize = 12,
            Foreground = Theme.TodayPlaceholder,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(5, 0, 0, 0),
            IsHitTestVisible = false
        };
        var inputHost = new Border
        {
            CornerRadius = new CornerRadius(5),
            Background = Theme.InputFocusedBackground,
            Height = 25,
            Width = 41,
            Child = new Grid { Children = { placeholder, minutes } }
        };

        var error = new TextBlock
        {
            Text = "请输入 1 至 10080 的整数分钟。",
            FontSize = 10,
            Foreground = Theme.Freeze(0xA2, 0x56, 0x64),
            Margin = new Thickness(5, 3, 5, 1),
            TextWrapping = TextWrapping.Wrap,
            Visibility = Visibility.Collapsed
        };

        void StartCustom()
        {
            if (!int.TryParse(minutes.Text, out var value) || value is < 1 or > 10080)
            {
                error.Visibility = Visibility.Visible;
                return;
            }
            Start(manager, id, value * 60, close, refresh);
        }

        minutes.TextChanged += (_, _) =>
        {
            placeholder.Visibility = minutes.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            if (Ime.IsComposing(minutes)) return;
            var digits = new string(minutes.Text.Where(char.IsDigit).Take(5).ToArray());
            if (digits == minutes.Text)
            {
                error.Visibility = Visibility.Collapsed;
                return;
            }
            minutes.Text = digits;
            minutes.CaretIndex = digits.Length;
        };

        minutes.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter || Ime.IsComposing(minutes)) return;
            StartCustom();
            e.Handled = true;
        };

        var row = new Grid { Margin = new Thickness(0, 1, 0, 1) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(43) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var backButton = BackButton(back);
        var unit = new TextBlock
        {
            Text = "分钟",
            FontSize = 11,
            Foreground = Theme.Icon,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(4, 0, 0, 0)
        };
        var startButton = RoundedActionButton("开始", StartCustom);

        Grid.SetColumn(backButton, 0);
        Grid.SetColumn(inputHost, 1);
        Grid.SetColumn(unit, 2);
        Grid.SetColumn(startButton, 4);
        row.Children.Add(backButton);
        row.Children.Add(inputHost);
        row.Children.Add(unit);
        row.Children.Add(startButton);
        menu.Children.Add(row);
        menu.Children.Add(error);
        minutes.Loaded += (_, _) => minutes.Focus();
        return menu;
    }

    private static Button BackButton(Action action)
    {
        var plate = new Border
        {
            Width = 22,
            Height = 25,
            CornerRadius = new CornerRadius(5),
            Background = Brushes.Transparent,
            Child = Marks.ArrowLeft(Theme.Icon)
        };
        var button = CreateFlatButton(plate, "返回快捷时长");
        button.MouseEnter += (_, _) => plate.Background = Theme.Freeze(0xF1, 0xEF, 0xF6);
        button.MouseLeave += (_, _) => plate.Background = Brushes.Transparent;
        button.Click += (_, _) => action();
        return button;
    }

    private static Button RoundedActionButton(string text, Action action)
    {
        var normal = Theme.Underline;
        var hover = Theme.IconHover;
        var plate = new Border
        {
            Background = normal,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(9, 5, 9, 5),
            Child = new TextBlock
            {
                Text = text,
                FontSize = 11,
                Foreground = Brushes.White,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        var button = CreateFlatButton(plate, "开始倒计时");
        button.MouseEnter += (_, _) => plate.Background = hover;
        button.MouseLeave += (_, _) => plate.Background = normal;
        button.Click += (_, _) => action();
        return button;
    }

    private static void Start(CountdownManager manager, Guid id, double seconds, Action close, Action refresh)
    {
        manager.Start(seconds, id);
        refresh();
        close();
    }

    private static Grid Pair(Button left, Button right)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition());
        row.ColumnDefinitions.Add(new ColumnDefinition());
        Grid.SetColumn(right, 1);
        row.Children.Add(left);
        row.Children.Add(right);
        return row;
    }

    private static Button Choice(string title, Action action, bool danger = false)
    {
        var label = new TextBlock
        {
            Text = title,
            FontSize = 12,
            Foreground = danger ? Theme.Freeze(0x87, 0x6A, 0x74) : Theme.Freeze(0x51, 0x4B, 0x5D)
        };
        var plate = new Border
        {
            Background = Brushes.Transparent,
            CornerRadius = new CornerRadius(5),
            Padding = new Thickness(8, 7, 8, 7),
            Child = label
        };
        var button = CreateFlatButton(plate);
        button.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        button.MouseEnter += (_, _) => plate.Background = Theme.Freeze(0xF1, 0xEF, 0xF6);
        button.MouseLeave += (_, _) => plate.Background = Brushes.Transparent;
        button.Click += (_, _) => action();
        return button;
    }

    private static Button CreateFlatButton(UIElement content, string? tooltip = null)
    {
        var button = new Button
        {
            Content = content,
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Cursor = Cursors.Hand,
            Focusable = false,
            FocusVisualStyle = null,
            OverridesDefaultStyle = true,
            ToolTip = tooltip
        };
        var template = new ControlTemplate(typeof(Button));
        template.VisualTree = new FrameworkElementFactory(typeof(ContentPresenter));
        button.Template = template;
        return button;
    }
}
