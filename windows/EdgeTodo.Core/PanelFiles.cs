using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace EdgeTodo;

public sealed class PanelSelectionStore
{
    private readonly string _filePath;
    private SelectionFile _file;

    public PanelSelectionStore(string dataDirectory)
    {
        _filePath = Path.Combine(dataDirectory, "settings.json");
        if (File.Exists(_filePath))
        {
            try
            {
                _file = JsonSerializer.Deserialize<SelectionFile>(File.ReadAllText(_filePath), TodoJson.SettingsOptions) ?? new SelectionFile();
            }
            catch
            {
                _file = new SelectionFile();
            }
        }
        else
        {
            _file = new SelectionFile();
        }
    }

    public TodoCategory Category => TodoCategories.FromWire(_file.LastCategory);

    public bool IsPinned(string displayId) => _file.PinnedDisplays.Contains(displayId);

    public void SetPinned(bool pinned, string displayId)
    {
        _file.PinnedDisplays.Remove(displayId);
        if (pinned) _file.PinnedDisplays.Add(displayId);
        Save();
    }

    public void Select(TodoCategory category)
    {
        _file.LastCategory = category.ToWire();
        Save();
    }

    private void Save() =>
        AtomicFile.WriteAllText(_filePath, JsonSerializer.Serialize(_file, TodoJson.SettingsOptions));

}

/**
 * 提供带唯一临时文件与失败清理机制的原子文件写入助手，避免并发写入或残余临时文件冲突。
 */
internal static class AtomicFile
{
    /**
     * 将文本内容以独立进程/随机临时文件写出后原子替换目标文件。
     * @param {string} filePath 目标文件路径
     * @param {string} content 要写入的文本内容
     */
    public static void WriteAllText(string filePath, string content)
    {
        var directory = Path.GetDirectoryName(filePath);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        var temporary = $"{filePath}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporary, content);
            File.Move(temporary, filePath, overwrite: true);
        }
        catch
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); } catch { }
            throw;
        }
    }
}

/**
 * 基于规范化物理数据目录的跨进程、跨 Windows 会话独占文件锁助手，串行化对同一目录数据的读改写操作。
 */
internal static class DataDirectoryLock
{
    private static readonly TimeSpan DefaultWait = TimeSpan.FromSeconds(10);
    private static readonly ConcurrentDictionary<string, object> InProcessGates = new(StringComparer.OrdinalIgnoreCase);

    /**
     * 在指定数据目录的独占锁保护下执行临界区逻辑（同时覆盖同进程多线程与跨会话多进程）。
     * @param {string} directory 数据目录路径
     * @param {Func<T>} action 临界区执行回调
     * @returns {T} 回调返回值
     */
    public static T Execute<T>(string directory, Func<T> action)
    {
        var lockDir = string.IsNullOrWhiteSpace(directory)
            ? AppPaths.DefaultDataDirectory()
            : AppPaths.NormalizeDirectory(directory);
        var gate = InProcessGates.GetOrAdd(lockDir, static _ => new object());
        lock (gate)
        {
            Directory.CreateDirectory(lockDir);
            var lockFilePath = Path.Combine(lockDir, ".edgetodo.lock");
            var deadline = Environment.TickCount64 + (long)DefaultWait.TotalMilliseconds;
            FileStream stream;
            while (true)
            {
                try
                {
                    stream = new FileStream(lockFilePath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
                    break;
                }
                catch (IOException) when (Environment.TickCount64 < deadline)
                {
                    Thread.Sleep(15);
                }
                catch (IOException ex)
                {
                    throw new InvalidOperationException("数据目录正被另一操作占用，请稍后重试。", ex);
                }
            }

            using (stream)
            {
                return action();
            }
        }
    }

    /**
     * 在指定数据目录对应的跨进程互斥锁保护下执行无返回值操作。
     * @param {string} directory 数据目录路径
     * @param {Action} action 临界区执行回调
     */
    public static void Execute(string directory, Action action) =>
        Execute<object?>(directory, () => { action(); return null; });
}

internal sealed class SelectionFile
{
    public string LastCategory { get; set; } = "today";
    public List<string> PinnedDisplays { get; set; } = [];
}

public sealed class ArchiveSettings
{
    public string Table { get; set; } = "";
    public string Document { get; set; } = "";
    public string Profile { get; set; } = "";
    public string CliPath { get; set; } = "";
    public string AccountID { get; set; } = "";

