namespace EdgeTodo;

public enum SavedLinkSource
{
    YouTube,
    Xiaohongshu,
    Bilibili
}

public sealed record SavedLinkNote(string OriginalText, Uri Url, string Title, string Domain)
{
    public SavedLinkSource? SourceIcon => IconFor(Domain);

    public static SavedLinkNote? Parse(string text)
    {
        var lines = text.Trim().Split(['\r', '\n'], StringSplitOptions.None);
        if (lines.Length is < 1 or > 2) return null;
        var address = lines[^1].Trim();
        if (address.Length == 0 || address.Any(char.IsWhiteSpace)) return null;
        var normalized = address.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? "https://" + address : address;
        if (!Uri.TryCreate(normalized, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme is not ("http" or "https")) return null;
        if (string.IsNullOrEmpty(uri.Host) || !string.IsNullOrEmpty(uri.UserInfo)) return null;

        var rawTitle = lines.Length == 2 ? lines[0].Trim() : "";
        if (lines.Length == 2 && rawTitle.Length == 0) return null;
        var shortDomain = uri.Host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? uri.Host[4..] : uri.Host;
        shortDomain = shortDomain.ToLowerInvariant();
        var isXiaohongshu = Matches(shortDomain, "xiaohongshu.com") || shortDomain == "xhslink.cn";
        var genericXiaohongshuTitle = isXiaohongshu &&
            (rawTitle == "小红书" || rawTitle.StartsWith("小红书 - ", StringComparison.Ordinal) || rawTitle.StartsWith("小红书-", StringComparison.Ordinal));
        var title = rawTitle.Length == 0 || genericXiaohongshuTitle
            || rawTitle == uri.Host || rawTitle == shortDomain
            || rawTitle == address || rawTitle == uri.AbsoluteUri
            ? (isXiaohongshu ? "小红书笔记" : shortDomain)
            : rawTitle;
        return new SavedLinkNote(text, uri, title, shortDomain);
    }

    public static SavedLinkSource? IconFor(string domain)
    {
        if (Matches(domain, "youtube.com") || Matches(domain, "youtu.be")) return SavedLinkSource.YouTube;
        if (Matches(domain, "xiaohongshu.com") || Matches(domain, "xhslink.cn")) return SavedLinkSource.Xiaohongshu;
        if (Matches(domain, "bilibili.com") || Matches(domain, "b23.tv")) return SavedLinkSource.Bilibili;
        return null;
    }

    private static bool Matches(string domain, string root) =>
        domain.Equals(root, StringComparison.OrdinalIgnoreCase) ||
        domain.EndsWith("." + root, StringComparison.OrdinalIgnoreCase);
}
