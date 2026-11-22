using EdgeTodo;
using Xunit;

namespace EdgeTodo.Core.Tests;

public sealed class ManualScheduler : IEdgeScheduler
{
    private readonly List<(TimeSpan Delay, Action Action)> _pending = [];
    public int Pending => _pending.Count;

    public IDisposable Schedule(TimeSpan delay, Action action)
    {
        var item = (delay, action);
        _pending.Add(item);
        return new Ticket(() => _pending.Remove(item));
    }

    public void FireNext()
    {
        var item = _pending[0];
        _pending.RemoveAt(0);
        item.Action();
    }

    private sealed class Ticket(Action cancel) : IDisposable
    {
        public void Dispose() => cancel();
    }
}

public class TodoStoreTests
{
    private static TodoStore Create(out string path)
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        path = Path.Combine(directory, "todos.json");
        var now = new DateTime(2026, 11, 15, 1, 0, 0, DateTimeKind.Utc);
        return new TodoStore(path, () => now);
    }

    [Fact]
    public void AddRejectsEmptyAndRoundTrips()
    {
        var store = Create(out var path);
        Assert.Throws<TodoStoreException>(() => store.Add("   "));
        var added = store.Add("  买牛奶  ");
        var loaded = store.Load();
        Assert.Equal("买牛奶", loaded[0].Text);
        Assert.Equal(added.Id, loaded[0].Id);
        Assert.Contains("\"category\": \"today\"", File.ReadAllText(path).Replace("\r\n", "\n"));
    }

    [Fact]
    public void CompletedTodayHidesOnTheNextLocalDay()
    {
        var now = new DateTime(2026, 11, 15, 2, 0, 0, DateTimeKind.Utc);
        var store = new TodoStore(Path.Combine(Path.GetTempPath(), "edgetodo-tests", Guid.NewGuid().ToString("N"), "todos.json"), () => now);
        var todo = store.Add("买牛奶");
        store.UpdateCompletion(todo.Id, true);
        Assert.True(store.Load().Single().IsVisible(now));
        Assert.False(store.Load().Single().IsVisible(now.AddDays(2)));
    }

    [Fact]
    public void MoveAppendsAtDestinationAndClearsCompletion()
    {
        var store = Create(out _);
        var first = store.Add("任务A");
        var note = store.Add("随记1", TodoCategory.Notes);
        store.UpdateCompletion(first.Id, true);
        store.Move(first.Id, TodoCategory.Notes);
        var notes = store.Load().Where(todo => todo.Category == TodoCategory.Notes).ToArray();
        Assert.Equal([note.Id, first.Id], notes.Select(todo => todo.Id));
        Assert.False(notes[1].IsCompleted);
    }

    [Fact]
    public void ImportIsIdempotentAndDeleteHidesTheRow()
    {
        var store = Create(out _);
        var id = Guid.NewGuid();
        var first = store.ImportNote(id, "标题\nhttps://example.com");
        var second = store.ImportNote(id, "另一条");
        Assert.Equal(first.Text, second.Text);
        Assert.Single(store.Load());
        store.Delete(id);
        Assert.Empty(store.Load());
        Assert.Single(store.LoadArchive());
    }

    [Fact]
    public void DuplicateIdsFailClosed()
    {
        var store = Create(out var path);
        var id = Guid.NewGuid();
        File.WriteAllText(path, $$"""
        [
          {"id":"{{id}}","text":"a","createdAt":"2026-11-15T00:00:00.000Z","isCompleted":false,"category":"today"},
          {"id":"{{id}}","text":"b","createdAt":"2026-11-15T00:00:00.000Z","isCompleted":false,"category":"today"}
        ]
        """);
        Assert.Throws<TodoStoreException>(() => store.Load());
    }
}

