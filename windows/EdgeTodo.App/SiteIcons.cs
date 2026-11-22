using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace EdgeTodo;

internal static class SiteIcons
{
    private static readonly Dictionary<SavedLinkSource, ImageSource?> Cache = [];

    public static ImageSource? Get(SavedLinkSource source)
    {
        if (Cache.TryGetValue(source, out var cached)) return cached;
        var name = source switch
        {
            SavedLinkSource.YouTube => "youtube.png",
            SavedLinkSource.Xiaohongshu => "xiaohongshu.png",
            _ => "bilibili.png"
        };
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.UriSource = new Uri($"pack://application:,,,/Assets/SiteIcons/{name}", UriKind.Absolute);
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.EndInit();
            image.Freeze();
            Cache[source] = image;
            return image;
        }
        catch (Exception)
        {
            Cache[source] = null;
            return null;
        }
    }
}
