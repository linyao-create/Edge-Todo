using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace EdgeTodo;

public sealed record MonitorInfo(string Device, int Left, int Top, int Right, int Bottom, uint Dpi, bool IsLeftSeam = false)
{
    public int Height => Bottom - Top;
}

public static class Monitors
{
    /**
     * 枚举全部可用显示器工作区、DPI 以及左边缘是否紧邻另一块屏幕（用于跨屏接缝防误触）。
     * @returns {List<MonitorInfo>} 显示器信息列表
     */
    public static List<MonitorInfo> All()
    {
        var raw = new List<(string Device, Native.Rect Work, ScreenBounds Physical, uint Dpi)>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (hmon, _, _, _) =>
        {
            var info = new Native.MonitorInfoEx { cbSize = Marshal.SizeOf<Native.MonitorInfoEx>() };
            if (!Native.GetMonitorInfo(hmon, ref info)) return true;
            uint dpi = 96;
            try { Native.GetDpiForMonitor(hmon, 0, out dpi, out _); } catch { dpi = 96; }
            if (dpi == 0) dpi = 96;
            var physical = new ScreenBounds(info.Monitor.Left, info.Monitor.Top, info.Monitor.Right, info.Monitor.Bottom);
            raw.Add((info.DeviceName, info.Work, physical, dpi));
            return true;
        }, IntPtr.Zero);

        var allBounds = raw.Select(item => item.Physical).ToArray();
        return raw.Select(item => new MonitorInfo(
            item.Device,
            item.Work.Left,
            item.Work.Top,
            item.Work.Right,
            item.Work.Bottom,
            item.Dpi,
            EdgeSeamDetector.HasLeftNeighbor(item.Physical, allBounds))).ToList();
    }

    public static string DeviceUnderCursor()
    {
        Native.GetCursorPos(out var point);
        var monitor = Native.MonitorFromPoint(point, 2);
        var info = new Native.MonitorInfoEx { cbSize = Marshal.SizeOf<Native.MonitorInfoEx>() };
        return Native.GetMonitorInfo(monitor, ref info) ? info.DeviceName : "";
    }
}

/**
 * 用户级浏览器协议注册辅助类，支持独立测试协议名并保护已有旧版可执行文件与绑定目录不被测试副本覆盖。
 */
public static class ProtocolRegistration
{
    /**
     * 安全尝试读取指定协议在当前 Windows 合并视图（HKCU 优先，HKLM 兜底）下的启动命令行。
     * @param {string} scheme 协议名称（例如 edgetodo）
     * @param {out string?} command 成功读取时返回命令行文本，未注册则为 null
     * @returns {bool} 注册表读取是否成功
     */
    public static bool TryGetRegisteredCommand(string scheme, out string? command)
    {
        command = null;
        if (!TryReadCommandFromHive(Registry.CurrentUser, scheme, out var hkcuFound, out var hkcuCommand))
            return false;
        if (hkcuFound)
        {
            command = hkcuCommand;
            return true;
        }

        if (!TryReadCommandFromHive(Registry.LocalMachine, scheme, out var hklmFound, out var hklmCommand))
            return false;
        if (hklmFound)
        {
            command = hklmCommand;
        }
        return true;
    }

    private static bool TryReadCommandFromHive(RegistryKey hive, string scheme, out bool hasCommand, out string? command)
    {
        hasCommand = false;
        command = null;
        try
        {
            using var key = hive.OpenSubKey($@"Software\Classes\{scheme}\shell\open\command");
            if (key is null) return true;
            var raw = key.GetValue("");
            if (raw is null) return true;
            if (raw is string text)
            {
                if (!string.IsNullOrWhiteSpace(text))
                {
                    hasCommand = true;
                    command = text;
                }
                return true;
            }
            return false;
        }
        catch
        {
            return false;
        }
    }

    /**
     * 读取指定协议在当前用户注册表中的启动命令行。
     * @param {string} scheme 协议名称（例如 edgetodo）
     * @returns {string?} 命令行文本，未注册或读取失败则返回 null
     */
    public static string? GetRegisteredCommand(string scheme) =>
        TryGetRegisteredCommand(scheme, out var cmd) ? cmd : null;

    /**
     * 从注册表命令行文本中提取可执行文件绝对路径。
     * @param {string?} command 注册表命令行内容
     * @returns {string?} 解析出的可执行文件路径
     */
    public static string? ExtractExecutablePath(string? command) =>
        ProtocolRegistrationPolicy.ParseCommand(command).ExecutablePath;