public class SavedLinkTests
{
    [Theory]
    [InlineData("https://m.youtube.com/watch?v=abc", SavedLinkSource.YouTube)]
    [InlineData("https://youtu.be/abc", SavedLinkSource.YouTube)]
    [InlineData("https://www.xiaohongshu.com/explore/abc", SavedLinkSource.Xiaohongshu)]
    [InlineData("https://xhslink.cn/abc", SavedLinkSource.Xiaohongshu)]
    [InlineData("https://www.bilibili.com/video/BV1", SavedLinkSource.Bilibili)]
    [InlineData("https://b23.tv/abc", SavedLinkSource.Bilibili)]
    public void RecognizesHosts(string address, SavedLinkSource source)
    {
        var link = SavedLinkNote.Parse(address);
        Assert.NotNull(link);
        Assert.Equal(source, link.SourceIcon);
    }

    [Theory]
    [InlineData("https://example.com/page")]
    [InlineData("https://youtube.com.evil.example/page")]
    [InlineData("https://notbilibili.com/video")]
    public void UnknownHostsStayPlain(string address)
    {
        var link = SavedLinkNote.Parse(address);
        Assert.NotNull(link);
        Assert.Null(link.SourceIcon);
    }

    [Fact]
    public void KeepsTitleAndOriginalUrl()
    {
        var original = "https://www.funwithcomputervision.com/?source=note&next=a%2Fb#gallery";
        var link = SavedLinkNote.Parse("Fun With Computer Vision\n" + original);
        Assert.NotNull(link);
        Assert.Equal("Fun With Computer Vision", link.Title);
        Assert.Equal("funwithcomputervision.com", link.Domain);
        Assert.Equal(original, link.Url.AbsoluteUri);
    }

    [Fact]
    public void XiaohongshuWithoutSchemeGetsShortTitle()
    {
        var original = "www.xiaohongshu.com/explore/000000000000000000000001?xsec_token=synthetic_demo_token&xsec_source=pc_feed";
        var link = SavedLinkNote.Parse(original);
        Assert.NotNull(link);
        Assert.Equal("小红书笔记", link.Title);
        Assert.Equal("xiaohongshu.com", link.Domain);
        Assert.StartsWith("https://" + original, link.Url.AbsoluteUri);
    }

    [Fact]
    public void GenericXiaohongshuTitleFallsBack()
    {
        var text = "小红书 - 你的生活指南\nhttps://www.xiaohongshu.com/explore/abc?xsec_token=token";
        var link = SavedLinkNote.Parse(text);
        Assert.NotNull(link);
        Assert.Equal("小红书笔记", link.Title);
        Assert.Equal(text, link.OriginalText);
    }
}

public class BrowserCaptureTests
{
    [Fact]
    public void CaptureImportsOnce()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-tests", Guid.NewGuid().ToString("N"));
        var store = new TodoStore(Path.Combine(directory, "todos.json"));
        var id = Guid.NewGuid();
        var url = $"edgetodo://capture?id={id}&title={Uri.EscapeDataString("一篇笔记")}&url={Uri.EscapeDataString("https://example.com/a")}";
        var note = BrowserCapture.Receive(store, url);
        var again = BrowserCapture.Receive(store, url);
        Assert.Equal(note.Id, again.Id);
        Assert.Equal(TodoCategory.Notes, note.Category);
        Assert.Contains("https://example.com/a", note.Text);
        Assert.True(BrowserCapture.IsReveal("edgetodo://show"));
        Assert.False(BrowserCapture.IsReveal(url));
    }

    [Fact]
    public void CustomProtocolSchemeIsolatesCaptureAndReveal()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-tests", Guid.NewGuid().ToString("N"));
        var store = new TodoStore(Path.Combine(directory, "todos.json"));
        var id = Guid.NewGuid();
        var customUrl = $"edgetodo-test://capture?id={id}&title={Uri.EscapeDataString("测试网页")}&url={Uri.EscapeDataString("https://example.org/test")}";

        Assert.True(BrowserCapture.IsProtocolUri(customUrl, "edgetodo-test"));
        Assert.False(BrowserCapture.IsProtocolUri(customUrl, "edgetodo"));
        Assert.True(BrowserCapture.IsReveal("edgetodo-test://show", "edgetodo-test"));
        Assert.False(BrowserCapture.IsReveal("edgetodo-test://show", "edgetodo"));

        var note = BrowserCapture.Receive(store, customUrl, "edgetodo-test");
        Assert.Contains("https://example.org/test", note.Text);
        Assert.Throws<BrowserCaptureException>(() => BrowserCapture.Receive(store, customUrl, "edgetodo"));
    }
}

