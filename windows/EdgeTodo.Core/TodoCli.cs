using System.Text.Json;

namespace EdgeTodo;

public static class TodoCli
{
    private static readonly JsonSerializerOptions Json = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    public static bool IsCommand(IReadOnlyList<string> args)
    {
        if (args.Count == 0) return false;
        if (args[0].Contains("://", StringComparison.Ordinal)) return false;
        return args[0] is "list" or "add" or "done" or "undo" or "delete" or "move" or "path" or "help";
    }

    /**
     * 按数据目录调度命令：若同目录桌面端在线则通过隔离管道转发；若通信异常则拒绝盲写；仅确认无人监听时走跨进程锁读写本地文件。
     * @param {string} dataDirectory 目标数据目录
     * @param {IReadOnlyList<string>} args 已剥离选项的业务命令行参数
     * @returns {string} JSON 或帮助输出文本
     */
    public static string Execute(string dataDirectory, IReadOnlyList<string> args)
    {
        var payload = JsonSerializer.Serialize(args);
        var query = EdgeTodoClient.QueryDetailed(dataDirectory, payload);
        return query.Status switch
        {
            PipeQueryStatus.Responded => query.Output ?? Error("桌面端响应为空。"),
            PipeQueryStatus.Failed => Error(query.Error ?? "桌面端正忙或本地通信超时，为避免覆盖数据未直接写盘，请稍后重试。"),
            PipeQueryStatus.NotListening => Run(new TodoStore(Path.Combine(dataDirectory, "todos.json")), args),
            _ => Error("未知本地通信状态。")
        };
    }

    public static string Run(TodoStore store, IReadOnlyList<string> args)
    {
        try
        {
            return args[0] switch
            {
                "list" => List(store),
                "path" => JsonSerializer.Serialize(new { dataDirectory = Path.GetDirectoryName(store.FilePath) }, Json),
                "add" => Add(store, args),
                "done" => SetCompleted(store, args, true),
                "undo" => SetCompleted(store, args, false),
                "delete" => Delete(store, args),
                "move" => Move(store, args),
                _ => Help()
            };
        }
        catch (Exception ex) when (ex is TodoStoreException or FormatException or InvalidOperationException or TimeoutException or IOException or UnauthorizedAccessException or JsonException)
        {
            return Error(ex.Message);
        }
    }

    public static string Help() =>
        """
        Edge Todo 命令：
        list
        path
        add today 内容
        add notes 内容
        done <id>
        undo <id>
        delete <id>
        move <id> today|notes
        """;

    private static string List(TodoStore store)
    {
        var items = store.Load().Select(todo => new
        {
            id = todo.Id,
            category = todo.Category.ToWire(),
            text = todo.Text,
            completed = todo.IsCompleted,
            createdAt = TodoJson.FormatIso(todo.CreatedAt)
        });
        return JsonSerializer.Serialize(new
        {
            dataDirectory = Path.GetDirectoryName(store.FilePath),
            items
        }, Json);
    }

    private static string Add(TodoStore store, IReadOnlyList<string> args)
    {
        if (args.Count < 3) return Error("用法：add today|notes 内容");
        var category = ParseCategory(args[1]) ?? throw new InvalidOperationException("分类要用 today 或 notes。");
        var text = string.Join(' ', args.Skip(2));
        return Item(store.Add(text, category));
    }

    private static string SetCompleted(TodoStore store, IReadOnlyList<string> args, bool completed)
    {
        var id = ParseId(args);
        return Item(store.UpdateCompletion(id, completed));
    }

    private static string Delete(TodoStore store, IReadOnlyList<string> args)
    {
        var id = ParseId(args);
        store.Delete(id);
        return JsonSerializer.Serialize(new { deleted = id }, Json);
    }

    private static string Move(TodoStore store, IReadOnlyList<string> args)
    {
        if (args.Count < 3) return Error("用法：move <id> today|notes");
        var category = ParseCategory(args[2]) ?? throw new InvalidOperationException("分类要用 today 或 notes。");
        return Item(store.Move(ParseId(args), category));
    }

    private static Guid ParseId(IReadOnlyList<string> args)
    {
        if (args.Count < 2 || !Guid.TryParse(args[1], out var id))
            throw new InvalidOperationException("需要一条待办的 id。先运行 list。");
        return id;
    }

    private static TodoCategory? ParseCategory(string value) => value.Trim().ToLowerInvariant() switch
    {
        "today" or "todo" or "待办" or "今日" or "今日待办" => TodoCategory.Today,
        "notes" or "note" or "随记" => TodoCategory.Notes,
        _ => null
    };

    private static string Item(Todo todo) => JsonSerializer.Serialize(new
    {
        id = todo.Id,
        category = todo.Category.ToWire(),
        text = todo.Text,
        completed = todo.IsCompleted
    }, Json);

    public static string Error(string message) => JsonSerializer.Serialize(new { error = message }, Json);
}