    public const string FileName = "feishu-settings.json";

    public static ArchiveSettings? Load(string dataDirectory)
    {
        var path = Path.Combine(dataDirectory, FileName);
        string raw;
        try
        {
            raw = File.ReadAllText(path);
        }
        catch (FileNotFoundException)
        {
            return null;
        }
        catch (DirectoryNotFoundException)
        {
            return null;
        }
        return JsonSerializer.Deserialize<ArchiveSettings>(raw, TodoJson.SettingsOptions);
    }

    /**
     * 安全尝试读取飞书同步配置，区分「未配置」与「配置文件损坏或不可读」。
     * @param {string} dataDirectory 数据目录路径
     * @param {out ArchiveSettings?} settings 成功时返回配置实例，未配置时为 null
     * @param {out string?} error 读取失败或 JSON 损坏时返回中文原因
     * @returns {bool} 是否正常（未配置也视为正常并开启默认关闭状态）
     */
    public static bool TryLoad(string dataDirectory, out ArchiveSettings? settings, out string? error)
    {
        var path = Path.Combine(dataDirectory, FileName);
        string raw;
        try
        {
            raw = File.ReadAllText(path);
        }
        catch (FileNotFoundException)
        {
            settings = null;
            error = null;
            return true;
        }
        catch (DirectoryNotFoundException)
        {
            settings = null;
            error = null;
            return true;
        }
        catch (Exception ex)
        {
            settings = null;
            error = "飞书配置文件无法读取，已保留本地数据：" + ex.Message;
            return false;
        }
        try
        {
            var loaded = JsonSerializer.Deserialize<ArchiveSettings>(raw, TodoJson.SettingsOptions);
            if (loaded is null)
            {
                settings = null;
                error = "飞书配置文件内容为空或格式无效，已保留本地数据。";
                return false;
            }
            settings = loaded;
            error = null;
            return true;
        }
        catch (Exception ex)
        {
            settings = null;
            error = "飞书配置文件损坏，已保留本地数据：" + ex.Message;
            return false;
        }
    }
}

public static class ArchiveLinks
{
    public static bool TryTableUrl(string table, string document, out Uri tableUrl, out string error)
    {
        tableUrl = null!;
        if (!TryParts(table, "base", out var tableUri, out var token, out error)) return false;
        if (!TryParts(document, "docx", out _, out _, out error)) return false;
        var query = ParseQuery(tableUri.Query).Where(item => item.Name == "table").ToArray();
        if (query.Length != 1 || query[0].Value is not string tableId || !tableId.StartsWith("tbl", StringComparison.Ordinal) || !ValidId(tableId))
        {
            error = "飞书表格链接无法识别。";
            return false;
        }
        if (!ValidId(token))
        {
            error = "飞书表格链接无法识别。";
            return false;
        }
        tableUrl = tableUri;
        error = "";
        return true;
    }

    public static bool TryDestination(string table, string document, out string baseToken, out string tableId, out string documentId, out string error)
    {
        baseToken = "";
        tableId = "";
        documentId = "";
        if (!TryParts(table, "base", out var tableUri, out baseToken, out error)) return false;
        if (!TryParts(document, "docx", out _, out documentId, out error)) return false;
        var query = ParseQuery(tableUri.Query).Where(item => item.Name == "table").ToArray();
        if (query.Length != 1 || query[0].Value is not string id || !id.StartsWith("tbl", StringComparison.Ordinal) || !ValidId(id) || !ValidId(baseToken))
        {
            error = "飞书表格链接无法识别。";
            return false;
        }
        tableId = id;
        error = "";
        return true;
    }