public class CountdownTests
{
    [Fact]
    public void PauseResumeAndExpire()
    {
        var start = new DateTime(2026, 11, 15, 0, 0, 0, DateTimeKind.Utc);
        var timer = Countdown.Start(90, start);
        Assert.Equal(CountdownStatus.Running, timer.Status(start.AddSeconds(10)));
        timer.Pause(start.AddSeconds(30));
        Assert.Equal(CountdownStatus.Paused, timer.Status(start.AddMinutes(10)));
        Assert.InRange(timer.Remaining(start), 59, 60);
        timer.Resume(start.AddMinutes(10));
        Assert.Equal(CountdownStatus.Running, timer.Mode);
        Assert.True(timer.ExpireIfNeeded(start.AddHours(2)));
        Assert.Equal(CountdownStatus.Expired, timer.Mode);
        Assert.Equal("01:30", Countdown.Format(90));
        Assert.Equal("1:00:00", Countdown.Format(3600));
    }
}

public class CliTests
{
    [Fact]
    public void AddListAndComplete()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-tests", Guid.NewGuid().ToString("N"));
        var store = new TodoStore(Path.Combine(directory, "todos.json"));
        var added = TodoCli.Run(store, ["add", "today", "买牛奶"]);
        Assert.Contains("买牛奶", added);
        var listed = TodoCli.Run(store, ["list"]);
        Assert.Contains("\"category\":\"today\"", listed);
        var id = store.Load().Single().Id;
        var done = TodoCli.Run(store, ["done", id.ToString()]);
        Assert.Contains("\"completed\":true", done);
    }
}

public class InteractionTests
{
    [Fact]
    public void DwellExpandsAndLeaveCollapsesUnlessPinned()
    {
        var scheduler = new ManualScheduler();
        var states = new List<EdgePanelState>();
        var interaction = new EdgeInteractionController(scheduler);
        interaction.StateChanged += states.Add;
        interaction.PointerEntered();
        interaction.PointerExited();
        Assert.Equal(0, scheduler.Pending);
        interaction.PointerEntered();
        scheduler.FireNext();
        Assert.Equal(EdgePanelState.Expanded, interaction.State);
        interaction.PointerExited();
        interaction.PointerEntered();
        Assert.Equal(0, scheduler.Pending);
        interaction.PointerExited();
        scheduler.FireNext();
        Assert.Equal(EdgePanelState.Collapsed, interaction.State);
        interaction.Reveal();
        interaction.SetPinned(true);
        interaction.PointerExited();
        Assert.Equal(0, scheduler.Pending);
        Assert.Equal(EdgePanelState.Expanded, interaction.State);
    }
}

public class DataIsolationTests
{
    [Fact]
    public void DifferentDataDirectoriesProduceDistinctPipeAndMutexNamesAndRejectMismatches()
    {
        var dirA = Path.Combine(Path.GetTempPath(), "edgetodo-iso-a");
        var dirB = Path.Combine(Path.GetTempPath(), "edgetodo-iso-b");

        Assert.NotEqual(EdgeTodoClient.PipeNameFor(dirA), EdgeTodoClient.PipeNameFor(dirB));
        Assert.NotEqual(EdgeTodoClient.MutexNameFor(dirA), EdgeTodoClient.MutexNameFor(dirB));
        Assert.Equal(EdgeTodoClient.PipeNameFor(dirA), EdgeTodoClient.PipeNameFor(dirA + Path.DirectorySeparatorChar));

        var wrapped = EdgeTodoClient.WrapRequest(dirA, "[\"list\"]");
        Assert.True(EdgeTodoClient.TryUnwrapRequest(wrapped, dirA, out var payload));
        Assert.Equal("[\"list\"]", payload);
        Assert.False(EdgeTodoClient.TryUnwrapRequest(wrapped, dirB, out _));
    }

