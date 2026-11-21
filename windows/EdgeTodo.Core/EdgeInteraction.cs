namespace EdgeTodo;

public enum EdgePanelState
{
    Collapsed,
    Expanded
}

public interface IEdgeScheduler
{
    IDisposable Schedule(TimeSpan delay, Action action);
}

public sealed class EdgeInteractionController
{
    private readonly IEdgeScheduler _scheduler;
    private readonly TimeSpan _dwell;
    private readonly TimeSpan _collapseDelay = TimeSpan.FromMilliseconds(250);
    private IDisposable? _pendingExpansion;
    private IDisposable? _pendingCollapse;
    private bool _heldOpen;
    private bool _pinned;

    public EdgeInteractionController(IEdgeScheduler scheduler, TimeSpan? dwell = null)
    {
        _scheduler = scheduler;
        _dwell = dwell ?? TimeSpan.FromMilliseconds(180);
    }

    public EdgePanelState State { get; private set; } = EdgePanelState.Collapsed;
    public event Action<EdgePanelState>? StateChanged;

    public void PointerEntered()
    {
        Cancel(ref _pendingCollapse);
        if (State == EdgePanelState.Expanded) return;
        Cancel(ref _pendingExpansion);
        _pendingExpansion = _scheduler.Schedule(_dwell, () =>
        {
            _pendingExpansion = null;
            State = EdgePanelState.Expanded;
            StateChanged?.Invoke(State);
        });
    }

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

    public void PointerExited()
    {
        Cancel(ref _pendingExpansion);
        if (State != EdgePanelState.Expanded || _heldOpen || _pinned) return;
        Cancel(ref _pendingCollapse);
        _pendingCollapse = _scheduler.Schedule(_collapseDelay, () =>
        {
            _pendingCollapse = null;
            State = EdgePanelState.Collapsed;
            StateChanged?.Invoke(State);
        });
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
