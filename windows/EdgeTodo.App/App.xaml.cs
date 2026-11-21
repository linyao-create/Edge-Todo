using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace EdgeTodo;

/**
 * 桌面应用启动入口，按数据目录与协议配置隔离各运行实例。
 */
public partial class App : Application
{
    private PanelHost? _host;
    private Forms.NotifyIcon? _tray;

    private void OnStartup(object sender, StartupEventArgs e)
    {
        DispatcherUnhandledException += (_, args) =>
        {
            args.Handled = true;
            CaptureToast.Show(args.Exception.Message, error: true);
        };

        ParsedLaunchArguments parsed;
        string dataDirectory;
        string? configuredDataDirectory;
        string protocolScheme;
        bool? registerProtocol;
        try
        {
            parsed = AppPaths.ParseArguments(e.Args);
            dataDirectory = AppPaths.ResolveDataDirectory(parsed.DataDirectory);
            configuredDataDirectory = AppPaths.ResolveConfiguredDataDirectory(parsed.DataDirectory);
            protocolScheme = AppPaths.ResolveProtocolScheme(parsed.ProtocolScheme);
            registerProtocol = AppPaths.ResolveRegisterProtocol(parsed.RegisterProtocol);
        }
        catch (LaunchConfigException ex)
        {
            if (e.Args.Any(arg => TodoCli.IsCommand([arg])))
            {
                ConsoleAttach.Prepare();
                Console.WriteLine(TodoCli.Error(ex.Message));
            }
            else
            {
                MessageBox.Show(ex.Message, "一角配置错误", MessageBoxButton.OK, MessageBoxImage.Error);
            }
            Shutdown(1);
            return;
        }

        if (TodoCli.IsCommand(parsed.RemainingArgs))
        {
            ConsoleAttach.Prepare();
            var output = TodoCli.Execute(dataDirectory, parsed.RemainingArgs);
            Console.WriteLine(output);
            Shutdown(output.Contains("\"error\"", StringComparison.Ordinal) ? 1 : 0);
            return;
        }

        if (!SingleInstance.BecomePrimary(dataDirectory, parsed.RemainingArgs))
        {
            Shutdown();
            return;
        }

        ProtocolRegistration.Ensure(protocolScheme, dataDirectory, registerProtocol, configuredDataDirectory);
        _host = new PanelHost(dataDirectory, protocolScheme);
        _host.Start();
        _tray = Tray.Create(() => Dispatcher.Invoke(() => _host.Reveal(null)), () => Dispatcher.Invoke(Shutdown));
        SingleInstance.Listen(dataDirectory, line => Dispatcher.Invoke(() => _host.HandleLine(line)));
        if (parsed.RemainingArgs.Length > 0) _host.Handle(string.Join('\n', parsed.RemainingArgs));
        SystemEvents.DisplaySettingsChanged += (_, _) => Dispatcher.Invoke(_host.Restart);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        SingleInstance.StopListening();
        SingleInstance.ReleasePrimary();
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        _host?.Dispose();
        base.OnExit(e);
    }
}

/**
 * 面板窗口与本地数据、倒计时及飞书同步协调器。
 */
public sealed class PanelHost : IDisposable
{
    private readonly string _dataDirectory;
    private readonly string _protocolScheme;
    private readonly List<PanelWindow> _windows = [];
    private readonly DispatcherTimer _clock;
    private ArchiveSyncCoordinator? _archive;
    private string? _archiveWarning;
    public TodoStore Store { get; }
    public CountdownManager Countdowns { get; }
    public PanelSelectionStore Selection { get; }

    /**
     * 为指定数据目录与协议名初始化面板协调器。
     * @param {string?} dataDirectory 隔离的数据目录路径，为 null 时按默认解析规则确定
     * @param {string?} protocolScheme 绑定的协议名，默认 edgetodo
     */
    public PanelHost(string? dataDirectory = null, string? protocolScheme = null)
    {
        _dataDirectory = AppPaths.NormalizeDirectory(dataDirectory ?? AppPaths.ResolveDataDirectory());
        _protocolScheme = string.IsNullOrWhiteSpace(protocolScheme) ? BrowserCapture.Scheme : protocolScheme.Trim().ToLowerInvariant();
        Directory.CreateDirectory(_dataDirectory);
        Store = new TodoStore(Path.Combine(_dataDirectory, "todos.json"));
        Countdowns = new CountdownManager(Path.Combine(_dataDirectory, "countdowns.json"));
        Selection = new PanelSelectionStore(_dataDirectory);
        _clock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _clock.Tick += (_, _) =>
        {
            Countdowns.RefreshExpired(DateTime.UtcNow);
            foreach (var window in _windows) window.Tick();
        };
    }

    public void Start()
    {
        Open();
        _clock.Start();
        try
        {
            _archive = ArchiveSyncCoordinator.TryStart(Store, _dataDirectory, status =>
            {
                var warning = ArchiveSyncCoordinator.Warning(status);
                _archiveWarning = warning;
                if (_windows.Count == 0) return;
                _windows[0].Dispatcher.BeginInvoke(() =>
                {
                    foreach (var panel in _windows) panel.SetArchiveWarning(warning);
                });
            });
        }
        catch (Exception ex)
        {
            _archiveWarning = "飞书同步初始化失败，已保留本地数据：" + ex.Message;
            foreach (var panel in _windows) panel.SetArchiveWarning(_archiveWarning);
        }
    }

    public void Restart()
    {
        foreach (var window in _windows) window.Close();
        _windows.Clear();
        Open();
    }

    public void Reveal(Guid? noteId)
    {
        var device = Monitors.DeviceUnderCursor();
        var window = _windows.FirstOrDefault(item => item.Device == device) ?? _windows.FirstOrDefault();
        window?.Reveal(noteId);
    }

    public string HandleLine(string line)
    {
        if (line.StartsWith('['))
        {
            var args = JsonSerializer.Deserialize<string[]>(line) ?? [];
            var output = TodoCli.Run(Store, args);
            Broadcast();
            return output;
        }

        Handle(line);
        return "ok";
    }

    public void Handle(string message)
    {
        foreach (var line in message.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (BrowserCapture.IsReveal(line, _protocolScheme))
            {
                Reveal(null);
                continue;
            }
            if (!BrowserCapture.IsProtocolUri(line, _protocolScheme)) continue;
            try
            {
                BrowserCapture.Receive(Store, line, _protocolScheme);
                foreach (var window in _windows) window.Reload();
                CaptureToast.Show("已存入随记", error: false);
            }
            catch (Exception ex)
            {
                CaptureToast.Show(ex.Message, error: true);
            }
        }
    }

    public void Broadcast()
    {
        foreach (var window in _windows) window.Reload();
    }

    public void Dispose()
    {
        _archive?.Dispose();
        _clock.Stop();
        foreach (var window in _windows) window.Close();
        _windows.Clear();
    }

    private void Open()
    {
        var monitors = Monitors.All();
        if (monitors.Count == 0) return;
        for (var index = 0; index < monitors.Count; index++)
        {
            var window = new PanelWindow(this, monitors[index], ownsHotkey: index == 0);
            _windows.Add(window);
            window.Show();
            window.SetArchiveWarning(_archiveWarning);
        }
    }
}
