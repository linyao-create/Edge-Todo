using System.Text;

namespace EdgeTodo;

/**
 * 命令行辅助工具入口，支持通过 --data-dir 或环境变量操作指定数据目录并通知对应运行的桌面实例。
 */
internal static class Program
{
    private static int Main(string[] args)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        ParsedLaunchArguments parsed;
        string dataDirectory;
        try
        {
            parsed = AppPaths.ParseArguments(args);
            if (!TodoCli.IsCommand(parsed.RemainingArgs))
            {
                Console.WriteLine(TodoCli.Help());
                return 1;
            }
            dataDirectory = AppPaths.ResolveDataDirectory(parsed.DataDirectory);
        }
        catch (LaunchConfigException ex)
        {
            Console.WriteLine(TodoCli.Error(ex.Message));
            return 1;
        }

        var output = TodoCli.Execute(dataDirectory, parsed.RemainingArgs);
        Console.WriteLine(output);
        return output.Contains("\"error\"", StringComparison.Ordinal) ? 1 : 0;
    }
}
