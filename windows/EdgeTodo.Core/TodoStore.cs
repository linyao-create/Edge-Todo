using System.Text.Json;

namespace EdgeTodo;

public sealed class TodoStoreException : Exception
{
    public TodoStoreException(string message) : base(message) { }

    public static TodoStoreException EmptyText() => new("内容不能为空");
    public static TodoStoreException NotFound() => new("这条内容已经不存在，可能刚刚被删除");
    public static TodoStoreException NotesLimitReached() => new("随记已满 20 条，整理后可继续添加。");
}

public sealed class TodoStore
{
    public const int NotesLimit = 20;

    public static int NotesCount(IReadOnlyList<Todo> todos) =>
        todos.Count(todo => todo.Category == TodoCategory.Notes && !todo.IsDeleted && !TodoEditing.ShouldDeleteRow(todo.Text));

    private readonly string _filePath;
    private readonly string _lockDirectory;
    private readonly Func<DateTime> _now;
    private readonly Lock _gate = new();

    public TodoStore(string filePath, Func<DateTime>? now = null)
    {
        _filePath = Path.GetFullPath(filePath);
        _lockDirectory = Path.GetDirectoryName(_filePath) ?? AppPaths.DefaultDataDirectory();
        _now = now ?? (() => DateTime.UtcNow);
    }

    public string FilePath => _filePath;
    public string CountdownFilePath => Path.Combine(Path.GetDirectoryName(_filePath) ?? "", "countdowns.json");
    public event Action? Changed;

    /**
     * 在调用方已持有同一数据目录跨进程独占锁的前提下，读取最新未完成今日待办标识集合（不写盘）。
     * 仅在文件或目录不存在时返回空集；读取或反序列化失败时照常抛出异常，避免误删倒计时。
     * @param {string} todosFilePath todos.json 文件绝对路径
     * @returns {HashSet<Guid>} 当前磁盘中所有有效未完成今日待办的 Id 集合
     */
    internal static HashSet<Guid> ReadActiveTodayIdsUnlocked(string todosFilePath)
    {
        string raw;
        try
        {
            raw = File.ReadAllText(todosFilePath);
        }
        catch (FileNotFoundException)
        {
            return [];
        }
        catch (DirectoryNotFoundException)
        {
            return [];
        }
        var todos = JsonSerializer.Deserialize<List<TodoDto>>(raw, TodoJson.TodoOptions)
            ?.Select(dto => dto.ToTodo()) ?? [];
        return todos
            .Where(todo => !todo.IsDeleted && todo.Category == TodoCategory.Today && !todo.IsCompleted)
            .Select(todo => todo.Id)
            .ToHashSet();
    }

    private T ExecuteLocked<T>(Func<T> action)
    {
        lock (_gate)
        {
            return DataDirectoryLock.Execute(_lockDirectory, action);
        }
    }

    private void ExecuteLocked(Action action) =>
        ExecuteLocked<object?>(() => { action(); return null; });

    public IReadOnlyList<Todo> Load() => LoadArchive().Where(todo => !todo.IsDeleted).ToArray();

    public IReadOnlyList<Todo> LoadArchive() => ExecuteLocked(LoadArchiveUnlocked);

    public Todo Add(string text, TodoCategory category = TodoCategory.Today)
    {
        return ExecuteLocked(() =>
        {
            var trimmed = text.Trim();
            if (trimmed.Length == 0) throw TodoStoreException.EmptyText();
            var todos = LoadArchiveUnlocked().ToList();
            var todo = NewTodo(Guid.NewGuid(), trimmed, category);
            todos.Add(todo);
            SaveUnlocked(todos);
            return todo.Copy();
        });
    }

    public Todo ImportNote(Guid id, string text)
    {
        return ExecuteLocked(() =>
        {
            var todos = LoadArchiveUnlocked().ToList();
            var existing = todos.FirstOrDefault(todo => todo.Id == id);
            if (existing is not null) return existing.Copy();
            var trimmed = text.Trim();
            if (trimmed.Length == 0) throw TodoStoreException.EmptyText();
            var note = NewTodo(id, trimmed, TodoCategory.Notes);
            todos.Add(note);
            SaveUnlocked(todos);
            return note.Copy();
        });
    }

    public void Save(IReadOnlyList<Todo> todos) => ExecuteLocked(() => SaveUnlocked(todos));

