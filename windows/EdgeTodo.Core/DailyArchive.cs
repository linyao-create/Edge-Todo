using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace EdgeTodo;

public sealed class DailyArchiveRecord
{
    /**
     * 构造包含结构化条目的每日归档快照，兼顾表格文本与云文档结构化渲染。
     */
    public DailyArchiveRecord(
        string dateKey,
        string todoText,
        string notesText,
        IReadOnlyList<string> completedItems,
        IReadOnlyList<string> incompleteItems,
        IReadOnlyList<string> deletedItems,
        IReadOnlyList<string> noteItems)
    {
        DateKey = dateKey;
        TodoText = todoText;
        NotesText = notesText;
        CompletedItems = completedItems;
        IncompleteItems = incompleteItems;
        DeletedItems = deletedItems;
        NoteItems = noteItems;
    }

    /**
     * 兼容从已拼接文本构造每日归档快照。
     */
    public DailyArchiveRecord(string dateKey, string todoText, string notesText)
    {
        DateKey = dateKey;
        TodoText = todoText;
        NotesText = notesText;
        var parsedTodos = DailyDocumentArchiveRenderer.LegacySections(todoText);
        CompletedItems = parsedTodos.Completed;
        IncompleteItems = parsedTodos.Incomplete;
        DeletedItems = parsedTodos.Deleted;
        NoteItems = DailyDocumentArchiveRenderer.LegacyParseNotes(notesText);
    }

    public string DateKey { get; }
    public string TodoText { get; }
    public string NotesText { get; }
    public IReadOnlyList<string> CompletedItems { get; }
    public IReadOnlyList<string> IncompleteItems { get; }
    public IReadOnlyList<string> DeletedItems { get; }
    public IReadOnlyList<string> NoteItems { get; }

    public string Fingerprint => Hash(DateKey + "\n" + TodoText + "\n" + NotesText);

    public string FieldJson()
    {
        var body = new JsonObject
        {
            ["今日待办"] = TodoText,
            ["日期"] = DateKey,
            ["随记"] = NotesText
        };
        return body.ToJsonString();
    }

    public static IReadOnlyList<DailyArchiveRecord> Snapshots(IReadOnlyList<Todo> todos, DateTime through)
    {
        var today = Todo.StartOfLocalDay(through);
        var days = new HashSet<DateTime> { today };
        foreach (var todo in todos)
        {
            var createdDay = Todo.StartOfLocalDay(todo.CreatedAt);
            if (createdDay <= today) days.Add(createdDay);
            if (todo.CompletedAt is DateTime completed)
            {
                var completedDay = Todo.StartOfLocalDay(completed);
                if (completedDay <= today) days.Add(completedDay);
            }
            if (todo.IsDeleted)
            {
                var deletedDay = Todo.StartOfLocalDay(todo.DeletedAt ?? todo.CreatedAt);
                if (deletedDay <= today) days.Add(deletedDay);
            }
        }
        return days.OrderBy(day => day).Select(day => Build(todos, day, today, through)).ToArray();
    }

