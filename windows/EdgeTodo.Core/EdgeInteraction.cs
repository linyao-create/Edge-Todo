namespace EdgeTodo;

public enum EdgePanelState
{
    Collapsed,
    Expanded
}

/**
 * 显示器的物理屏幕矩形边界，用于识别多屏拼接时的内侧接缝边。
 */
public readonly record struct ScreenBounds(int Left, int Top, int Right, int Bottom);

/**
 * 边缘面板交互默认时序与防误触参数。
 */
public static class EdgeInteractionDefaults
{
    public static readonly TimeSpan OuterDwell = TimeSpan.FromMilliseconds(220);
    public static readonly TimeSpan SeamDwell = TimeSpan.FromMilliseconds(450);
    public static readonly TimeSpan CollapseDelay = TimeSpan.FromMilliseconds(380);
    public const double SeamMaxDriftDip = 6.0;
    public const double CardExitBufferDip = 8.0;
}

/**
 * 多显示器接缝检测工具，判断某块屏幕左边缘是否紧邻另一块显示器（用于降低跨屏滑动误触发展开）。
 */
public static class EdgeSeamDetector
{
    /**
     * 判断目标显示器的左边缘是否与另一块显示器的右边缘相邻且纵向重叠。
     * @param {ScreenBounds} target 待判断的目标显示器物理边界
     * @param {IReadOnlyList<ScreenBounds>} allScreens 全部显示器物理边界列表
     * @returns {bool} true 表示左边缘处于多屏接缝处；false 表示屏幕最外侧物理边
     */
    public static bool HasLeftNeighbor(ScreenBounds target, IReadOnlyList<ScreenBounds> allScreens)
    {
        foreach (var other in allScreens)
        {
            if (other == target) continue;
            var touchesLeftEdge = Math.Abs(other.Right - target.Left) <= 2;
            var overlapsVertically = other.Bottom > target.Top && other.Top < target.Bottom;
            if (touchesLeftEdge && overlapsVertically) return true;
        }
        return false;
    }
}

public interface IEdgeScheduler
{
    IDisposable Schedule(TimeSpan delay, Action action);
}

/**
 * 边缘悬浮面板的展开/收起状态机，支持展开前与收起前二次条件核实，防止跨屏滑过误展开或编辑中误收起。
 */
public sealed class EdgeInteractionController
{
    private readonly IEdgeScheduler _scheduler;
    private readonly TimeSpan _dwell;
    private readonly TimeSpan _collapseDelay;
    private readonly Func<bool>? _canExpand;
    private readonly Func<bool>? _canCollapse;
    private IDisposable? _pendingExpansion;
    private IDisposable? _pendingCollapse;
    private bool _heldOpen;
    private bool _pinned;

    /**
     * 初始化边缘面板交互状态机。
     * @param {IEdgeScheduler} scheduler 延时调度器
     * @param {TimeSpan?} dwell 悬停展开所需停留时长
     * @param {TimeSpan?} collapseDelay 离开后收起延时（默认 380ms）
     * @param {Func<bool>?} canExpand 定时到期展开前的二次核实回调（返回 false 时取消展开）
     * @param {Func<bool>?} canCollapse 定时到期收起前的二次核实回调（返回 false 时取消收起）
     */
    public EdgeInteractionController(
        IEdgeScheduler scheduler,
        TimeSpan? dwell = null,
        TimeSpan? collapseDelay = null,
        Func<bool>? canExpand = null,
        Func<bool>? canCollapse = null)
    {
        _scheduler = scheduler;
        _dwell = dwell ?? TimeSpan.FromMilliseconds(180);
        _collapseDelay = collapseDelay ?? EdgeInteractionDefaults.CollapseDelay;
        _canExpand = canExpand;
        _canCollapse = canCollapse;
    }

    public EdgePanelState State { get; private set; } = EdgePanelState.Collapsed;
    public bool IsExpansionPending => _pendingExpansion is not null;
    public bool IsCollapsePending => _pendingCollapse is not null;
    public event Action<EdgePanelState>? StateChanged;

    /**
     * 指针进入触发把手或卡片区域：取消待执行的收起任务；收起态下重新排期悬停展开。
     */
    public void PointerEntered()
    {
        Cancel(ref _pendingCollapse);
        if (State == EdgePanelState.Expanded) return;
        Cancel(ref _pendingExpansion);
        _pendingExpansion = _scheduler.Schedule(_dwell, () =>
        {
            _pendingExpansion = null;
            if (_canExpand is not null && !_canExpand()) return;
            State = EdgePanelState.Expanded;
            StateChanged?.Invoke(State);
        });
    }

    /**
     * 立即展开面板（用于点击把手、快捷键、托盘或浏览器收藏唤起）。
     */
    public void Reveal()
    {
        Cancel(ref _pendingExpansion);
        Cancel(ref _pendingCollapse);
        State = EdgePanelState.Expanded;
        StateChanged?.Invoke(State);
    }

    public void SetHeldOpen(bool heldOpen)
    {
        _heldOpen = heldOpen;
        if (heldOpen) Cancel(ref _pendingCollapse);
    }

    public void SetPinned(bool pinned)
    {
        _pinned = pinned;
        if (pinned) Cancel(ref _pendingCollapse);
    }

    /**
     * 指针离开把手或卡片区域：取消待展开计时；展开态下若未在倒计时则排期延迟收起（重复调用不会重置已有倒计时）。
     */
    public void PointerExited()
    {
        Cancel(ref _pendingExpansion);
        if (State != EdgePanelState.Expanded || _heldOpen || _pinned) return;
        if (_pendingCollapse is not null) return;
        _pendingCollapse = _scheduler.Schedule(_collapseDelay, () =>
        {
            _pendingCollapse = null;
            if (_heldOpen || _pinned || (_canCollapse is not null && !_canCollapse())) return;
            State = EdgePanelState.Collapsed;
            StateChanged?.Invoke(State);
        });
    }

    /**
     * 未固定且未被弹窗/拖拽锁定时立即收起面板（例如用户点击面板外部窗口导致失活）。
     */
    public void CollapseImmediately()
    {
        Cancel(ref _pendingExpansion);
        Cancel(ref _pendingCollapse);
        if (State != EdgePanelState.Expanded || _heldOpen || _pinned) return;
        State = EdgePanelState.Collapsed;
        StateChanged?.Invoke(State);
    }

    public void CancelAll()
    {
        Cancel(ref _pendingExpansion);
        Cancel(ref _pendingCollapse);
        _heldOpen = false;
        State = EdgePanelState.Collapsed;
        StateChanged?.Invoke(State);
    }

    private static void Cancel(ref IDisposable? ticket)
    {
        ticket?.Dispose();
        ticket = null;
    }
}

public sealed class DispatchEdgeScheduler : IEdgeScheduler
{
    public IDisposable Schedule(TimeSpan delay, Action action)
    {
        var source = new CancellationTokenSource();
        _ = Run(delay, action, source.Token);
        return source;
    }

    private static async Task Run(TimeSpan delay, Action action, CancellationToken token)
    {
        try
        {
            await Task.Delay(delay, token);
            if (!token.IsCancellationRequested) action();
        }
        catch (TaskCanceledException)
        {
        }
    }
}