    public void ReorderActiveToday(IReadOnlyList<Guid> orderedIds)
    {
        ExecuteLocked(() =>
        {
            var all = LoadArchiveUnlocked().ToList();
            var positions = all.Select((todo, index) => (todo, index))
                .Where(pair => !pair.todo.IsDeleted && pair.todo.Category == TodoCategory.Today && !pair.todo.IsCompleted)
                .Select(pair => pair.index)
                .ToArray();
            var current = positions.Select(index => all[index]).ToArray();
            if (orderedIds.Count != current.Length || orderedIds.ToHashSet().SetEquals(current.Select(todo => todo.Id)) == false
                || orderedIds.Distinct().Count() != orderedIds.Count)
            {
                throw TodoStoreException.NotFound();
            }
            var byId = current.ToDictionary(todo => todo.Id);
            for (var i = 0; i < positions.Length; i++) all[positions[i]] = byId[orderedIds[i]];
            SaveUnlocked(all);
        });
    }

    public void Delete(Guid id)
    {
        ExecuteLocked(() =>
        {
            var todos = LoadArchiveUnlocked().ToList();
            var index = todos.FindIndex(todo => todo.Id == id && !todo.IsDeleted);
            if (index < 0) return;
            todos[index].IsDeleted = true;
            todos[index].DeletedAt = _now();
            SaveUnlocked(todos);
        });
    }

    public Todo Update(Guid id, string text)
    {
        return ExecuteLocked(() =>
        {
            var trimmed = text.Trim();
            if (trimmed.Length == 0) throw TodoStoreException.EmptyText();
            var todos = LoadArchiveUnlocked().ToList();
            var index = todos.FindIndex(todo => todo.Id == id && !todo.IsDeleted);
            if (index < 0) throw TodoStoreException.NotFound();
            todos[index].Text = trimmed;
            todos[index].LastNonemptyText = trimmed;
            SaveUnlocked(todos);
            return todos[index].Copy();
        });
    }

    public Todo UpdateCompletion(Guid id, bool isCompleted)
    {
        return ExecuteLocked(() =>
        {
            var todos = LoadArchiveUnlocked().ToList();
            var index = todos.FindIndex(todo => todo.Id == id && !todo.IsDeleted);
            if (index < 0) throw TodoStoreException.NotFound();
            if (todos[index].Category != TodoCategory.Today) return todos[index].Copy();
            if (todos[index].IsCompleted != isCompleted)
                todos[index].CompletedAt = isCompleted ? _now() : null;
            todos[index].IsCompleted = isCompleted;
            SaveUnlocked(todos);
            return todos[index].Copy();
        });
    }

    public Todo SaveDraft(Guid id, string text, TodoCategory category = TodoCategory.Today, bool allowInsert = true, Guid? insertAfter = null)
    {
        return ExecuteLocked(() =>
        {
            var todos = LoadArchiveUnlocked().ToList();
            var index = todos.FindIndex(todo => todo.Id == id);
            if (index >= 0)
            {
                if (todos[index].IsDeleted) throw TodoStoreException.NotFound();
                todos[index].Text = text;
                if (!TodoEditing.ShouldDeleteRow(text)) todos[index].LastNonemptyText = text;
                SaveUnlocked(todos);
                return todos[index].Copy();
            }

            if (!allowInsert) throw TodoStoreException.NotFound();
            if (string.IsNullOrWhiteSpace(text)) throw TodoStoreException.EmptyText();
            var todo = new Todo
            {
                Id = id,
                Text = text,
                CreatedAt = _now(),
                Category = category,
                LastNonemptyText = TodoEditing.ShouldDeleteRow(text) ? "" : text
            };
            if (insertAfter is Guid after)
            {
                var afterIndex = todos.FindIndex(item => item.Id == after);
                todos.Insert(afterIndex >= 0 ? afterIndex + 1 : todos.Count, todo);
            }
            else
            {
                todos.Add(todo);
            }
            SaveUnlocked(todos);
            return todo.Copy();
        });
    }

    public Todo Move(Guid id, TodoCategory category)
    {
        return ExecuteLocked(() =>
        {
            var todos = LoadArchiveUnlocked().ToList();
            var index = todos.FindIndex(todo => todo.Id == id && !todo.IsDeleted);
            if (index < 0) throw TodoStoreException.NotFound();
            if (todos[index].Category == category) return todos[index].Copy();
            var todo = todos[index];
            todos.RemoveAt(index);
            todo.Category = category;
            todo.IsCompleted = false;
            todo.CompletedAt = null;
            todos.Add(todo);
            SaveUnlocked(todos);
            return todo.Copy();
        });
    }

    private Todo NewTodo(Guid id, string text, TodoCategory category)
    {
        var trimmed = text.Trim();
        return new Todo
        {
            Id = id,
            Text = trimmed,
            CreatedAt = _now(),
            Category = category,
            LastNonemptyText = TodoEditing.ShouldDeleteRow(trimmed) ? "" : trimmed
        };
    }