    private static DailyArchiveRecord Build(IReadOnlyList<Todo> todos, DateTime day, DateTime today, DateTime through)
    {
        var completed = new List<string>();
        var incomplete = new List<string>();
        var deleted = new List<string>();
        var notes = new List<string>();
        var completedItems = new List<string>();
        var incompleteItems = new List<string>();
        var deletedItems = new List<string>();
        var noteItems = new List<string>();

        foreach (var todo in todos)
        {
            var createdDay = Todo.StartOfLocalDay(todo.CreatedAt);
            var completionDay = todo.CompletedAt is DateTime done ? Todo.StartOfLocalDay(done) : (DateTime?)null;
            var deletionDay = Todo.StartOfLocalDay(todo.DeletedAt ?? todo.CreatedAt);
            var rawText = todo.ArchiveText.Replace("\r\n", "\n", StringComparison.Ordinal).Trim('\r', '\n');
            if (string.IsNullOrWhiteSpace(rawText)) continue;
            var tableText = rawText.Trim();

            if (todo.Category == TodoCategory.Notes)
            {
                if ((todo.IsDeleted ? deletionDay : createdDay) == day)
                {
                    AddUnique(todo.IsDeleted ? "• [已删除] " + tableText : "• " + tableText, notes);
                    AddUnique(todo.IsDeleted ? "[已删除] " + rawText : rawText, noteItems);
                }
                continue;
            }
            if (todo.IsDeleted)
            {
                if (deletionDay == day)
                {
                    AddUnique("• " + tableText, deleted);
                    AddUnique(rawText, deletedItems);
                }
                else if (createdDay == day)
                {
                    AddUnique("☐ " + tableText, incomplete);
                    AddUnique(rawText, incompleteItems);
                }
                continue;
            }
            if (day == today && todo.IsVisible(through))
            {
                if (todo.IsCompleted)
                {
                    AddUnique("☑ " + tableText, completed);
                    AddUnique(rawText, completedItems);
                }
                else
                {
                    AddUnique("☐ " + tableText, incomplete);
                    AddUnique(rawText, incompleteItems);
                }
            }
            else if (createdDay == day)
            {
                if (completionDay == day)
                {
                    AddUnique("☑ " + tableText, completed);
                    AddUnique(rawText, completedItems);
                }
                else
                {
                    AddUnique("☐ " + tableText, incomplete);
                    AddUnique(rawText, incompleteItems);
                }
            }
            else if (completionDay == day)
            {
                AddUnique("☑ " + tableText, completed);
                AddUnique(rawText, completedItems);
            }
        }
        var sections = new List<string>();
        if (completed.Count > 0) sections.Add("已完成\n" + string.Join('\n', completed));
        if (incomplete.Count > 0) sections.Add("未完成\n" + string.Join('\n', incomplete));
        if (deleted.Count > 0) sections.Add("已删除\n" + string.Join('\n', deleted));
        return new DailyArchiveRecord(
            day.ToString("yyyy-MM-dd"),
            string.Join("\n\n", sections),
            string.Join('\n', notes),
            completedItems,
            incompleteItems,
            deletedItems,
            noteItems);
    }

    private static void AddUnique(string text, List<string> values)
    {
        if (text.Length > 0 && !values.Contains(text)) values.Add(text);
    }

    public static string Hash(string value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant();
}

/**
 * 基于结构化条目渲染飞书云文档每日归档，完整保留正文缩进、空行、项目符号与多行 URL。
 */
public static class DailyDocumentArchiveRenderer
{
    public const string Title = "桌面随手记｜每日归档";
    public const string RenderVersion = "v2";

    /**
     * 从结构化每日归档记录直接渲染飞书云文档内容。
     * @param {IReadOnlyList<DailyArchiveRecord>} records 按日期排列的归档记录
     * @returns {string} 渲染后的飞书文档 XML/标记文本
     */
    public static string Render(IReadOnlyList<DailyArchiveRecord> records)
    {
        var xml = new StringBuilder();
        xml.Append("<title>").Append(Escape(Title)).Append("</title><p>由桌面待办自动维护的历史副本；本机待办是数据来源。</p>");
        foreach (var record in records.OrderBy(item => item.DateKey, StringComparer.Ordinal))
        {
            xml.Append("<h1>").Append(Escape(record.DateKey)).Append("</h1><h2>今日待办</h2>");
            xml.Append(Checkbox("已完成", record.CompletedItems, done: true));
            xml.Append(Checkbox("未完成", record.IncompleteItems, done: false));
            xml.Append("<h3>已删除</h3>");
            if (record.DeletedItems.Count == 0) xml.Append("<p>暂无。</p>");
            else xml.Append("<ul>").Append(string.Join("", record.DeletedItems.Select(item => "<li><del>" + Escape(item) + "</del></li>"))).Append("</ul>");
            xml.Append("<h2>随记</h2>");
            xml.Append(record.NoteItems.Count == 0 ? "<p>暂无。</p>" : "<ul>" + string.Join("", record.NoteItems.Select(item => "<li>" + Escape(item) + "</li>")) + "</ul>");
        }
        return xml.ToString();
    }