    private static bool TryParts(string value, string kind, out Uri uri, out string id, out string error)
    {
        uri = null!;
        id = "";
        error = kind == "base" ? "飞书表格链接无法识别。" : "飞书文档链接无法识别。";
        var trimmed = value.Trim();
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var parsed)) return false;
        if (!parsed.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)) return false;
        var host = parsed.Host.ToLowerInvariant();
        if (host != "feishu.cn" && !host.EndsWith(".feishu.cn", StringComparison.Ordinal)) return false;
        if (!string.IsNullOrEmpty(parsed.UserInfo) || !parsed.IsDefaultPort) return false;
        var path = parsed.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (path.Length != 2 || path[0] != kind || !ValidId(path[1])) return false;
        uri = parsed;
        id = path[1];
        error = "";
        return true;
    }

    private static bool ValidId(string value) =>
        value.Length > 0 && value.All(ch => char.IsAsciiLetterOrDigit(ch));

    private static List<(string Name, string? Value)> ParseQuery(string query)
    {
        var items = new List<(string, string?)>();
        if (string.IsNullOrEmpty(query)) return items;
        var body = query.TrimStart('?');
        foreach (var part in body.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var split = part.IndexOf('=');
            var name = Uri.UnescapeDataString(split < 0 ? part : part[..split]);
            var value = split < 0 ? null : Uri.UnescapeDataString(part[(split + 1)..]);
            items.Add((name, value));
        }
        return items;
    }
}

/**
 * 启动配置、命令行参数或环境变量存在错误时抛出的异常，阻止回退到默认数据目录。
 */
public sealed class LaunchConfigException(string message) : Exception(message);

/**
 * 应用启动配置（位于可执行程序同目录的 edgetodo-config.json），用于将独立副本绑定到专属数据目录与测试协议。
 */
public sealed class AppLaunchConfig
{
    public const string FileName = "edgetodo-config.json";
    public const string PendingFileName = "edgetodo-config.json.pending";

    public string? DataDirectory { get; set; }
    public string? ProtocolScheme { get; set; }
    public bool? RegisterProtocol { get; set; }

    /**
     * 读取指定程序目录下的启动配置，遵循「有疑问就停下」原则：
     * 先检查目录可访问性与配置状态标记，若存在进行中标记（edgetodo-config.json.pending）或目录无法检查则立即停止；
     * 主配置缺失且无任何残留配置产物（.tmp/.bak 等）时才返回 null（目录完全干净视为未配置）；
     * 主配置缺失但检测到残留产物、权限受限、同名目录占坑、JSON 损坏或缺少有效 dataDirectory 时一律抛出 LaunchConfigException。
     * 主配置有效且无进行中标记时，允许目录中留存历史 .tmp/.bak 文件。
     * @param {string?} appBaseDirectory 程序所在目录
     * @returns {AppLaunchConfig?} 若目录干净且无配置则返回 null，合法则返回配置实例
     */
    public static AppLaunchConfig? Load(string? appBaseDirectory = null)
    {
        var baseDir = string.IsNullOrWhiteSpace(appBaseDirectory) ? AppContext.BaseDirectory : appBaseDirectory;
        var (pending, firstArtifact) = InspectArtifacts(baseDir);
        if (pending)
            throw new LaunchConfigException($"检测到上次配置未完成（{PendingFileName}），为避免误用默认目录已停止启动；请重新运行 configure-data-dir.ps1。");

        var path = Path.Combine(baseDir, FileName);
        string raw;
        try
        {
            raw = File.ReadAllText(path);
        }
        catch (FileNotFoundException)
        {
            if (firstArtifact is not null)
                throw new LaunchConfigException($"未找到主配置但检测到残留配置文件（{firstArtifact}），上次配置可能未完成，为避免误用默认目录已停止启动；请恢复备份或重新运行配置脚本。");
            return null;
        }
        catch (Exception ex)
        {
            throw new LaunchConfigException($"启动配置 {FileName} 无法读取，为避免误用默认目录已停止启动：{ex.Message}");
        }

        AppLaunchConfig? config;
        try
        {
            config = JsonSerializer.Deserialize<AppLaunchConfig>(raw, TodoJson.SettingsOptions);
        }
        catch (Exception ex)
        {
            throw new LaunchConfigException($"启动配置 {FileName} 损坏或无法解析，为避免误用默认目录已停止启动：{ex.Message}");
        }
        if (config is null)
            throw new LaunchConfigException($"启动配置 {FileName} 内容无效，为避免误用默认目录已停止启动。");
        if (string.IsNullOrWhiteSpace(config.DataDirectory))
            throw new LaunchConfigException($"启动配置 {FileName} 缺少有效的 dataDirectory，为避免误用默认目录已停止启动。");
        if (config.ProtocolScheme is not null && !AppPaths.IsValidSchemeValue(config.ProtocolScheme))
            throw new LaunchConfigException($"启动配置 {FileName} 中的 protocolScheme 不合法。");
        return config;
    }

