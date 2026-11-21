using System.Windows.Media;

namespace EdgeTodo;

/**
 * 面板视觉主题常量，对齐原版 macOS 的极简留白与紫灰配色体系。
 */
internal static class Theme
{
    public static readonly Brush Panel = Freeze(0xFB, 0xFB, 0xFD);
    public static readonly Brush PanelBorder = Freeze(0x58, 0x56, 0x6F, 43);
    public static readonly Brush GlassOverlay = Freeze(0xFB, 0xFB, 0xFD, 36);
    public static readonly Brush GlassBorder = Freeze(0x58, 0x56, 0x6F, 48);
    public static readonly Brush GlassInnerHighlight = Freeze(0xFF, 0xFF, 0xFF, 150);
    public static readonly Brush Text = Freeze(0x29, 0x28, 0x32);
    public static readonly Brush Completed = Freeze(0x77, 0x73, 0x7F);
    public static readonly Brush Date = Freeze(0x6E, 0x6A, 0x79);
    public static readonly Brush TodayPlaceholder = Freeze(0xC8, 0xC3, 0xD0);
    public static readonly Brush Placeholder = Freeze(0x89, 0x83, 0x91);
    public static readonly Brush Plus = Freeze(0xA0, 0x9B, 0xAA);
    public static readonly Brush PlusFocused = Freeze(0x71, 0x67, 0xA2);
    public static readonly Brush InputFocusedBackground = Freeze(0xF1, 0xF0, 0xF7);
    public static readonly Brush SelectedTab = Freeze(0x30, 0x2C, 0x3D);
    public static readonly Brush Tab = Freeze(0x72, 0x6D, 0x7C);
    public static readonly Brush HoveredTab = Freeze(0x51, 0x4B, 0x5D);
    public static readonly Brush Underline = Freeze(0x74, 0x6D, 0x99);
    public static readonly Brush Icon = Freeze(0x77, 0x73, 0x84);
    public static readonly Brush IconHover = Freeze(0x5C, 0x56, 0x8C);
    public static readonly Brush IconPlate = Freeze(0xEE, 0xED, 0xF5);
    public static readonly Brush ClockRunning = Freeze(0x71, 0x67, 0x99);
    public static readonly Brush ClockPaused = Freeze(0x99, 0x94, 0xA1);
    public static readonly Brush ClockExpired = Freeze(0x99, 0x5C, 0x68);
    public static readonly Brush ClockPlate = Freeze(0xEC, 0xEA, 0xF4);
    public static readonly Brush RowHover = Freeze(0xF3, 0xF2, 0xF8);
    public static readonly Brush RowHoverGlass = Freeze(0xFF, 0xFF, 0xFF, 48);
    public static readonly Brush Bullet = Freeze(0xA8, 0xA3, 0xBA);
    public static readonly Brush Checkbox = Freeze(0xB8, 0xB5, 0xC8);
    public static readonly Brush CheckboxDone = Freeze(0x81, 0x77, 0xBC);
    public static readonly Brush Link = Freeze(0x39, 0x35, 0x49);
    public static readonly Brush LinkHover = Freeze(0x6C, 0x60, 0xA6);
    public static readonly Brush Domain = Freeze(0x6F, 0x6A, 0x7B);
    public static readonly Brush Move = Freeze(0x82, 0x7A, 0x9A);
    public static readonly Brush ScrollThumb = Freeze(0xBB, 0xB8, 0xCA);
    public static readonly Brush Handle = Freeze(0x85, 0x81, 0x9D);
    public static readonly Brush HandleHover = Freeze(0x80, 0x7A, 0x9D);
    public static readonly Brush Caret = Freeze(0x34, 0x33, 0x3F);

    /**
     * 创建并冻结纯色画刷以提升 WPF 渲染性能。
     * @param {byte} r 红色通道
     * @param {byte} g 绿色通道
     * @param {byte} b 蓝色通道
     * @param {byte} a 透明度通道
     * @returns {SolidColorBrush} 冻结后的画刷
     */
    public static SolidColorBrush Freeze(byte r, byte g, byte b, byte a = 255)
    {
        var brush = new SolidColorBrush(Color.FromArgb(a, r, g, b));
        brush.Freeze();
        return brush;
    }
}