    /**
     * 计算渲染版本号与文档输出文本的组合指纹，确保渲染规则升级或任意细节变动触发重写。
     * @param {IReadOnlyList<DailyArchiveRecord>} records 归档记录集合
     * @returns {string} 64 位小写 SHA-256 指纹
     */
    public static string Fingerprint(IReadOnlyList<DailyArchiveRecord> records) =>
        DailyArchiveRecord.Hash(RenderVersion + "\n" + Render(records));

    internal static List<string> LegacyParseNotes(string notesText)
    {
        var items = new List<string>();
        foreach (var rawLine in notesText.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            if (rawLine.StartsWith("• ", StringComparison.Ordinal))
            {
                items.Add(rawLine[2..]);
            }
            else if (items.Count > 0 && rawLine.Trim().Length > 0)
            {
                items[^1] = items[^1] + "\n" + rawLine;
            }
        }
        return items;
    }

    internal static (List<string> Completed, List<string> Incomplete, List<string> Deleted) LegacySections(string value)
    {
        var section = "";
        var completed = new List<string>();
        var incomplete = new List<string>();
        var deleted = new List<string>();
        foreach (var line in value.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.Length == 0) continue;
            if (trimmed is "已完成" or "未完成" or "已删除")
            {
                section = trimmed;
                continue;
            }
            if (trimmed.StartsWith("☑ ", StringComparison.Ordinal))
            {
                section = "已完成";
                completed.Add(trimmed[2..]);
            }
            else if (trimmed.StartsWith("☐ ", StringComparison.Ordinal))
            {
                section = "未完成";
                incomplete.Add(trimmed[2..]);
            }
            else if (trimmed.StartsWith("• ", StringComparison.Ordinal))
            {
                section = "已删除";
                deleted.Add(trimmed[2..]);
            }
            else
            {
                var target = section switch
                {
                    "已完成" => completed,
                    "未完成" => incomplete,
                    "已删除" => deleted,
                    _ => null
                };
                if (target is not null)
                {
                    if (target.Count > 0) target[^1] = target[^1] + "\n" + trimmed;
                    else target.Add(trimmed);
                }
            }
        }
        return (completed, incomplete, deleted);
    }

    private static string Checkbox(string title, IReadOnlyList<string> items, bool done) =>
        "<h3>" + title + "</h3>" + (items.Count == 0 ? "<p>暂无。</p>" : string.Join("", items.Select(item => "<checkbox done=\"" + (done ? "true" : "false") + "\">" + Escape(item) + "</checkbox>")));

    /**
     * 按行转义正文，将行首空格保留为非换行空格实体并将换行转为 &lt;br/&gt;。
     * @param {string} value 原始多行文本
     * @returns {string} 转义后的节点正文
     */
    private static string Escape(string value)
    {
        var lines = value.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            lines[i] = EscapeSingleLine(lines[i]);
        }
        return string.Join("<br/>", lines);
    }

    private static string EscapeSingleLine(string line)
    {
        var leadingSpaces = 0;
        while (leadingSpaces < line.Length && line[leadingSpaces] == ' ') leadingSpaces++;
        var prefix = leadingSpaces > 0 ? string.Concat(Enumerable.Repeat("&#160;", leadingSpaces)) : "";
        var rest = line[leadingSpaces..]
            .Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal);
        return prefix + rest;
    }
}

public interface IDailyArchiveTransport
{
    Task Upsert(DailyArchiveRecord record, CancellationToken cancellation);
}

public interface IDailyDocumentTransport
{
    Task<IReadOnlyList<string>> Update(IReadOnlyList<DailyArchiveRecord> records, CancellationToken cancellation);
}

public interface ILarkClient
{
    Task<string> Run(IReadOnlyList<string> arguments, string? input, TimeSpan timeout, CancellationToken cancellation, string? workingDirectory = null);
}

public sealed class LarkProcessClient : ILarkClient
{
    private readonly string _cliPath;
    private readonly string _profile;

    public LarkProcessClient(string cliPath, string profile)
    {
        _cliPath = cliPath;
        _profile = profile;
    }

