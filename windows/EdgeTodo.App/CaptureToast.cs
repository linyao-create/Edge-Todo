using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;

namespace EdgeTodo;

/**
 * 浏览器快速收藏随记后的轻提示气泡窗口。
 */
public static class CaptureToast
{
    /**
     * 在当前鼠标指针下方弹出轻提示气泡并在短时间后自动关闭。
     * @param {string} message 提示文本内容
     * @param {bool} error 是否为错误提示
     */
    public static void Show(string message, bool error)
    {
        var window = new Window
        {
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = Brushes.Transparent,
            ShowInTaskbar = false,
            ShowActivated = false,
            Topmost = true,
            Width = error ? 308 : 208,
            Height = error ? 80 : 68,
            IsHitTestVisible = false,
            FontFamily = new FontFamily("Microsoft YaHei UI")
        };

        var foreground = new SolidColorBrush(error ? Color.FromRgb(0x9E, 0x66, 0x6E) : Color.FromRgb(0x72, 0x6D, 0x7C));
        var icon = error
            ? Marks.Stroke("M8,3 A5,5 0 1 0 8.01,3 M8,5.5 V8.5 M8,10.5 H8.01", foreground, 14, 1.4)
            : Marks.Checkmark(foreground);
        icon.VerticalAlignment = VerticalAlignment.Center;
        icon.Margin = new Thickness(0, 0, 8, 0);

        var text = new TextBlock
        {
            Text = (error ? "未能存入随记  " : "") + message,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = foreground
        };

        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center
        };
        row.Children.Add(icon);
        row.Children.Add(text);

        window.Content = new Border
        {
            Background = Theme.Freeze(0xFB, 0xFB, 0xFD, 247),
            BorderBrush = Theme.PanelBorder,
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(13, 10, 13, 10),
            Margin = new Thickness(12),
            Child = row,
            Effect = new DropShadowEffect { BlurRadius = 8, ShadowDepth = 3, Direction = 270, Opacity = 0.12, Color = Colors.Black }
        };

        if (Native.GetCursorPos(out var point))
        {
            var scale = Monitors.All().FirstOrDefault(monitor => point.X >= monitor.Left && point.X < monitor.Right && point.Y >= monitor.Top && point.Y < monitor.Bottom)?.Dpi / 96.0 ?? 1;
            if (scale <= 0) scale = 1;
            window.Left = point.X / scale - window.Width / 2;
            window.Top = point.Y / scale + 12;
        }

        window.Show();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(error ? 4500 : 2500) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            window.Close();
        };
        timer.Start();
    }
}
