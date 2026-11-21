using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Markup;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace EdgeTodo;

/**
 * 极简悬浮细滚动条工厂，复刻原版 Mac 4px 透明轨道紫灰胶囊滚动条，不挤占内容区宽度。
 */
internal static class SlimScrollViewer
{
    private const string ScrollViewerTemplateXaml = """
        <ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                         xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
                         TargetType="{x:Type ScrollViewer}">
            <Grid Background="Transparent">
                <ScrollContentPresenter x:Name="PART_ScrollContentPresenter"
                                        CanContentScroll="{TemplateBinding CanContentScroll}"
                                        Margin="{TemplateBinding Padding}" />
                <ScrollBar x:Name="PART_VerticalScrollBar"
                           HorizontalAlignment="Right"
                           Width="8"
                           Margin="0,2,1,2"
                           Orientation="Vertical"
                           Maximum="{TemplateBinding ScrollableHeight}"
                           ViewportSize="{TemplateBinding ViewportHeight}"
                           Value="{Binding VerticalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"
                           Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}">
                    <ScrollBar.Template>
                        <ControlTemplate TargetType="{x:Type ScrollBar}">
                            <Grid Background="Transparent">
                                <Track x:Name="PART_Track" IsDirectionReversed="True">
                                    <Track.DecreaseRepeatButton>
                                        <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" IsHitTestVisible="False" />
                                    </Track.DecreaseRepeatButton>
                                    <Track.IncreaseRepeatButton>
                                        <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" IsHitTestVisible="False" />
                                    </Track.IncreaseRepeatButton>
                                    <Track.Thumb>
                                        <Thumb>
                                            <Thumb.Template>
                                                <ControlTemplate TargetType="{x:Type Thumb}">
                                                    <Grid Background="Transparent">
                                                        <Border Width="4"
                                                                HorizontalAlignment="Right"
                                                                Margin="0,0,1,0"
                                                                CornerRadius="2"
                                                                Background="#FFBBB8CA" />
                                                    </Grid>
                                                </ControlTemplate>
                                            </Thumb.Template>
                                        </Thumb>
                                    </Track.Thumb>
                                </Track>
                            </Grid>
                        </ControlTemplate>
                    </ScrollBar.Template>
                </ScrollBar>
            </Grid>
        </ControlTemplate>
        """;

    /**
     * 创建一个带悬浮细滚动条的 ScrollViewer。
     * @param {UIElement} content 滚动区域内部承载的列表控件
     * @param {Action?} onScrolled 用户滚动内容时的回调（可用于自动关闭浮层菜单）
     * @returns {ScrollViewer} 配置好极简滚动条模板的 ScrollViewer
     */
    public static ScrollViewer Create(UIElement content, Action? onScrolled = null)
    {
        var viewer = new ScrollViewer
        {
            Content = content,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            CanContentScroll = false,
            PanningMode = PanningMode.VerticalOnly,
            Focusable = false,
            Template = (ControlTemplate)XamlReader.Parse(ScrollViewerTemplateXaml)
        };

        var hideTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
        ScrollBar? verticalBar = null;

        void SetBarVisible(bool visible, int durationMs)
        {
            if (verticalBar is null) return;
            var anim = new DoubleAnimation(visible ? 0.95 : 0, TimeSpan.FromMilliseconds(durationMs))
            {
                EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }
            };
            verticalBar.BeginAnimation(UIElement.OpacityProperty, anim);
        }

        viewer.Loaded += (_, _) =>
        {
            verticalBar = viewer.Template.FindName("PART_VerticalScrollBar", viewer) as ScrollBar;
            if (verticalBar is not null) verticalBar.Opacity = 0;
        };

        hideTimer.Tick += (_, _) =>
        {
            hideTimer.Stop();
            if (!viewer.IsMouseOver) SetBarVisible(false, 220);
        };

        viewer.MouseEnter += (_, _) =>
        {
            hideTimer.Stop();
            SetBarVisible(true, 140);
        };

        viewer.MouseLeave += (_, _) =>
        {
            hideTimer.Stop();
            hideTimer.Start();
        };

        viewer.ScrollChanged += (_, e) =>
        {
            if (Math.Abs(e.VerticalChange) > 0.1)
            {
                onScrolled?.Invoke();
                SetBarVisible(true, 100);
                hideTimer.Stop();
                hideTimer.Start();
            }
        };

        return viewer;
    }
}