    public async Task<string> Run(IReadOnlyList<string> arguments, string? input, TimeSpan timeout, CancellationToken cancellation, string? workingDirectory = null)
    {
        var start = StartInfo(_cliPath, new[] { "--profile=" + _profile }.Concat(arguments).ToArray());
        if (workingDirectory is not null) start.WorkingDirectory = workingDirectory;
        start.Environment["LARKSUITE_CLI_NO_UPDATE_NOTIFIER"] = "1";
        start.Environment["LARKSUITE_CLI_NO_SKILLS_NOTIFIER"] = "1";
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new ArchiveSyncException("飞书命令没有启动。");
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        linked.CancelAfter(timeout);

        var stdout = process.StandardOutput.ReadToEndAsync(linked.Token);
        var stderr = process.StandardError.ReadToEndAsync(linked.Token);
        try
        {
            if (input is not null)
            {
                await process.StandardInput.WriteAsync(input.AsMemory(), linked.Token);
                await process.StandardInput.FlushAsync(linked.Token);
            }
            process.StandardInput.Close();
            await process.WaitForExitAsync(linked.Token);
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); } catch (Exception) { }
            cancellation.ThrowIfCancellationRequested();
            throw new ArchiveSyncException("飞书命令超时。");
        }
        var output = await stdout;
        var error = await stderr;
        if (process.ExitCode != 0) throw new ArchiveSyncException(ShortError(error));
        return output;
    }

    public static ProcessStartInfo StartInfo(string cliPath, IReadOnlyList<string> arguments)
    {
        var directory = Path.GetDirectoryName(cliPath) ?? "";
        var script = Path.Combine(directory, "node_modules", "@larksuite", "cli", "scripts", "run.js");
        var start = new ProcessStartInfo
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)
        };
        if (File.Exists(script))
        {
            var node = Path.Combine(directory, "node.exe");
            start.FileName = File.Exists(node) ? node : "node";
            start.ArgumentList.Add(script);
        }
        else
        {
            start.FileName = cliPath;
        }
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        return start;
    }

    private static string ShortError(string stderr)
    {
        try
        {
            using var json = JsonDocument.Parse(stderr);
            if (json.RootElement.TryGetProperty("error", out var error) && error.TryGetProperty("message", out var message))
                return message.GetString() ?? "飞书命令失败。";
        }
        catch (JsonException)
        {
        }
        return "飞书命令失败。";
    }
}

public sealed class ArchiveSyncException : Exception
{
    public ArchiveSyncException(string message) : base(message) { }
}