    /**
     * 检查程序目录中的配置进行中标记与配置相关残留文件（edgetodo-config.json.*）。
     * 避免通配符 8.3 短文件名匹配偏差，直接在枚举结果中精确按前缀过滤。
     * @param {string} baseDir 程序所在目录
     * @returns {(bool Pending, string? FirstArtifact)} 是否存在配置进行中标记，及首个非标记残留文件名
     */
    private static (bool Pending, string? FirstArtifact) InspectArtifacts(string baseDir)
    {
        List<string?> entries;
        try
        {
            entries = Directory.EnumerateFileSystemEntries(baseDir).Select(Path.GetFileName).ToList();
        }
        catch (Exception ex)
        {
            throw new LaunchConfigException($"无法检查程序目录中的启动配置状态，为避免误用默认目录已停止启动：{ex.Message}");
        }

        var prefix = FileName + ".";
        var pending = false;
        string? firstArtifact = null;
        foreach (var name in entries)
        {
            if (string.IsNullOrEmpty(name)) continue;
            if (!name.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
            if (name.Equals(PendingFileName, StringComparison.OrdinalIgnoreCase))
                pending = true;
            else
                firstArtifact ??= name;
        }
        return (pending, firstArtifact);
    }
}

/**
 * 命令行参数解析结果，拆分出隔离配置参数与实际业务参数。
 */
public sealed record ParsedLaunchArguments(
    string? DataDirectory,
    string? ProtocolScheme,
    bool? RegisterProtocol,
    string[] RemainingArgs);

/**
 * 协议注册表命令行解析结果，包含可执行路径与绑定的数据目录（如有）。
 */
public sealed record ProtocolCommandInfo(string? ExecutablePath, string? DataDirectory);

/**
 * 浏览器协议防覆盖保护策略，结合程序路径与绑定数据目录判断能否安全接管协议入口。
 */
public static class ProtocolRegistrationPolicy
{
    /**
     * 从注册表命令行字符串中解析出可执行文件路径及 --data-dir 绑定目录。
     * @param {string?} command 注册表 (default) 命令行字符串
     * @returns {ProtocolCommandInfo} 解析出的程序路径与可选数据目录
     */
    public static ProtocolCommandInfo ParseCommand(string? command)
    {
        if (string.IsNullOrWhiteSpace(command))
            return new ProtocolCommandInfo(null, null);

        var tokens = SplitCommandTokens(command);
        if (tokens.Count == 0 || string.IsNullOrWhiteSpace(tokens[0]))
            return new ProtocolCommandInfo(null, null);

        var exe = tokens[0];
        string? dataDir = null;
        for (var i = 1; i < tokens.Count; i++)
        {
            var token = tokens[i];
            if (token.Equals("--data-dir", StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 < tokens.Count && !string.IsNullOrWhiteSpace(tokens[i + 1]) && tokens[i + 1] != "%1")
                    dataDir = tokens[++i];
            }
            else if (token.StartsWith("--data-dir=", StringComparison.OrdinalIgnoreCase))
            {
                var value = token["--data-dir=".Length..];
                if (!string.IsNullOrWhiteSpace(value) && value != "%1")
                    dataDir = value;
            }
        }

        return new ProtocolCommandInfo(exe, dataDir);
    }

