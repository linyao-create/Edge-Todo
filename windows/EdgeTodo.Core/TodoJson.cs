using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace EdgeTodo;

public static class TodoJson
{
    public static readonly DateTime SwiftReference = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    public static JsonSerializerOptions TodoOptions { get; } = CreateTodoOptions();

    public static JsonSerializerOptions SettingsOptions { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private static JsonSerializerOptions CreateTodoOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
        };
        options.Converters.Add(new UpperGuidConverter());
        options.Converters.Add(new IsoDateTimeConverter());
        options.Converters.Add(new TodoCategoryConverter());
        return options;
    }

    public static string FormatIso(DateTime value)
    {
        var utc = value.Kind == DateTimeKind.Unspecified
            ? DateTime.SpecifyKind(value, DateTimeKind.Utc)
            : value.ToUniversalTime();
        return utc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
    }

    public static DateTime ParseIso(string value)
    {
        if (!DateTime.TryParse(value, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var parsed))
        {
            throw new JsonException("Invalid ISO-8601 date");
        }
        return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
    }
}

public sealed class UpperGuidConverter : JsonConverter<Guid>
{
    public override Guid Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var text = reader.GetString();
        if (text is null || !Guid.TryParse(text, out var id)) throw new JsonException("Invalid id");
        return id;
    }

    public override void Write(Utf8JsonWriter writer, Guid value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("D").ToUpperInvariant());
}

public sealed class IsoDateTimeConverter : JsonConverter<DateTime>
{
    public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        TodoJson.ParseIso(reader.GetString() ?? throw new JsonException("Invalid ISO-8601 date"));

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options) =>
        writer.WriteStringValue(TodoJson.FormatIso(value));
}

public sealed class TodoCategoryConverter : JsonConverter<TodoCategory>
{
    public override TodoCategory Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        TodoCategories.FromWire(reader.GetString());

    public override void Write(Utf8JsonWriter writer, TodoCategory value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToWire());
}