public static class FeishuArchive
{
    public static string? ParseList(string json, string dateKey)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (!OkUser(root)) throw new ArchiveSyncException("飞书返回无法确认。");
        var body = root.GetProperty("data");
        RejectIgnored(root);
        RejectIgnored(body);
        var fields = Strings(body, "fields");
        var fieldIds = Strings(body, "field_id_list");
        var ids = Strings(body, "record_id_list");
        if (fields.Count != 1 || fields[0] != "日期" || fieldIds.Count != 1 || body.GetProperty("has_more").GetBoolean() != false)
            throw new ArchiveSyncException("飞书返回无法确认。");
        if (!body.TryGetProperty("data", out var rows) || rows.ValueKind != JsonValueKind.Array || ids.Count != rows.GetArrayLength() || ids.Count > 1)
            throw new ArchiveSyncException("飞书返回无法确认。");
        if (ids.Count == 0) return null;
        if (!ValidRecord(ids[0]) || rows[0].GetArrayLength() != 1 || rows[0][0].GetString() != dateKey)
            throw new ArchiveSyncException("飞书返回无法确认。");
        return ids[0];
    }

    public static void ValidateWrite(string json, string? existingId)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (!OkUser(root)) throw new ArchiveSyncException("飞书返回无法确认。");
        var body = root.GetProperty("data");
        RejectIgnored(root);
        RejectIgnored(body);
        var flag = existingId is null ? "created" : "updated";
        if (!body.TryGetProperty(flag, out var ok) || ok.ValueKind != JsonValueKind.True || !body.TryGetProperty("record", out var record))
            throw new ArchiveSyncException("飞书返回无法确认。");
        if (existingId is null)
        {
            var ids = Strings(record, "record_id_list");
            if (ids.Count != 1 || !ValidRecord(ids[0])) throw new ArchiveSyncException("飞书返回无法确认。");
        }
        else if (!ValidRecord(existingId) || !record.TryGetProperty("update", out var update) || update.ValueKind != JsonValueKind.Object || !update.EnumerateObject().Any())
        {
            throw new ArchiveSyncException("飞书返回无法确认。");
        }
        if (record.TryGetProperty("ignored_fields", out var ignored) && ignored.GetArrayLength() != 0)
            throw new ArchiveSyncException("飞书返回无法确认。");
    }

    /**
     * 校验飞书云文档更新响应，并提取可能存在的降级警告列表。
     * @param {string} json 飞书命令行返回的 JSON 字符串
     * @returns {IReadOnlyList<string>} 警告提示文本列表（无警告时为空列表）
     */
    public static IReadOnlyList<string> ValidateDocument(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (!OkUser(root) || !root.TryGetProperty("data", out var data) || !data.TryGetProperty("result", out var result) || result.GetString() != "success")
            throw new ArchiveSyncException("飞书返回无法确认。");

        var warnings = new List<string>();
        if (data.TryGetProperty("warnings", out var warningArray) && warningArray.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in warningArray.EnumerateArray())
            {
                var text = ExtractWarningText(item);
                if (!string.IsNullOrWhiteSpace(text)) warnings.Add(text);
            }
        }
        return warnings;
    }

    private static string? ExtractWarningText(JsonElement item)
    {
        if (item.ValueKind == JsonValueKind.String) return item.GetString();
        if (item.ValueKind == JsonValueKind.Object)
        {
            foreach (var key in new[] { "message", "msg", "detail", "warning", "code" })
            {
                if (item.TryGetProperty(key, out var prop) && prop.ValueKind == JsonValueKind.String)
                    return prop.GetString();
            }
            return item.GetRawText();
        }
        return item.ToString();
    }

    public static string? OpenId(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (!root.TryGetProperty("identities", out var identities) || !identities.TryGetProperty("user", out var user)) return null;
        return user.TryGetProperty("openId", out var id) ? id.GetString() : null;
    }

    private static bool OkUser(JsonElement root) =>
        root.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True && root.TryGetProperty("identity", out var identity) && identity.GetString() == "user";

    private static void RejectIgnored(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty("ignored_fields", out var ignored) && ignored.GetArrayLength() != 0)
            throw new ArchiveSyncException("飞书返回无法确认。");
    }

    private static List<string> Strings(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Array) throw new ArchiveSyncException("飞书返回无法确认。");
        return value.EnumerateArray().Select(item => item.GetString() ?? "").ToList();
    }

    private static bool ValidRecord(string id) =>
        id.StartsWith("rec", StringComparison.Ordinal) && id.Length > 3 && id.All(ch => char.IsAsciiLetterOrDigit(ch) || ch == '_');
}

public sealed class FeishuDailyArchiveTransport : IDailyArchiveTransport
{
    private readonly ILarkClient _client;
    private readonly string _baseToken;
    private readonly string _tableId;

    public FeishuDailyArchiveTransport(ILarkClient client, string baseToken, string tableId)
    {
        _client = client;
        _baseToken = baseToken;
        _tableId = tableId;
    }