    /**
     * 判断在未强制覆盖时是否必须保留现有注册表协议命令。
     * @param {bool} readFailed 是否读取注册表失败
     * @param {string?} existingCommand 现有注册表命令文本
     * @param {string} currentExePath 当前启动的程序路径
     * @param {string} currentDataDirectory 当前实例解析出的数据目录
     * @param {Func<string, bool>?} fileExists 文件存在性检查回调（测试可注入）
     * @param {string?} defaultDataDirectory 默认数据目录覆盖值（测试可注入）
     * @returns {bool} true 表示应保留原有入口不得覆盖；false 表示可以写入当前入口
     */
    public static bool ShouldPreserveExisting(
        bool readFailed,
        string? existingCommand,
        string currentExePath,
        string currentDataDirectory,
        Func<string, bool>? fileExists = null,
        string? defaultDataDirectory = null)
    {
        if (readFailed) return true;
        if (string.IsNullOrWhiteSpace(existingCommand)) return false;

        var info = ParseCommand(existingCommand);
        if (string.IsNullOrWhiteSpace(info.ExecutablePath)) return true;

        string normalizedExistingExe;
        string normalizedCurrentExe;
        string normalizedCurrentData;
        try
        {
            normalizedExistingExe = Path.GetFullPath(info.ExecutablePath.Trim());
            normalizedCurrentExe = Path.GetFullPath(currentExePath.Trim());
            normalizedCurrentData = AppPaths.NormalizeDirectory(currentDataDirectory);
        }
        catch
        {
            return true;
        }

        var checkExists = fileExists ?? File.Exists;
        if (!string.Equals(normalizedExistingExe, normalizedCurrentExe, StringComparison.OrdinalIgnoreCase))
            return checkExists(normalizedExistingExe);

        string existingBoundData;
        try
        {
            if (!string.IsNullOrWhiteSpace(info.DataDirectory))
            {
                existingBoundData = AppPaths.NormalizeDirectory(info.DataDirectory);
            }
            else
            {
                var exeDir = Path.GetDirectoryName(normalizedExistingExe);
                var config = !string.IsNullOrWhiteSpace(exeDir) && (fileExists is null || Directory.Exists(exeDir))
                    ? AppLaunchConfig.Load(exeDir)
                    : null;
                if (!string.IsNullOrWhiteSpace(config?.DataDirectory))
                {
                    var combined = Path.IsPathRooted(config.DataDirectory.Trim())
                        ? config.DataDirectory.Trim()
                        : Path.Combine(exeDir!, config.DataDirectory.Trim());
                    existingBoundData = AppPaths.NormalizeDirectory(combined);
                }
                else
                {
                    existingBoundData = AppPaths.NormalizeDirectory(defaultDataDirectory ?? AppPaths.DefaultDataDirectory());
                }
            }
        }
        catch
        {
            return true;
        }

        return !string.Equals(existingBoundData, normalizedCurrentData, StringComparison.OrdinalIgnoreCase);
    }

    private static List<string> SplitCommandTokens(string command)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        var inQuotes = false;
        var hasToken = false;

        foreach (var ch in command)
        {
            if (ch == '"')
            {
                inQuotes = !inQuotes;
                hasToken = true;
                continue;
            }
            if (char.IsWhiteSpace(ch) && !inQuotes)
            {
                if (hasToken)
                {
                    tokens.Add(current.ToString());
                    current.Clear();
                    hasToken = false;
                }
                continue;
            }
            current.Append(ch);
            hasToken = true;
        }
        if (hasToken) tokens.Add(current.ToString());
        return tokens;
    }
}

/**
 * 负责数据目录解析、规范化、跨进程隔离键及启动参数解析。
 */