    private List<Todo> LoadArchiveUnlocked()
    {
        string raw;
        try
        {
            raw = File.ReadAllText(_filePath);
        }
        catch (FileNotFoundException)
        {
            return [];
        }
        catch (DirectoryNotFoundException)
        {
            return [];
        }
        var todos = JsonSerializer.Deserialize<List<TodoDto>>(raw, TodoJson.TodoOptions)
            ?.Select(dto => dto.ToTodo()).ToList() ?? [];
        if (todos.Select(todo => todo.Id).Distinct().Count() != todos.Count) throw TodoStoreException.NotFound();
        var adopted = false;
        foreach (var todo in todos.Where(todo => todo.IsCompleted && todo.CompletedAt is null))
        {
            todo.CompletedAt = _now();
            adopted = true;
        }
        if (!adopted) return todos;
        PersistUnlocked(todos);
        return JsonSerializer.Deserialize<List<TodoDto>>(File.ReadAllText(_filePath), TodoJson.TodoOptions)!
            .Select(dto => dto.ToTodo()).ToList();
    }

    private void SaveUnlocked(IReadOnlyList<Todo> todos)
    {
        var existing = LoadArchiveUnlocked();
        var deletedIds = existing.Where(todo => todo.IsDeleted).Select(todo => todo.Id).ToHashSet();
        var merged = todos.Where(todo => !deletedIds.Contains(todo.Id)).Select(todo => todo.Copy()).ToList();
        for (var i = 0; i < merged.Count; i++)
        {
            var previous = existing.FirstOrDefault(todo => todo.Id == merged[i].Id);
            if (previous is not null && merged[i].Text.Length < previous.Text.Length)
                merged[i].LastNonemptyText = previous.LastNonemptyText;
            else if (!TodoEditing.ShouldDeleteRow(merged[i].Text))
                merged[i].LastNonemptyText = merged[i].Text;
            else if (previous is not null)
                merged[i].LastNonemptyText = previous.ArchiveText;
        }
        merged.AddRange(existing.Where(todo => todo.IsDeleted).Select(todo => todo.Copy()));
        if (merged.Select(todo => todo.Id).Distinct().Count() != merged.Count) throw TodoStoreException.NotFound();
        if (NotesCount(merged) > Math.Max(NotesLimit, NotesCount(existing))) throw TodoStoreException.NotesLimitReached();
        PersistUnlocked(merged);
    }

    private void PersistUnlocked(IReadOnlyList<Todo> todos)
    {
        var payload = JsonSerializer.Serialize(todos.Select(TodoDto.From).ToArray(), TodoJson.TodoOptions);
        AtomicFile.WriteAllText(_filePath, payload);
        var handler = Changed;
        if (handler is not null) ThreadPool.UnsafeQueueUserWorkItem(static state => ((Action)state!)(), handler);
    }

    public void NotifyChanged() => Changed?.Invoke();
}

internal sealed class TodoDto
{
    public Guid Id { get; set; }
    public string Text { get; set; } = "";
    public DateTime CreatedAt { get; set; }
    public bool IsCompleted { get; set; }
    public TodoCategory Category { get; set; }
    public DateTime? CompletedAt { get; set; }
    public bool IsDeleted { get; set; }
    public DateTime? DeletedAt { get; set; }
    public string? LastNonemptyText { get; set; }

    public Todo ToTodo() => new()
    {
        Id = Id,
        Text = Text,
        CreatedAt = DateTime.SpecifyKind(CreatedAt, DateTimeKind.Utc),
        IsCompleted = IsCompleted,
        Category = Category,
        CompletedAt = CompletedAt is null ? null : DateTime.SpecifyKind(CompletedAt.Value, DateTimeKind.Utc),
        IsDeleted = IsDeleted,
        DeletedAt = DeletedAt is null ? null : DateTime.SpecifyKind(DeletedAt.Value, DateTimeKind.Utc),
        LastNonemptyText = LastNonemptyText ?? (TodoEditing.ShouldDeleteRow(Text) ? "" : Text)
    };

    public static TodoDto From(Todo todo) => new()
    {
        Id = todo.Id,
        Text = todo.Text,
        CreatedAt = todo.CreatedAt,
        IsCompleted = todo.IsCompleted,
        Category = todo.Category,
        CompletedAt = todo.CompletedAt,
        IsDeleted = todo.IsDeleted,
        DeletedAt = todo.DeletedAt,
        LastNonemptyText = todo.LastNonemptyText
    };
}