    public async Task Upsert(DailyArchiveRecord record, CancellationToken cancellation)
    {
        var filter = new JsonObject
        {
            ["conditions"] = new JsonArray(new JsonArray("日期", "==", record.DateKey)),
            ["logic"] = "and"
        };
        var lookup = await _client.Run(Common("+record-list").Concat(["--filter-json", filter.ToJsonString(), "--field-id", "日期", "--limit", "2", "--format", "json"]).ToArray(), null, TimeSpan.FromSeconds(40), cancellation);
        var existing = FeishuArchive.ParseList(lookup, record.DateKey);
        var write = Common("+record-upsert").Concat(["--format", "json"]).ToList();
        if (existing is not null) write.AddRange(["--record-id", existing]);
        const string fileName = "record.json";
        write.AddRange(["--json", "@" + fileName]);
        // lark-cli resolves @file inside its working directory. Keep each request in its own directory.
        var directory = Directory.CreateTempSubdirectory("edgetodo-feishu-");
        var file = Path.Combine(directory.FullName, fileName);
        try
        {
            await File.WriteAllTextAsync(file, record.FieldJson(), cancellation);
            var saved = await _client.Run(write, null, TimeSpan.FromSeconds(40), cancellation, directory.FullName);
            FeishuArchive.ValidateWrite(saved, existing);
        }
        finally
        {
            try
            {
                File.Delete(file);
                directory.Delete();
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private string[] Common(string command) =>
        ["base", command, "--as", "user", "--base-token", _baseToken, "--table-id", _tableId];
}

public sealed class FeishuDailyDocumentTransport : IDailyDocumentTransport
{
    private readonly ILarkClient _client;
    private readonly string _documentId;

    public FeishuDailyDocumentTransport(ILarkClient client, string documentId)
    {
        _client = client;
        _documentId = documentId;
    }

    public async Task<IReadOnlyList<string>> Update(IReadOnlyList<DailyArchiveRecord> records, CancellationToken cancellation)
    {
        var result = await _client.Run(
            ["docs", "+update", "--as", "user", "--doc", _documentId, "--command", "overwrite", "--content", "-"],
            DailyDocumentArchiveRenderer.Render(records),
            TimeSpan.FromSeconds(60),
            cancellation);
        return FeishuArchive.ValidateDocument(result);
    }
}

public sealed class ArchiveSyncCoordinator : IDisposable
{
    private readonly TodoStore _store;
    private readonly string _metadataPath;
    private readonly IDailyArchiveTransport _table;
    private readonly IDailyDocumentTransport? _document;
    private readonly Func<CancellationToken, Task> _validate;
    private readonly Func<DateTime> _now;
    private readonly TimeSpan _retry;
    private readonly TimeSpan _debounceInterval;
    private readonly Action<string>? _statusChanged;
    private readonly Dictionary<string, string> _acknowledgements = [];
    private readonly object _gate = new();
    private CancellationTokenSource? _debounce;
    private CancellationTokenSource? _lifetime;
    private Task? _polling;
    private IReadOnlyList<string> _lastDocumentWarnings = [];
    private int _syncing;
    private int _again;
    private bool _started;

    public ArchiveSyncCoordinator(TodoStore store, string metadataPath, IDailyArchiveTransport table, IDailyDocumentTransport? document, Func<CancellationToken, Task> validate, Func<DateTime>? now = null, TimeSpan? retry = null, TimeSpan? debounce = null, Action<string>? statusChanged = null)
    {
        _store = store;
        _metadataPath = metadataPath;
        _table = table;
        _document = document;
        _validate = validate;
        _now = now ?? (() => DateTime.UtcNow);
        _retry = retry ?? TimeSpan.FromSeconds(30);
        _debounceInterval = debounce ?? TimeSpan.FromMilliseconds(750);
        _statusChanged = statusChanged;
        Status = "正在连接飞书…";
        if (File.Exists(metadataPath))
        {
            try
            {
                var saved = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(metadataPath));
                if (saved is not null)
                {
                    foreach (var pair in saved) _acknowledgements[pair.Key] = pair.Value;
                    if (saved.TryGetValue(DocumentWarningsKey, out var rawWarnings) && !string.IsNullOrWhiteSpace(rawWarnings))
                    {
                        var parsed = JsonSerializer.Deserialize<string[]>(rawWarnings);
                        if (parsed is { Length: > 0 }) _lastDocumentWarnings = parsed;
                    }
                }
            }
            catch (Exception)
            {
                Status = "飞书同步状态损坏，保留本地数据";
            }
        }
    }

    private const string DocumentWarningsKey = "document:v2:warnings";

    public string Status { get; private set; }

    public static string? Warning(string status)
    {
        if (status is "正在连接飞书…" or "已保存到每日档案") return null;
        if (status.Contains("稍后重试", StringComparison.Ordinal)) return "飞书同步稍后重试";
        if (status.Contains("损坏", StringComparison.Ordinal)) return "飞书同步异常";
        return status;
    }

    public void Start()
    {
        lock (_gate)
        {
            if (_started) return;
            _started = true;
            _lifetime = new CancellationTokenSource();
            _store.Changed += OnStoreChanged;
        }
        Schedule();
        var token = _lifetime.Token;
        _polling = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try { await Task.Delay(_retry, token); }
                catch (OperationCanceledException) { return; }
                await SyncNow(token);
            }
        }, token);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _started = false;
            _store.Changed -= OnStoreChanged;
            _debounce?.Cancel();
            _lifetime?.Cancel();
        }
    }

    public async Task SyncNow(CancellationToken cancellation = default)
    {
        if (Interlocked.CompareExchange(ref _syncing, 1, 0) != 0)
        {
            Interlocked.Exchange(ref _again, 1);
            return;
        }
        try
        {
            await SyncBody(cancellation);
        }
        finally
        {
            Interlocked.Exchange(ref _syncing, 0);
            if (Interlocked.Exchange(ref _again, 0) == 1) Schedule();
        }
    }

    private async Task SyncBody(CancellationToken cancellation)
    {
        try
        {
            await _validate(cancellation);
            cancellation.ThrowIfCancellationRequested();
            var rows = DailyArchiveRecord.Snapshots(_store.LoadArchive(), _now());
            if (!rows.Any(row => row.TodoText.Length > 0 || row.NotesText.Length > 0))
            {
                SetStatus("飞书归档已开启，等待本地记录");
                return;
            }
            var failures = new List<string>();
            IReadOnlyList<string> documentWarnings = [];
            try { await SyncTable(rows, cancellation); }
            catch (OperationCanceledException) { throw; }
            catch (Exception) { failures.Add("表格"); }
            if (_document is not null)
            {
                try { documentWarnings = await SyncDocument(rows, cancellation); }
                catch (OperationCanceledException) { throw; }
                catch (Exception) { failures.Add("文档"); }
            }
            if (failures.Count > 0)
            {
                SetStatus("本地已保存，飞书" + string.Join('、', failures) + "稍后重试");
            }
            else if (documentWarnings.Count > 0)
            {
                SetStatus("已保存到每日档案（飞书文档提示：" + string.Join("；", documentWarnings) + "）");
            }
            else
            {
                SetStatus("已保存到每日档案");
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            SetStatus(ex is ArchiveSyncException ? ex.Message : "本地已保存，飞书同步稍后重试");
        }
    }

    private async Task SyncTable(IReadOnlyList<DailyArchiveRecord> rows, CancellationToken cancellation)
    {
        var today = rows[^1].DateKey;
        foreach (var row in rows)
        {
            cancellation.ThrowIfCancellationRequested();
            var key = "daily:v1:" + row.DateKey;
            if (row.DateKey != today && _acknowledgements.ContainsKey(key)) continue;
            if (_acknowledgements.TryGetValue(key, out var saved) && saved == row.Fingerprint) continue;
            await _table.Upsert(row, cancellation);
            cancellation.ThrowIfCancellationRequested();
            var current = DailyArchiveRecord.Snapshots(_store.LoadArchive(), _now()).FirstOrDefault(item => item.DateKey == row.DateKey);
            if (current?.Fingerprint != row.Fingerprint)
            {
                Interlocked.Exchange(ref _again, 1);
                continue;
            }
            Acknowledge(row.Fingerprint, key);
        }
    }

    private async Task<IReadOnlyList<string>> SyncDocument(IReadOnlyList<DailyArchiveRecord> rows, CancellationToken cancellation)
    {
        const string key = "document:v2";
        var fingerprint = DailyDocumentArchiveRenderer.Fingerprint(rows);
        if (_acknowledgements.TryGetValue(key, out var saved) && saved == fingerprint)
            return _lastDocumentWarnings;
        cancellation.ThrowIfCancellationRequested();
        var warnings = await _document!.Update(rows, cancellation);
        cancellation.ThrowIfCancellationRequested();
        _lastDocumentWarnings = warnings.ToArray();
        if (DailyDocumentArchiveRenderer.Fingerprint(DailyArchiveRecord.Snapshots(_store.LoadArchive(), _now())) != fingerprint)
        {
            Interlocked.Exchange(ref _again, 1);
            return warnings;
        }
        AcknowledgeDocument(fingerprint, key, _lastDocumentWarnings);
        return _lastDocumentWarnings;
    }

    private void AcknowledgeDocument(string fingerprint, string key, IReadOnlyList<string> warnings)
    {
        lock (_gate)
        {
            _acknowledgements[key] = fingerprint;
            if (warnings.Count > 0)
                _acknowledgements[DocumentWarningsKey] = JsonSerializer.Serialize(warnings);
            else
                _acknowledgements.Remove(DocumentWarningsKey);
            AtomicFile.WriteAllText(_metadataPath, JsonSerializer.Serialize(_acknowledgements));
        }
    }

    private void OnStoreChanged() => Schedule();

    private void Schedule()
    {
        CancellationToken token;
        lock (_gate)
        {
            if (!_started) return;
            _debounce?.Cancel();
            _debounce = CancellationTokenSource.CreateLinkedTokenSource(_lifetime?.Token ?? CancellationToken.None);
            token = _debounce.Token;
        }
        _ = RunDebounce(token);
    }

    private async Task RunDebounce(CancellationToken token)
    {
        try { await Task.Delay(_debounceInterval, token); }
        catch (OperationCanceledException) { return; }
        if (Volatile.Read(ref _syncing) == 1)
        {
            Interlocked.Exchange(ref _again, 1);
            return;
        }
        await SyncNow(token);
    }

    private void Acknowledge(string fingerprint, string key)
    {
        lock (_gate)
        {
            _acknowledgements[key] = fingerprint;
            AtomicFile.WriteAllText(_metadataPath, JsonSerializer.Serialize(_acknowledgements));
        }
    }

    private void SetStatus(string status)
    {
        Status = status;
        _statusChanged?.Invoke(status);
    }

    public static ArchiveSyncCoordinator? TryStart(TodoStore store, string dataDirectory, Action<string>? statusChanged)
    {
        if (!ArchiveSettings.TryLoad(dataDirectory, out var settings, out var settingsError))
        {
            statusChanged?.Invoke(settingsError ?? "飞书配置异常，已保留本地数据");
            return null;
        }
        if (settings is null || string.IsNullOrWhiteSpace(settings.AccountID) || string.IsNullOrWhiteSpace(settings.CliPath) || string.IsNullOrWhiteSpace(settings.Profile)) return null;
        if (!ArchiveLinks.TryDestination(settings.Table, settings.Document, out var baseToken, out var tableId, out var documentId, out var destError))
        {
            statusChanged?.Invoke(string.IsNullOrWhiteSpace(destError) ? "飞书配置链接无效，已保留本地数据" : destError);
            return null;
        }
        var client = new LarkProcessClient(settings.CliPath, settings.Profile);
        var metadata = MetadataPath(dataDirectory, settings.Profile, settings.AccountID, baseToken, tableId, documentId);
        var sync = new ArchiveSyncCoordinator(store, metadata, new FeishuDailyArchiveTransport(client, baseToken, tableId), new FeishuDailyDocumentTransport(client, documentId), async cancellation =>
        {
            var status = await client.Run(["auth", "status", "--json"], null, TimeSpan.FromSeconds(40), cancellation);
            if (FeishuArchive.OpenId(status) != settings.AccountID) throw new ArchiveSyncException("飞书登录账号已变化，请在设置里重新检查并开启归档。");
        }, statusChanged: statusChanged);
        sync.Start();
        return sync;
    }

    public static string MetadataPath(string directory, string profile, string accountId, string baseToken, string tableId, string documentId)
    {
        var key = string.Join('\n', [profile, accountId, baseToken, tableId, documentId]);
        return Path.Combine(directory, "feishu-sync", DailyArchiveRecord.Hash(key) + ".json");
    }
}