public static class AppPaths
{
    /**
     * 返回系统默认数据目录（%LOCALAPPDATA%\EdgeTodo）。
     * @returns {string} 规范化后的默认目录绝对路径
     */
    public static string DefaultDataDirectory() =>
        NormalizeDirectory(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "EdgeTodo"));

    /**
     * 规范化目录路径（解析目录联接/符号链接为物理目录、保留根目录斜杠并移除普通末尾分隔符）。
     * @param {string} path 原始目录路径
     * @returns {string} 规范化后的真实物理绝对路径
     */
    public static string NormalizeDirectory(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new LaunchConfigException("数据目录路径不能为空。");

        var full = Path.GetFullPath(path.Trim());
        full = ResolveLinkSegments(full);
        var root = Path.GetPathRoot(full) ?? "";
        if (full.Length > root.Length)
            full = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return full;
    }

    private static string ResolveLinkSegments(string fullPath)
    {
        var root = Path.GetPathRoot(fullPath);
        if (string.IsNullOrEmpty(root)) return fullPath;

        var relative = fullPath[root.Length..];
        var parts = relative.Split([Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar], StringSplitOptions.RemoveEmptyEntries);
        var current = root;

        foreach (var part in parts)
        {
            current = Path.Combine(current, part);
            if (!Directory.Exists(current)) continue;
            try
            {
                var target = new DirectoryInfo(current).ResolveLinkTarget(returnFinalTarget: true);
                if (target is not null && !string.IsNullOrWhiteSpace(target.FullName))
                    current = Path.GetFullPath(target.FullName);
            }
            catch
            {
            }
        }
        return current;
    }

    /**
     * 基于规范化后的数据目录生成 16 位稳定哈希标识，用于隔离互斥锁与命名管道。
     * @param {string} dataDirectory 数据目录路径
     * @returns {string} 16 位小写十六进制哈希字符串
     */
    public static string DirectoryKey(string dataDirectory)
    {
        var normalized = NormalizeDirectory(dataDirectory).ToLowerInvariant();
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
        return Convert.ToHexString(hash)[..16].ToLowerInvariant();
    }

    /**
     * 解析命令行中携带的目录隔离与协议参数，并剥离后保留剩余业务参数；传参错误时抛出 LaunchConfigException。
     * @param {IReadOnlyList<string>} args 原始命令行参数列表
     * @returns {ParsedLaunchArguments} 解析后的配置与剩余参数
     */
    public static ParsedLaunchArguments ParseArguments(IReadOnlyList<string> args)
    {
        string? dataDir = null;
        string? scheme = null;
        bool? registerProtocol = null;
        var remaining = new List<string>(args.Count);

        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];
            if (arg.Equals("--data-dir", StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 >= args.Count || string.IsNullOrWhiteSpace(args[i + 1]) || args[i + 1].StartsWith("--", StringComparison.Ordinal))
                    throw new LaunchConfigException("参数 --data-dir 必须指定有效的数据目录路径。");
                dataDir = args[++i];
                continue;
            }
            if (arg.StartsWith("--data-dir=", StringComparison.OrdinalIgnoreCase))
            {
                var value = arg["--data-dir=".Length..];
                if (string.IsNullOrWhiteSpace(value))
                    throw new LaunchConfigException("参数 --data-dir 必须指定有效的数据目录路径。");
                dataDir = value;
                continue;
            }
            if (arg.Equals("--protocol-scheme", StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 >= args.Count || string.IsNullOrWhiteSpace(args[i + 1]) || args[i + 1].StartsWith("--", StringComparison.Ordinal) || !IsValidSchemeValue(args[i + 1]))
                    throw new LaunchConfigException("参数 --protocol-scheme 必须指定合法的协议名称。");
                scheme = args[++i];
                continue;
            }
            if (arg.StartsWith("--protocol-scheme=", StringComparison.OrdinalIgnoreCase))
            {
                var value = arg["--protocol-scheme=".Length..];
                if (!IsValidSchemeValue(value))
                    throw new LaunchConfigException("参数 --protocol-scheme 必须指定合法的协议名称。");
                scheme = value;
                continue;
            }
            if (arg.Equals("--register-protocol", StringComparison.OrdinalIgnoreCase))
            {
                if (registerProtocol == false)
                    throw new LaunchConfigException("不能同时指定 --register-protocol 和 --no-register-protocol。");
                registerProtocol = true;
                continue;
            }
            if (arg.Equals("--no-register-protocol", StringComparison.OrdinalIgnoreCase))
            {
                if (registerProtocol == true)
                    throw new LaunchConfigException("不能同时指定 --register-protocol 和 --no-register-protocol。");
                registerProtocol = false;
                continue;
            }
            remaining.Add(arg);
        }

        return new ParsedLaunchArguments(dataDir, scheme, registerProtocol, remaining.ToArray());
    }

    /**
     * 解析当前默认数据目录（优先环境变量，否则使用 %LOCALAPPDATA%\EdgeTodo）。
     * @returns {string} 规范化后的数据目录路径
     */
    public static string DataDirectory() => ResolveDataDirectory();

    /**
     * 按优先级解析最终使用的数据目录：显式参数 -> 环境变量 -> edgetodo-config.json -> 默认目录。
     * @param {string?} explicitDir 命令行显式指定的数据目录
     * @param {string?} appBaseDir 程序所在基目录
     * @returns {string} 规范化后的绝对路径
     */
    public static string ResolveDataDirectory(string? explicitDir = null, string? appBaseDir = null)
    {
        var configured = ResolveConfiguredDataDirectory(explicitDir, appBaseDir);
        return configured ?? DefaultDataDirectory();
    }

    /**
     * 若显式指定了独立数据目录（命令行、环境变量或配置），返回其规范化路径；未配置时返回 null，配置损坏或为空则抛异常。
     * @param {string?} explicitDir 命令行显式指定的数据目录
     * @param {string?} appBaseDir 程序所在基目录
     * @returns {string?} 独立配置的数据目录绝对路径，或 null
     */
    public static string? ResolveConfiguredDataDirectory(string? explicitDir = null, string? appBaseDir = null)
    {
        if (explicitDir is not null)
            return NormalizeDirectory(explicitDir);

        var envDir = Environment.GetEnvironmentVariable("EDGE_TODO_DATA_DIRECTORY");
        if (envDir is not null)
            return NormalizeDirectory(envDir);

        var baseDir = string.IsNullOrWhiteSpace(appBaseDir) ? AppContext.BaseDirectory : appBaseDir;
        var config = AppLaunchConfig.Load(baseDir);
        if (config?.DataDirectory is not null)
        {
            var raw = config.DataDirectory.Trim();
            var combined = Path.IsPathRooted(raw) ? raw : Path.Combine(baseDir, raw);
            return NormalizeDirectory(combined);
        }

        return null;
    }

    /**
     * 按优先级解析本实例使用的浏览器协议名称：显式参数 -> 环境变量 -> edgetodo-config.json -> "edgetodo"。
     * @param {string?} explicitScheme 命令行显式指定的协议名称
     * @param {string?} appBaseDir 程序所在基目录
     * @returns {string} 合法的小写协议名
     */
    public static string ResolveProtocolScheme(string? explicitScheme = null, string? appBaseDir = null)
    {
        if (explicitScheme is not null)
        {
            if (!IsValidSchemeValue(explicitScheme))
                throw new LaunchConfigException("指定的协议名称不合法。");
            return explicitScheme.Trim().ToLowerInvariant();
        }

        var env = Environment.GetEnvironmentVariable("EDGE_TODO_PROTOCOL_SCHEME");
        if (env is not null)
        {
            if (!IsValidSchemeValue(env))
                throw new LaunchConfigException("环境变量 EDGE_TODO_PROTOCOL_SCHEME 指定的协议名称不合法。");
            return env.Trim().ToLowerInvariant();
        }

        var config = AppLaunchConfig.Load(appBaseDir);
        if (config?.ProtocolScheme is not null)
            return config.ProtocolScheme.Trim().ToLowerInvariant();

        return BrowserCapture.Scheme;
    }

    /**
     * 解析是否允许向系统注册表写入协议处理配置：
     * 仅当次命令行明确传参可触发强制接管（true）；隔离副本配置文件的禁用设置（false）优先于任何环境变量；
     * 继承来的环境变量永不允许把普通启动提升为强制接管。
     * @param {bool?} explicitRegister 当次命令行显式开关
     * @param {string?} appBaseDir 程序所在基目录
     * @returns {bool?} true 仅限当次明确接管，false 禁止注册，null 按防覆盖保护策略自动判断
     */
    public static bool? ResolveRegisterProtocol(bool? explicitRegister = null, string? appBaseDir = null)
    {
        if (explicitRegister is not null) return explicitRegister;
        var configured = AppLaunchConfig.Load(appBaseDir)?.RegisterProtocol;
        if (configured == false) return false;
        var env = Environment.GetEnvironmentVariable("EDGE_TODO_REGISTER_PROTOCOL");
        if (env is not null)
        {
            var trimmed = env.Trim();
            if (trimmed.Equals("false", StringComparison.OrdinalIgnoreCase) || trimmed == "0") return false;
            if (!trimmed.Equals("true", StringComparison.OrdinalIgnoreCase) && trimmed != "1")
                throw new LaunchConfigException("环境变量 EDGE_TODO_REGISTER_PROTOCOL 只能是 true/false 或 1/0。");
        }
        return null;
    }

    internal static bool IsValidSchemeValue(string? value)
    {
        var trimmed = (value ?? "").Trim().ToLowerInvariant();
        return trimmed.Length > 0
            && char.IsAsciiLetter(trimmed[0])
            && trimmed.All(ch => char.IsAsciiLetterOrDigit(ch) || ch == '-' || ch == '+' || ch == '.');
    }
}
