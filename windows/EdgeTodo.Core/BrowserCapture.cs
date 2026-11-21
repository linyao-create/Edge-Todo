using System.Text;

namespace EdgeTodo;

public sealed class BrowserCaptureException : Exception
{
    public BrowserCaptureException(string message) : base(message) { }

    public static BrowserCaptureException InvalidRequest() =>
        new("保存请求不完整，请重新点击浏览器的「存当前页到随记」。");

    public static BrowserCaptureException InvalidPage() =>
        new("请先在浏览器打开要保存的网页，再点击「存当前页到随记」。");
}

/**
 * 解析并接收来自浏览器扩展的协议收藏与唤醒指令，支持指定独立协议名以实现多版本隔离。
 */
public static class BrowserCapture
{
    public const string Scheme = "edgetodo";

    /**
     * 判断给定 URI 字符串是否属于指定的协议名。
     * @param {string} raw 原始 URI 文本
     * @param {string} scheme 目标协议名
     * @returns {bool} 是否匹配指定协议
     */
    public static bool IsProtocolUri(string raw, string scheme) =>
        Uri.TryCreate(raw, UriKind.Absolute, out var uri)
        && uri.Scheme.Equals(scheme, StringComparison.OrdinalIgnoreCase);

    public static bool IsReveal(string raw) => IsReveal(raw, Scheme);

    /**
     * 判断 URI 是否为唤醒展示指令（例如 edgetodo://show）。
     * @param {string} raw 原始 URI 文本
     * @param {string?} expectedScheme 允许匹配的协议名，默认 edgetodo
     * @returns {bool} 是否为有效的唤醒指令
     */
    public static bool IsReveal(string raw, string? expectedScheme)
    {
        var scheme = string.IsNullOrWhiteSpace(expectedScheme) ? Scheme : expectedScheme;
        if (!TryParts(raw, scheme, out var host, out var path, out var items, out var fragment, out var port, out var user)) return false;
        return host == "show" && (path.Length == 0 || path == "/") && items.Count == 0 && fragment is null && port is null && user is null;
    }

    public static Todo Receive(TodoStore store, string raw) => Receive(store, raw, Scheme);

    /**
     * 解析浏览器收藏请求并幂等写入指定数据存储。
     * @param {TodoStore} store 目标数据存储实例
     * @param {string} raw 浏览器发送的协议 URI
     * @param {string?} expectedScheme 允许匹配的协议名，默认 edgetodo
     * @returns {Todo} 写入或已存在的随记实体
     */
    public static Todo Receive(TodoStore store, string raw, string? expectedScheme)
    {
        var scheme = string.IsNullOrWhiteSpace(expectedScheme) ? Scheme : expectedScheme;
        if (Encoding.UTF8.GetByteCount(raw) > 65_536) throw BrowserCaptureException.InvalidRequest();
        if (!TryParts(raw, scheme, out var host, out var path, out var items, out var fragment, out var port, out var user))
            throw BrowserCaptureException.InvalidRequest();
        if (host != "capture" || (path.Length != 0 && path != "/") || port is not null || user is not null || fragment is not null)
            throw BrowserCaptureException.InvalidRequest();
        if (items.Count(item => item.Name == "url") != 1 ||
            items.Count(item => item.Name == "title") > 1 ||
            items.Count(item => item.Name == "id") != 1 ||
            !Guid.TryParse(items.First(item => item.Name == "id").Value, out var id))
        {
            throw BrowserCaptureException.InvalidRequest();
        }

        var pageValue = items.First(item => item.Name == "url").Value ?? "";
        if (!Uri.TryCreate(pageValue, UriKind.Absolute, out var page) ||
            page.Scheme is not ("http" or "https") ||
            string.IsNullOrEmpty(page.Host))
        {
            throw BrowserCaptureException.InvalidPage();
        }

        var title = (items.FirstOrDefault(item => item.Name == "title").Value ?? "").Trim();
        var note = title.Length == 0 ? page.AbsoluteUri : title + "\n" + page.AbsoluteUri;
        return store.ImportNote(id, note);
    }

    private static bool TryParts(string raw, string expectedScheme, out string host, out string path, out List<(string Name, string? Value)> items,
        out string? fragment, out int? port, out string? user)
    {
        host = "";
        path = "";
        items = [];
        fragment = null;
        port = null;
        user = null;
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri)) return false;
        if (!uri.Scheme.Equals(expectedScheme, StringComparison.OrdinalIgnoreCase)) return false;
        host = (uri.Host ?? "").ToLowerInvariant();
        path = uri.AbsolutePath ?? "";
        fragment = string.IsNullOrEmpty(uri.Fragment) ? null : uri.Fragment;
        port = uri.IsDefaultPort ? null : uri.Port;
        user = string.IsNullOrEmpty(uri.UserInfo) ? null : uri.UserInfo;
        items = ParseQuery(uri.Query);
        return true;
    }

    private static List<(string Name, string? Value)> ParseQuery(string query)
    {
        var items = new List<(string, string?)>();
        if (string.IsNullOrEmpty(query)) return items;
        var body = query.StartsWith('?') ? query[1..] : query;
        if (body.Length == 0) return items;
        foreach (var part in body.Split('&', StringSplitOptions.None))
        {
            if (part.Length == 0) continue;
            var split = part.IndexOf('=');
            var name = Uri.UnescapeDataString(split < 0 ? part : part[..split]);
            var value = split < 0 ? null : Uri.UnescapeDataString(part[(split + 1)..]);
            items.Add((name, value));
        }
        return items;
    }
}