    [Fact]
    public void LaunchConfigAndArgumentParsingRespectPrecedence()
    {
        var appDir = Path.Combine(Path.GetTempPath(), "edgetodo-appcfg-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(appDir);
        try
        {
            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), """
                {
                  "dataDirectory": "./local-data",
                  "protocolScheme": "edgetodo-cfg",
                  "registerProtocol": false
                }
                """);

            var parsed = AppPaths.ParseArguments(["--data-dir", Path.Combine(appDir, "cli-data"), "--protocol-scheme=edgetodo-cli", "--register-protocol", "list"]);
            Assert.Equal(["list"], parsed.RemainingArgs);
            Assert.Equal(AppPaths.NormalizeDirectory(Path.Combine(appDir, "cli-data")), AppPaths.ResolveDataDirectory(parsed.DataDirectory, appDir));
            Assert.Equal(AppPaths.NormalizeDirectory(Path.Combine(appDir, "local-data")), AppPaths.ResolveDataDirectory(null, appDir));
            Assert.Equal("edgetodo-cli", AppPaths.ResolveProtocolScheme(parsed.ProtocolScheme, appDir));
            Assert.Equal("edgetodo-cfg", AppPaths.ResolveProtocolScheme(null, appDir));
            Assert.True(AppPaths.ResolveRegisterProtocol(parsed.RegisterProtocol, appDir));
            Assert.False(AppPaths.ResolveRegisterProtocol(null, appDir));
        }
        finally
        {
            Directory.Delete(appDir, recursive: true);
        }
    }

    [Fact]
    public void MovingTodoToFullNotesThrowsAndLeavesOriginalTodoInToday()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-limit-" + Guid.NewGuid().ToString("N"));
        var store = new TodoStore(Path.Combine(directory, "todos.json"));
        for (var i = 0; i < TodoStore.NotesLimit; i++)
            store.Add($"随记{i}", TodoCategory.Notes);

        var today = store.Add("保留在今日待办", TodoCategory.Today);
        var ex = Assert.Throws<TodoStoreException>(() => store.Move(today.Id, TodoCategory.Notes));
        Assert.Contains("已满 20 条", ex.Message);

        var reloaded = store.Load().Single(item => item.Id == today.Id);
        Assert.Equal(TodoCategory.Today, reloaded.Category);
        Assert.Equal(TodoStore.NotesLimit, TodoStore.NotesCount(store.Load()));
    }

    [Fact]
    public void CorruptedConfigEmptyArgsAndEmptyEnvThrowLaunchConfigExceptionWithoutFallback()
    {
        var appDir = Path.Combine(Path.GetTempPath(), "edgetodo-badcfg-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(appDir);
        var origEnvDir = Environment.GetEnvironmentVariable("EDGE_TODO_DATA_DIRECTORY");
        try
        {
            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), "{ bad json");
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));

            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), """{"dataDirectory": "   "}""");
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));

            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), """{"protocolScheme": "edgetodo-test"}""");
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));

            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), """{"dataDirectory": null}""");
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));

            File.Delete(Path.Combine(appDir, AppLaunchConfig.FileName));
            Directory.CreateDirectory(Path.Combine(appDir, AppLaunchConfig.FileName));
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));
            Directory.Delete(Path.Combine(appDir, AppLaunchConfig.FileName));

            Assert.Throws<LaunchConfigException>(() => AppPaths.ParseArguments(["--data-dir", ""]));
            Assert.Throws<LaunchConfigException>(() => AppPaths.ParseArguments(["--data-dir="]));
            Assert.Throws<LaunchConfigException>(() => AppPaths.ParseArguments(["--protocol-scheme", "123_invalid"]));
            Assert.Throws<LaunchConfigException>(() => AppPaths.ParseArguments(["--register-protocol", "--no-register-protocol"]));

            Environment.SetEnvironmentVariable("EDGE_TODO_DATA_DIRECTORY", "   ");
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));
        }
        finally
        {
            Environment.SetEnvironmentVariable("EDGE_TODO_DATA_DIRECTORY", origEnvDir);
            if (Directory.Exists(appDir)) Directory.Delete(appDir, recursive: true);
        }
    }

    [Fact]
    public void NormalizeDirectoryResolvesWindowsJunctionAliasConsistently()
    {
        if (!OperatingSystem.IsWindows()) return;
        var root = Path.Combine(Path.GetTempPath(), "edgetodo-junc-" + Guid.NewGuid().ToString("N"));
        var realDir = Path.Combine(root, "real-data");
        var linkDir = Path.Combine(root, "link-data");
        Directory.CreateDirectory(realDir);
        try
        {
            using var mklink = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("cmd.exe", $"/c mklink /J \"{linkDir}\" \"{realDir}\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true
            });
            mklink?.WaitForExit(5000);
            Assert.True(Directory.Exists(linkDir));

            Assert.Equal(AppPaths.NormalizeDirectory(realDir), AppPaths.NormalizeDirectory(linkDir));
            Assert.Equal(AppPaths.DirectoryKey(realDir), AppPaths.DirectoryKey(linkDir));
            Assert.Equal(EdgeTodoClient.PipeNameFor(realDir), EdgeTodoClient.PipeNameFor(linkDir));
            Assert.Equal(EdgeTodoClient.StoreMutexNameFor(realDir), EdgeTodoClient.StoreMutexNameFor(linkDir));

            var subViaLink = Path.Combine(linkDir, "nested", "dir") + Path.DirectorySeparatorChar;
            var subViaReal = Path.Combine(realDir, "nested", "dir");
            Assert.Equal(AppPaths.NormalizeDirectory(subViaReal), AppPaths.NormalizeDirectory(subViaLink));
        }
        finally
        {
            try { if (Directory.Exists(linkDir)) Directory.Delete(linkDir); } catch { }
            try { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); } catch { }
        }
    }

    [Fact]
    public async Task TodoStoreSerializesConcurrentSavesWithoutDataLossOrStaleTempFiles()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-conc-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var filePath = Path.Combine(directory, "todos.json");
            var t1 = Task.Run(() =>
            {
                var store = new TodoStore(filePath);
                for (var i = 0; i < 10; i++) store.Add($"进程A-{i}", TodoCategory.Today);
            });
            var t2 = Task.Run(() =>
            {
                var store = new TodoStore(filePath);
                for (var i = 0; i < 10; i++) store.Add($"进程B-{i}", TodoCategory.Today);
            });
            await Task.WhenAll(t1, t2);

            var all = new TodoStore(filePath).Load();
            Assert.Equal(20, all.Count);
            Assert.Empty(Directory.GetFiles(directory, "*.tmp"));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void EdgeTodoClientDistinguishesBusyPrimaryFromNotListening()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-busy-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var idle = EdgeTodoClient.QueryDetailed(directory, "[\"list\"]", TimeSpan.FromMilliseconds(200));
            Assert.Equal(PipeQueryStatus.NotListening, idle.Status);

            using var primaryMutex = new Mutex(true, EdgeTodoClient.MutexNameFor(directory), out var created);
            Assert.True(created);
            try
            {
                var busy = EdgeTodoClient.QueryDetailed(directory, "[\"list\"]", TimeSpan.FromMilliseconds(200));
                Assert.Equal(PipeQueryStatus.Failed, busy.Status);

                var cliOut = TodoCli.Execute(directory, ["add", "today", "阻塞时不得写入"]);
                Assert.Contains("\"error\"", cliOut);
                Assert.False(File.Exists(Path.Combine(directory, "todos.json")));
            }
            finally
            {
                primaryMutex.ReleaseMutex();
            }
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void ProtocolRegistrationPolicyProtectsExistingExeAndDifferentDataDirectory()
    {
        var currentExe = @"C:\Apps\EdgeTodo\EdgeTodo.exe";
        var otherExe = @"C:\Old\EdgeTodo.exe";
        var defaultDir = @"C:\DefaultData";
        var dirA = @"C:\DataA";
        var dirB = @"C:\DataB";

        Assert.True(ProtocolRegistrationPolicy.ShouldPreserveExisting(true, null, currentExe, dirA));
        Assert.False(ProtocolRegistrationPolicy.ShouldPreserveExisting(false, null, currentExe, dirA));
        Assert.True(ProtocolRegistrationPolicy.ShouldPreserveExisting(false, "\"\"", currentExe, dirA));

        Assert.True(ProtocolRegistrationPolicy.ShouldPreserveExisting(false, $"\"{otherExe}\" \"%1\"", currentExe, dirA, _ => true, defaultDir));
        Assert.False(ProtocolRegistrationPolicy.ShouldPreserveExisting(false, $"\"{otherExe}\" \"%1\"", currentExe, dirA, _ => false, defaultDir));

        Assert.True(ProtocolRegistrationPolicy.ShouldPreserveExisting(false, $"\"{currentExe}\" --data-dir \"{dirA}\" \"%1\"", currentExe, dirB, _ => true, defaultDir));
        Assert.True(ProtocolRegistrationPolicy.ShouldPreserveExisting(false, $"\"{currentExe}\" \"%1\"", currentExe, dirA, _ => true, defaultDir));
        Assert.False(ProtocolRegistrationPolicy.ShouldPreserveExisting(false, $"\"{currentExe}\" --data-dir \"{dirA}\" \"%1\"", currentExe, dirA + @"\", _ => true, defaultDir));
        Assert.False(ProtocolRegistrationPolicy.ShouldPreserveExisting(false, $"\"{currentExe}\" \"%1\"", currentExe, defaultDir, _ => true, defaultDir));
    }

    [Fact]
    public void ConfigFileRegisterProtocolTrueDoesNotForceOverwriteOnNormalLaunch()
    {
        var appDir = Path.Combine(Path.GetTempPath(), "edgetodo-regcfg-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(appDir);
        var origEnv = Environment.GetEnvironmentVariable("EDGE_TODO_REGISTER_PROTOCOL");
        try
        {
            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), """{"dataDirectory": "./data", "registerProtocol": true}""");
            Assert.Null(AppPaths.ResolveRegisterProtocol(null, appDir));
            Assert.True(AppPaths.ResolveRegisterProtocol(true, appDir));

            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), """{"dataDirectory": "./data", "registerProtocol": false}""");
            Assert.False(AppPaths.ResolveRegisterProtocol(null, appDir));

            // 继承来的环境变量 EDGE_TODO_REGISTER_PROTOCOL=true 绝不能覆盖测试副本的禁用设置，也不能触发强制接管
            Environment.SetEnvironmentVariable("EDGE_TODO_REGISTER_PROTOCOL", "true");
            Assert.False(AppPaths.ResolveRegisterProtocol(null, appDir));

            File.Delete(Path.Combine(appDir, AppLaunchConfig.FileName));
            Assert.Null(AppPaths.ResolveRegisterProtocol(null, appDir));
            Assert.True(AppPaths.ResolveRegisterProtocol(true, appDir));

            // 无法定位配置所在目录时不得静默视为未配置
            var missingBaseDir = Path.Combine(appDir, "non-existent-parent");
            Assert.Throws<LaunchConfigException>(() => AppLaunchConfig.Load(missingBaseDir));

            // 主配置缺失但存在替换失败遗留的 .bak 备份时，必须拒绝启动以防回退默认目录
            File.WriteAllText(Path.Combine(appDir, "edgetodo-config.json.1234.abcdef.bak"), """{"dataDirectory": "./data"}""");
            Assert.Throws<LaunchConfigException>(() => AppLaunchConfig.Load(appDir));
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));

            // 重新写回合法主配置后，允许正常启动并优先使用主配置
            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), """{"dataDirectory": "./recovered-data"}""");
            Assert.Equal(AppPaths.NormalizeDirectory(Path.Combine(appDir, "recovered-data")), AppPaths.ResolveDataDirectory(null, appDir));
        }
        finally
        {
            Environment.SetEnvironmentVariable("EDGE_TODO_REGISTER_PROTOCOL", origEnv);
            if (Directory.Exists(appDir)) Directory.Delete(appDir, recursive: true);
        }
    }

    [Fact]
    public void CountdownRepositoryReloadsLatestFromDiskInsideLockAcrossInstances()
    {
        var dir = Path.Combine(Path.GetTempPath(), "edgetodo-cd-lock-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, "countdowns.json");
            var repoA = new CountdownRepository(file);
            var repoB = new CountdownRepository(file);
            var now = new DateTime(2026, 11, 21, 7, 0, 0, DateTimeKind.Utc);
            var id1 = Guid.NewGuid();
            var id2 = Guid.NewGuid();

            repoA.Set(Countdown.Start(60, now), id1);
            repoB.Set(Countdown.Start(120, now), id2);

            var reloaded = new CountdownRepository(file);
            Assert.NotNull(reloaded[id1]);
            Assert.NotNull(reloaded[id2]);

            // repoA 内存原本未见过 id2，Retain 应先从磁盘重读最新集合，保留 id2 并只移除 id1
            Assert.True(repoA.Retain(new HashSet<Guid> { id2 }));
            var afterRetain = new CountdownRepository(file);
            Assert.Null(afterRetain[id1]);
            Assert.NotNull(afterRetain[id2]);
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void CountdownManagerLocksAndUsesLatestDiskStateForSameItemAcrossInstances()
    {
        var dir = Path.Combine(Path.GetTempPath(), "edgetodo-cd-same-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, "countdowns.json");
            var t0 = new DateTime(2026, 11, 21, 8, 0, 0, DateTimeKind.Utc);
            var id = Guid.NewGuid();

            // 初始写入一个 10 秒后到期的倒计时
            var seed = new CountdownManager(file);
            seed.Set(Countdown.Start(10, t0), id);

            // 两个管理器各自加载了旧状态（t0 + 10s 到期）
            var mgrA = new CountdownManager(file);
            var mgrB = new CountdownManager(file);

            // 实例 A 在 t0 + 5s 重新启动同一条倒计时为 600 秒（运行中）
            var t1 = t0.AddSeconds(5);
            mgrA.Set(Countdown.Start(600, t1), id);

            // 实例 B 在 t0 + 15s 依据旧缓存执行 RefreshExpired，绝不能把磁盘覆盖回「已到期」
            var t2 = t0.AddSeconds(15);
            mgrB.RefreshExpired(t2);

            var diskAfterRefresh = new CountdownRepository(file);
            Assert.Equal(CountdownStatus.Running, diskAfterRefresh[id]?.Mode);
            Assert.Equal(CountdownStatus.Running, mgrB.Timer(id)?.Mode);

            // 实例 A 删除该倒计时后，实例 B 持旧缓存调用 Pause/Resume 绝不能把已删条目写回磁盘
            mgrA.Set(null, id);
            mgrB.Pause(id, t2.AddSeconds(1));
            mgrB.Resume(id, t2.AddSeconds(2));

            var diskAfterDelete = new CountdownRepository(file);
            Assert.Null(diskAfterDelete[id]);
            Assert.Null(mgrB.Timer(id));
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public void LaunchConfigBlocksWhenOnlyTempArtifactRemains()
    {
        var appDir = Path.Combine(Path.GetTempPath(), "edgetodo-cfg-tmp-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(appDir);
        try
        {
            File.WriteAllText(Path.Combine(appDir, "edgetodo-config.json.1234.abc.tmp"), """{"dataDirectory": "./data"}""");
            Assert.Throws<LaunchConfigException>(() => AppLaunchConfig.Load(appDir));
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));
        }
        finally
        {
            if (Directory.Exists(appDir)) Directory.Delete(appDir, recursive: true);
        }
    }

    [Fact]
    public void LaunchConfigBlocksWhenPendingMarkerPresent()
    {
        var appDir = Path.Combine(Path.GetTempPath(), "edgetodo-cfg-pending-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(appDir);
        try
        {
            var pendingPath = Path.Combine(appDir, AppLaunchConfig.PendingFileName);
            File.WriteAllText(pendingPath, """{"pid": 1234}""");
            Assert.Throws<LaunchConfigException>(() => AppLaunchConfig.Load(appDir));
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));

            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), """{"dataDirectory": "./data"}""");
            Assert.Throws<LaunchConfigException>(() => AppLaunchConfig.Load(appDir));
            Assert.Throws<LaunchConfigException>(() => AppPaths.ResolveDataDirectory(null, appDir));

            File.Delete(pendingPath);
            var loaded = AppLaunchConfig.Load(appDir);
            Assert.NotNull(loaded);
            Assert.Equal("./data", loaded.DataDirectory);
        }
        finally
        {
            if (Directory.Exists(appDir)) Directory.Delete(appDir, recursive: true);
        }
    }

    [Fact]
    public void LaunchConfigAllowsValidMainWithLeftoverArtifacts()
    {
        var appDir = Path.Combine(Path.GetTempPath(), "edgetodo-cfg-valid-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(appDir);
        try
        {
            File.WriteAllText(Path.Combine(appDir, AppLaunchConfig.FileName), """{"dataDirectory": "./my-data"}""");
            File.WriteAllText(Path.Combine(appDir, "edgetodo-config.json.1234.abc.tmp"), """{"dataDirectory": "./stale"}""");
            File.WriteAllText(Path.Combine(appDir, "edgetodo-config.json.1234.abc.bak"), """{"dataDirectory": "./old"}""");

            var loaded = AppLaunchConfig.Load(appDir);
            Assert.NotNull(loaded);
            Assert.Equal("./my-data", loaded.DataDirectory);
            Assert.Equal(AppPaths.NormalizeDirectory(Path.Combine(appDir, "my-data")), AppPaths.ResolveDataDirectory(null, appDir));
        }
        finally
        {
            if (Directory.Exists(appDir)) Directory.Delete(appDir, recursive: true);
        }
    }

    [Fact]
    public void LaunchConfigReturnsNullForCleanDirectory()
    {
        var appDir = Path.Combine(Path.GetTempPath(), "edgetodo-cfg-clean-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(appDir);
        try
        {
            Assert.Null(AppLaunchConfig.Load(appDir));
        }
        finally
        {
            if (Directory.Exists(appDir)) Directory.Delete(appDir, recursive: true);
        }
    }

    [Fact]
    public void CountdownRetainActiveUsesLatestTodosInsideLock()
    {
        var dir = Path.Combine(Path.GetTempPath(), "edgetodo-cd-retain-active-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var todosFile = Path.Combine(dir, "todos.json");
            var countdownsFile = Path.Combine(dir, "countdowns.json");

            // 模拟实例 A 先启动管理器（此时旧待办快照为空）
            var mgrA = new CountdownManager(countdownsFile);

            // 模拟实例 B 写入一条新的今日待办并立即为其开启倒计时
            var storeB = new TodoStore(todosFile);
            var created = storeB.Add("跨实例新建任务", TodoCategory.Today);
            var mgrB = new CountdownManager(countdownsFile);
            mgrB.Start(300, created.Id);

            // 实例 A 按旧视野刷新并调用 RetainActive，必须在同一把锁内读取最新 todos.json 并保留新建倒计时
            mgrA.RetainActive();
            var reloaded = new CountdownRepository(countdownsFile);
            Assert.NotNull(reloaded[created.Id]);

            // 将该待办标为完成后再调用 RetainActive，倒计时应被安全清理
            storeB.UpdateCompletion(created.Id, true);
            mgrA.RetainActive();
            var afterComplete = new CountdownRepository(countdownsFile);
            Assert.Null(afterComplete[created.Id]);
        }
        finally
        {
            if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
        }
    }
}
