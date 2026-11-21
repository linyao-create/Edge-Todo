namespace EdgeTodo;

public enum TodoCategory
{
    Today,
    Notes
}

public static class TodoCategories
{
    public static string Title(this TodoCategory category) =>
        category == TodoCategory.Today ? "今日待办" : "随记";

    public static TodoCategory Destination(this TodoCategory category) =>
        category == TodoCategory.Today ? TodoCategory.Notes : TodoCategory.Today;

    public static string MoveTitle(this TodoCategory category) =>
        category == TodoCategory.Today ? "→ 随记" : "→ 待办";

    public static string ToWire(this TodoCategory category) =>
        category == TodoCategory.Today ? "today" : "notes";

    public static TodoCategory FromWire(string? value) =>
        string.Equals(value, "notes", StringComparison.Ordinal) ? TodoCategory.Notes : TodoCategory.Today;
}

public sealed class Todo
{
    public Guid Id { get; set; }
    public string Text { get; set; } = "";
    public DateTime CreatedAt { get; set; }
    public bool IsCompleted { get; set; }
    public TodoCategory Category { get; set; } = TodoCategory.Today;
    public DateTime? CompletedAt { get; set; }
    public bool IsDeleted { get; set; }
    public DateTime? DeletedAt { get; set; }
    public string LastNonemptyText { get; set; } = "";

    public string ArchiveText =>
        IsDeleted || TodoEditing.ShouldDeleteRow(Text) ? LastNonemptyText : Text;

    public bool IsVisible(DateTime at)
    {
        if (IsDeleted) return false;
        if (Category != TodoCategory.Today || !IsCompleted || CompletedAt is null) return true;
        return StartOfLocalDay(CompletedAt.Value) >= StartOfLocalDay(at);
    }

    public static DateTime StartOfLocalDay(DateTime value)
    {
        var local = value.Kind == DateTimeKind.Utc ? value.ToLocalTime() : DateTime.SpecifyKind(value, DateTimeKind.Local);
        return local.Date;
    }

    public Todo Copy() => new()
    {
        Id = Id,
        Text = Text,
        CreatedAt = CreatedAt,
        IsCompleted = IsCompleted,
        Category = Category,
        CompletedAt = CompletedAt,
        IsDeleted = IsDeleted,
        DeletedAt = DeletedAt,
        LastNonemptyText = LastNonemptyText
    };
}

public static class TodoEditing
{
    public static bool ShouldDeleteRow(string text) =>
        string.IsNullOrWhiteSpace(text);
}
