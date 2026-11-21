using System.Windows.Media;
using System.Windows.Shapes;

namespace EdgeTodo;

/**
 * 面板矢量线框图标工厂，所有图标均使用统一圆角线帽与矢量路径，避免位图模糊。
 */
internal static class Marks
{
    /**
     * 创建统一样式的矢量描边图形。
     * @param {string} data SVG 路径几何数据
     * @param {Brush} brush 线条颜色画刷
     * @param {double} size 渲染宽高尺寸
     * @param {double} thickness 线条粗细
     * @param {Stretch} stretch 缩放拉伸模式
     * @returns {Path} WPF 矢量路径控件
     */
    public static Path Stroke(string data, Brush brush, double size, double thickness = 1.4, Stretch stretch = Stretch.Uniform) => new()
    {
        Data = Geometry.Parse(data),
        Stroke = brush,
        StrokeThickness = thickness,
        StrokeStartLineCap = PenLineCap.Round,
        StrokeEndLineCap = PenLineCap.Round,
        StrokeLineJoin = PenLineJoin.Round,
        Width = size,
        Height = size,
        Stretch = stretch,
        SnapsToDevicePixels = true
    };

    /**
     * 竖直极简平顶图钉图标（对齐原版 Mac 面板右上角图钉形态）。
     * @param {Brush} brush 线条颜色
     * @returns {Path} 图钉图标路径
     */
    public static Path Pin(Brush brush) => Stroke(
        "M5.2,2.8 H10.8 M6.2,2.8 L5.6,8.4 M9.8,2.8 L10.4,8.4 M3.8,8.4 H12.2 M8,8.4 V13.6",
        brush, 15, 1.35, Stretch.Uniform);

    /**
     * 清晰比例的极简线框垃圾桶图标，避免小尺寸下竖线糊连。
     * @param {Brush} brush 线条颜色
     * @returns {Path} 垃圾桶图标路径
     */
    public static Path Trash(Brush brush) => Stroke(
        "M3.0,4.5 H13.0 M5.6,4.5 V3.0 H10.4 V4.5 M4.4,4.5 L5.1,13.0 H10.9 L11.6,4.5 M6.8,7.0 V10.8 M9.2,7.0 V10.8",
        brush, 13.5, 1.25, Stretch.Uniform);

    /**
     * 每日档案笔记本图标，按原版 20x20 坐标绘制。
     * @param {Brush} brush 线条颜色
     * @returns {Path} 笔记本图标路径
     */
    public static Path Notebook(Brush brush) => Stroke(
        "M6.5,2.8 H15.5 A1.3,1.3 0 0 1 16.8,4.1 V15.9 A1.3,1.3 0 0 1 15.5,17.2 H6.5 A1.3,1.3 0 0 1 5.2,15.9 V4.1 A1.3,1.3 0 0 1 6.5,2.8 Z M12.8,2.8 V17.2 M12.8,6.4 H16.8 M12.8,10 H16.8 M12.8,13.6 H16.8 M3.5,5.2 H6.3 M3.5,8.4 H6.3 M3.5,11.6 H6.3 M3.5,14.8 H6.3",
        brush, 17, 1.4, Stretch.Uniform);

    /**
     * 倒计时状态图标（进行中、暂停、已到时）。
     * @param {Brush} brush 线条颜色
     * @param {CountdownStatus?} status 倒计时当前状态
     * @returns {Path} 闹钟/状态图标路径
     */
    public static Path Clock(Brush brush, CountdownStatus? status)
    {
        var paused = status == CountdownStatus.Paused;
        var data = paused
            ? "M7.2,5.2 V14.8 M12.8,5.2 V14.8"
            : status == CountdownStatus.Expired
                ? "M8,1.8 H12 M10,7 V10.8 M10,13.5 H10.01 M10,10.5 m -6.5,0 a 6.5,6.5 0 1 0 13,0 a 6.5,6.5 0 1 0 -13,0"
                : "M8,1.8 H12 M10,7 V10.8 L12.7,12.3 M10,10.5 m -6.5,0 a 6.5,6.5 0 1 0 13,0 a 6.5,6.5 0 1 0 -13,0";
        return Stroke(data, brush, 14, paused ? 1.9 : 1.35, Stretch.Uniform);
    }

    /**
     * 待办完成复选框内部的精致白色对勾。
     * @param {Brush} brush 对勾颜色
     * @returns {Path} 对勾路径
     */
    public static Path Checkmark(Brush brush) => Stroke(
        "M2.2,5.4 L4.4,7.6 L8.6,2.8",
        brush, 9.5, 1.6, Stretch.Uniform);

    /**
     * 倒计时自定义页面返回图标。
     * @param {Brush} brush 线条颜色
     * @returns {Path} 左箭头路径
     */
    public static Path ArrowLeft(Brush brush) => Stroke(
        "M10.5,6.0 H2.5 M5.8,2.8 L2.5,6.0 L5.8,9.2",
        brush, 11, 1.35, Stretch.Uniform);
}
