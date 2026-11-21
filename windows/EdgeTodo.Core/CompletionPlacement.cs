namespace EdgeTodo;

public static class CompletionPlacement
{
    public readonly record struct Hold(int Index, bool WasCompleted);

    public static List<T> Apply<T>(IReadOnlyList<T> rows, Func<T, Guid> id, IReadOnlyDictionary<Guid, Hold> holds)
    {
        var retained = rows.Where(row => holds.ContainsKey(id(row))).OrderBy(row => holds[id(row)].Index).ToList();
        var result = rows.Where(row => !holds.ContainsKey(id(row))).ToList();
        foreach (var row in retained)
        {
            var index = Math.Clamp(holds[id(row)].Index, 0, result.Count);
            result.Insert(index, row);
        }
        return result;
    }
}