    /**
     * 按安全策略确保协议指向本应用（不会覆盖指向其他现存旧版程序或不同绑定目录的主协议，除非显式允许）。
     * @param {string} scheme 协议名
     * @param {string} dataDirectory 当前实例实际使用的规范化数据目录
     * @param {bool?} forceRegister 显式开关：false 绝不写入，true 强制写入，null 自动保护旧版
     * @param {string?} configuredDataDirectory 若已配置独立数据目录则写入 --data-dir 启动参数
     */
    public static void Ensure(string scheme, string dataDirectory, bool? forceRegister, string? configuredDataDirectory)
    {
        if (forceRegister == false) return;

        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe)) return;
        var normalizedExe = Path.GetFullPath(exe);

        if (forceRegister != true)
        {
            var readOk = TryGetRegisteredCommand(scheme, out var existingCmd);
            if (ProtocolRegistrationPolicy.ShouldPreserveExisting(!readOk, existingCmd, normalizedExe, dataDirectory))
                return;
        }

        var argsPart = string.IsNullOrWhiteSpace(configuredDataDirectory)
            ? "\"%1\""
            : $"--data-dir \"{AppPaths.NormalizeDirectory(configuredDataDirectory)}\" \"%1\"";
        var commandText = $"\"{normalizedExe}\" {argsPart}";
        var keyPath = $@"Software\Classes\{scheme}";
        const string commandPath = @"shell\open\command";
        using (var existingKey = Registry.CurrentUser.OpenSubKey(keyPath))
        using (var existingCommand = existingKey?.OpenSubKey(commandPath))
        {
            if (existingKey?.GetValue("") is not null && existingKey.GetValue("URL Protocol") is not null &&
                string.Equals(existingCommand?.GetValue("") as string, commandText, StringComparison.Ordinal))
                return;
        }

        using var key = Registry.CurrentUser.CreateSubKey(keyPath);
        if (key.GetValue("") is null) key.SetValue("", "URL:一角");
        if (key.GetValue("URL Protocol") is null) key.SetValue("URL Protocol", "");
        using var command = key.CreateSubKey(commandPath);
        if (!string.Equals(command.GetValue("") as string, commandText, StringComparison.Ordinal))
            command.SetValue("", commandText);
    }
}

/**
 * 基于规范化物理数据目录隔离的单实例互斥锁与命名管道服务，限制仅当前用户访问并支持优雅退出。
 */
