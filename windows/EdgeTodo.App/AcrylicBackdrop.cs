using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using Microsoft.Win32;

namespace EdgeTodo;

/**
 * 固定面板时位于主窗口正下方的 Windows 11 原生系统级毛玻璃背景窗口。
 * 使用 WindowChrome + DWM 系统材质与硬件圆角，避免 SetWindowRgn 在 Win11 24H2 上失效产生直角白块。
 */
internal sealed class AcrylicBackdrop : Window
{
    private IntPtr _hwnd;
    private bool _backdropApplied;

    public AcrylicBackdrop()
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = false;
        Background = Brushes.Transparent;
        ShowInTaskbar = false;
        ShowActivated = false;
        Focusable = false;
        IsHitTestVisible = false;
        ResizeMode = ResizeMode.NoResize;
        Topmost = true;
        Title = "一角背景";

        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            GlassFrameThickness = new Thickness(-1),
            CaptionHeight = 0,
            CornerRadius = new CornerRadius(0),
            ResizeBorderThickness = new Thickness(0),
            UseAeroCaptionButtons = false
        });

        SourceInitialized += (_, _) =>
        {
            _hwnd = new WindowInteropHelper(this).Handle;
            if (HwndSource.FromHwnd(_hwnd) is { CompositionTarget: not null } source)
                source.CompositionTarget.BackgroundColor = Colors.Transparent;

            var style = Native.GetWindowLong(_hwnd, Native.GwlStyle);
            style = (style & ~(Native.WsCaption | Native.WsThickFrame | Native.WsBorder)) | unchecked((int)Native.WsPopup);
            Native.SetWindowLong(_hwnd, Native.GwlStyle, style);

            var exStyle = Native.GetWindowLong(_hwnd, Native.GwlExStyle);
            Native.SetWindowLong(_hwnd, Native.GwlExStyle, exStyle | Native.WsExToolWindow | Native.WsExNoActivate | Native.WsExTransparent);

            ApplyNativeBackdrop();
        };
    }

    /**
     * 检查当前系统是否允许透明毛玻璃特效。
     * @returns {bool} 是否启用系统透明特效
     */
    public static bool IsTransparencyEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            if (key?.GetValue("EnableTransparency") is int value) return value != 0;
        }
        catch
        {
        }
        return true;
    }

    /**
     * 将毛玻璃背景精准置于主面板卡片正下方。
     * @param {IntPtr} panelHwnd 主面板窗口句柄
     * @param {int} pxX 卡片物理像素 X 坐标
     * @param {int} pxY 卡片物理像素 Y 坐标
     * @param {int} pxW 卡片物理像素宽度
     * @param {int} pxH 卡片物理像素高度
     * @param {double} scale 当前显示器 DPI 缩放倍率
     */
    public void SyncBelow(IntPtr panelHwnd, int pxX, int pxY, int pxW, int pxH, double scale)
    {
        if (panelHwnd == IntPtr.Zero || pxW <= 0 || pxH <= 0) return;
        if (!IsVisible) Show();
        if (_hwnd == IntPtr.Zero) return;

        if (!_backdropApplied) ApplyNativeBackdrop();

        // 向内微缩 3px，确保 Win11 硬件 8px 圆角完全收在主卡片 18px 圆角内侧不露角
        var inset = Math.Max(2, (int)Math.Round(3.5 * scale));
        var bx = pxX + inset;
        var by = pxY + inset;
        var bw = Math.Max(20, pxW - inset * 2);
        var bh = Math.Max(20, pxH - inset * 2);

        Native.SetWindowPos(_hwnd, panelHwnd, bx, by, bw, bh, Native.SwpNoActivate | Native.SwpFrameChanged);
    }

    /**
     * 收起或取消固定时隐藏毛玻璃底层窗口。
     */
    public void HideBackdrop()
    {
        if (IsVisible) Hide();
    }

    private void ApplyNativeBackdrop()
    {
        if (_hwnd == IntPtr.Zero) return;

        var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        DwmExtendFrameIntoClientArea(_hwnd, ref margins);

        // 强制浅色背景基调并关闭 DWM 自带的灰色圆角外边框
        var darkMode = 0;
        DwmSetWindowAttribute(_hwnd, DwmwaUseImmersiveDarkMode, ref darkMode, sizeof(int));

        var cornerPref = 2; // DWMWCP_ROUND
        DwmSetWindowAttribute(_hwnd, DwmwaWindowCornerPreference, ref cornerPref, sizeof(int));

        var noBorder = unchecked((int)0xFFFFFFFE); // DWMWA_COLOR_NONE
        DwmSetWindowAttribute(_hwnd, DwmwaBorderColor, ref noBorder, sizeof(int));

        // 不使用 DWMSBT_TRANSIENTWINDOW（Win11 在无焦点时将其强行降级为纯灰块），
        // 改为结合 WindowChrome + 硬件圆角的 ACCENT_ENABLE_ACRYLICBLURBEHIND 保持失焦状态下的真模糊。
        ApplyAcrylicAccent();
        _backdropApplied = true;
    }

    private void ApplyAcrylicAccent()
    {
        // 使用 ACCENT_ENABLE_ACRYLICBLURBEHIND (4) 搭配极低白雾浓度（约 13%），
        // 在保持失焦不退化的前提下大幅提高透光率，使底层软件文字与色彩能柔焦透出。
        var accent = new AccentPolicy
        {
            AccentState = 4, // ACCENT_ENABLE_ACRYLICBLURBEHIND
            AccentFlags = 0,
            GradientColor = unchecked((int)0x22FFFFFF),
            AnimationId = 0
        };
        var size = Marshal.SizeOf(accent);
        var ptr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(accent, ptr, false);
            var data = new WindowCompositionAttributeData
            {
                Attribute = 19,
                SizeOfData = size,
                Data = ptr
            };
            if (!SetWindowCompositionAttribute(_hwnd, ref data))
            {
                accent.AccentState = 3; // ACCENT_ENABLE_BLURBEHIND
                accent.GradientColor = 0;
                Marshal.StructureToPtr(accent, ptr, false);
                SetWindowCompositionAttribute(_hwnd, ref data);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(ptr);
        }
    }

    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaWindowCornerPreference = 33;
    private const int DwmwaBorderColor = 34;
    private const int DwmwaSystemBackdropType = 38;

    [StructLayout(LayoutKind.Sequential)]
    private struct AccentPolicy
    {
        public int AccentState;
        public int AccentFlags;
        public int GradientColor;
        public int AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowCompositionAttributeData
    {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Margins
    {
        public int Left;
        public int Right;
        public int Top;
        public int Bottom;
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    [DllImport("dwmapi.dll")]
    private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);

    [DllImport("user32.dll")]
    private static extern bool SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);
}