public static class SingleInstance
{
    private static readonly TimeSpan IoTimeout = TimeSpan.FromSeconds(3);
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);
    private static Mutex? _mutex;
    private static CancellationTokenSource? _listenCts;

    /**
     * 尝试成为指定数据目录的主实例；若同目录已有实例运行，则将剩余参数转发过去。
     * @param {string} dataDirectory 当前实例的数据目录
     * @param {string[]} forwardArgs 需转发给已运行同目录实例的参数
     * @returns {bool} 是否成功作为主实例继续启动
     */
    public static bool BecomePrimary(string dataDirectory, string[] forwardArgs)
    {
        var mutexName = EdgeTodoClient.MutexNameFor(dataDirectory);
        var candidate = new Mutex(false, mutexName);
        bool acquired;
        try
        {
            acquired = candidate.WaitOne(0, false);
        }
        catch (AbandonedMutexException)
        {
            acquired = true;
        }

        if (acquired)
        {
            _mutex = candidate;
            return true;
        }

        candidate.Dispose();
        Notify(dataDirectory, string.Join('\n', forwardArgs));
        return false;
    }

    /**
     * 在专属命名管道上监听来自同目录 CLI 或副实例的请求，强校验当前用户、数据目录与消息大小超时；绝不释放主实例锁。
     * @param {string} dataDirectory 当前实例的数据目录
     * @param {Func<string, string>} onLine 校验通过后的处理函数
     */
    public static void Listen(string dataDirectory, Func<string, string> onLine)
    {
        StopListening();
        _listenCts = new CancellationTokenSource();
        var token = _listenCts.Token;
        var thread = new Thread(() => ListenLoop(dataDirectory, onLine, token))
        {
            IsBackground = true,
            Name = "EdgeTodo.Activation"
        };
        thread.Start();
    }

    /**
     * 仅停止命名管道监听线程（保留主实例互斥锁直到应用退出）。
     */
    public static void StopListening()
    {
        try { _listenCts?.Cancel(); } catch { }
        _listenCts?.Dispose();
        _listenCts = null;
    }

    /**
     * 释放并销毁主实例防双开互斥锁，仅应在桌面应用退出时调用。
     */
    public static void ReleasePrimary()
    {
        if (_mutex is not null)
        {
            try { _mutex.ReleaseMutex(); } catch { }
            _mutex.Dispose();
            _mutex = null;
        }
    }

    /**
     * 查询指定数据目录的运行中桌面实例。
     * @param {string} dataDirectory 目标数据目录
     * @param {string} line 请求载荷
     * @returns {string?} 实例返回值或 null
     */
    public static string? Query(string dataDirectory, string line) => EdgeTodoClient.Query(dataDirectory, line);

    private static void ListenLoop(string dataDirectory, Func<string, string> onLine, CancellationToken shutdownToken)
    {
        var pipeName = EdgeTodoClient.PipeNameFor(dataDirectory);
        while (!shutdownToken.IsCancellationRequested)
        {
            try
            {
                using var pipe = new NamedPipeServerStream(
                    pipeName,
                    PipeDirection.InOut,
                    1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                pipe.WaitForConnectionAsync(shutdownToken).GetAwaiter().GetResult();

                using var ioCts = CancellationTokenSource.CreateLinkedTokenSource(shutdownToken);
                ioCts.CancelAfter(IoTimeout);
                var line = EdgeTodoClient.ReadBoundedLineAsync(pipe, ioCts.Token).GetAwaiter().GetResult();
                if (string.IsNullOrWhiteSpace(line)) continue;

                var response = EdgeTodoClient.TryUnwrapRequest(line, dataDirectory, out var payload)
                    ? onLine(payload)
                    : "{\"error\":\"数据目录不匹配\"}";

                using var writer = new StreamWriter(pipe, Utf8NoBom, leaveOpen: true) { AutoFlush = true };
                writer.WriteLineAsync(response.AsMemory(), ioCts.Token).GetAwaiter().GetResult();
                writer.FlushAsync(ioCts.Token).GetAwaiter().GetResult();
            }
            catch (OperationCanceledException) when (shutdownToken.IsCancellationRequested)
            {
                break;
            }
            catch
            {
                if (!shutdownToken.IsCancellationRequested)
                    Thread.Sleep(150);
            }
        }
    }

    private static void Notify(string dataDirectory, string message) =>
        EdgeTodoClient.Notify(dataDirectory, message, IoTimeout);
}

internal static class ConsoleAttach
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    public static void Prepare()
    {
        AttachConsole(-1);
        Console.OutputEncoding = System.Text.Encoding.UTF8;
        try
        {
            var writer = new StreamWriter(Console.OpenStandardOutput(), new System.Text.UTF8Encoding(false)) { AutoFlush = true };
            Console.SetOut(writer);
        }
        catch
        {
        }
    }
}

public static class Tray
{
    public static Forms.NotifyIcon Create(Action show, Action quit)
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("显示待办", null, (_, _) => show());
        menu.Items.Add("退出", null, (_, _) => quit());
        var icon = new Forms.NotifyIcon
        {
            Icon = LoadIcon(),
            Visible = true,
            Text = "一角",
            ContextMenuStrip = menu
        };
        icon.DoubleClick += (_, _) => show();
        return icon;
    }

    private static System.Drawing.Icon LoadIcon()
    {
        var path = Environment.ProcessPath;
        if (!string.IsNullOrEmpty(path))
        {
            try
            {
                var extracted = System.Drawing.Icon.ExtractAssociatedIcon(path);
                if (extracted is not null) return extracted;
            }
            catch (ArgumentException)
            {
            }
        }
        return System.Drawing.SystemIcons.Application;
    }
}

internal static partial class Native
{
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr rect, IntPtr data);

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X, Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MonitorInfoEx
    {
        public int cbSize;
        public Rect Monitor;
        public Rect Work;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
    }

    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfoEx info);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hwnd, int index, int value);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hwnd, int id);

    public const int GwlStyle = -16;
    public const int GwlExStyle = -20;
    public const int WsCaption = 0x00C00000;
    public const int WsThickFrame = 0x00040000;
    public const int WsBorder = 0x00800000;
    public const uint WsPopup = 0x80000000;
    public const int WsExToolWindow = 0x00000080;
    public const int WsExTransparent = 0x00000020;
    public const int WsExNoActivate = 0x08000000;
    public const int HwndTopmost = -1;
    public const uint SwpNoActivate = 0x0010;
    public const uint SwpFrameChanged = 0x0020;
    public const int WmHotkey = 0x0312;
    public const uint ModControl = 0x0002;
    public const uint ModShift = 0x0004;
    public static readonly IntPtr Topmost = new(HwndTopmost);
}
