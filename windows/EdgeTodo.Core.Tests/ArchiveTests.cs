using EdgeTodo;
using Xunit;

namespace EdgeTodo.Core.Tests;

public class DailyArchiveTests
{
    [Fact]
    public void SameDayItemsBecomeOneRecord()
    {
        var when = new DateTime(2026, 11, 16, 2, 0, 0, DateTimeKind.Utc);
        var rows = DailyArchiveRecord.Snapshots(
        [
            Item("事项一", TodoCategory.Today, when),
            Item("灵感一", TodoCategory.Notes, when)
        ], when);
        var today = Assert.Single(rows);
        Assert.Contains("☐ 事项一", today.TodoText);
        Assert.Equal("• 灵感一", today.NotesText);
    }

    [Fact]
    public void RendererEscapesTextAndKeepsSections()
    {
        var xml = DailyDocumentArchiveRenderer.Render(
        [
            new DailyArchiveRecord("2026-10-08", "", ""),
            new DailyArchiveRecord("2026-10-07", "已完成\n☑ 先完成\n\n未完成\n☐ A < B & C", "• <idea>")
        ]);
        Assert.StartsWith("<title>桌面随手记｜每日归档</title>", xml);
        Assert.True(xml.IndexOf("2026-10-07", StringComparison.Ordinal) < xml.IndexOf("2026-10-08", StringComparison.Ordinal));
        Assert.Contains("<checkbox done=\"true\">先完成</checkbox>", xml);
        Assert.Contains("<checkbox done=\"false\">A &lt; B &amp; C</checkbox>", xml);
        Assert.Contains("<li>&lt;idea&gt;</li>", xml);
    }

    [Fact]
    public void RendererPreservesCapturedWebpageUrlAndMultilineNotesAndTodos()
    {
        var when = new DateTime(2026, 11, 20, 4, 0, 0, DateTimeKind.Utc);
        var todos = new List<Todo>
        {
            Item("示例网页标题\nhttps://example.com/article?id=42&ref=edge", TodoCategory.Notes, when),
            Item("第一行随记\n第二行随记\n第三行随记", TodoCategory.Notes, when),
            Item("多行待办标题\n补充说明行", TodoCategory.Today, when)
        };

        var records = DailyArchiveRecord.Snapshots(todos, when);
        var xml = DailyDocumentArchiveRenderer.Render(records);

        Assert.Contains("<li>示例网页标题<br/>https://example.com/article?id=42&amp;ref=edge</li>", xml);
        Assert.Contains("<li>第一行随记<br/>第二行随记<br/>第三行随记</li>", xml);
        Assert.Contains("<checkbox done=\"false\">多行待办标题<br/>补充说明行</checkbox>", xml);
    }

    [Fact]
    public void RendererPreservesEmptyLinesIndentationAndLiteralSectionMarkers()
    {
        var when = new DateTime(2026, 11, 20, 4, 0, 0, DateTimeKind.Utc);
        var todos = new List<Todo>
        {
            Item("  缩进随记首行\n\n  缩进第二段\n• 随记正文中的圆点", TodoCategory.Notes, when),
            Item("待办首行\n\n已删除\n  后续说明缩进", TodoCategory.Today, when)
        };

        var records = DailyArchiveRecord.Snapshots(todos, when);
        var xml = DailyDocumentArchiveRenderer.Render(records);

        Assert.Contains("<li>&#160;&#160;缩进随记首行<br/><br/>&#160;&#160;缩进第二段<br/>• 随记正文中的圆点</li>", xml);
        Assert.Contains("<checkbox done=\"false\">待办首行<br/><br/>已删除<br/>&#160;&#160;后续说明缩进</checkbox>", xml);
        Assert.DoesNotContain("<li><del>&#160;&#160;后续说明缩进</del></li>", xml);
    }

    [Fact]
    public void FeishuSyncRemainsDisabledWithoutSettingsFileAndHandlesCorruptedSettings()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-feishu-default", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var store = new TodoStore(Path.Combine(directory, "todos.json"));
            Assert.Null(ArchiveSyncCoordinator.TryStart(store, directory, _ => { }));

            File.WriteAllText(Path.Combine(directory, ArchiveSettings.FileName), "{ invalid json");
            Assert.False(ArchiveSettings.TryLoad(directory, out _, out var err));
            Assert.Contains("损坏", err);

            string? status = null;
            Assert.Null(ArchiveSyncCoordinator.TryStart(store, directory, s => status = s));
            Assert.Contains("损坏", status);
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task CoordinatorResyncsLegacyV1DocumentAndSurfacesDocumentWarnings()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-docv2", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var when = new DateTime(2026, 11, 20, 4, 0, 0, DateTimeKind.Utc);
            var store = new TodoStore(Path.Combine(directory, "todos.json"), () => when);
            store.Add("旧归档待办", TodoCategory.Today);

            var snapshot = Assert.Single(DailyArchiveRecord.Snapshots(store.LoadArchive(), when));
            var syncPath = Path.Combine(directory, "sync.json");
            File.WriteAllText(syncPath, $$"""{"daily:v1:{{snapshot.DateKey}}":"{{snapshot.Fingerprint}}","document:v1":"stale-doc-fp"}""");

            var table = new FakeTable();
            var document = new FakeDocument { WarningsToReturn = ["部分嵌套样式已简化"] };
            var sync = new ArchiveSyncCoordinator(store, syncPath, table, document, _ => Task.CompletedTask, () => when);

            await sync.SyncNow();
            Assert.Equal(0, table.Calls);
            Assert.Equal(1, document.Calls);
            Assert.Contains("飞书文档提示：部分嵌套样式已简化", sync.Status);
            Assert.NotNull(ArchiveSyncCoordinator.Warning(sync.Status));
            Assert.Contains("\"document:v2\"", File.ReadAllText(syncPath));

            // 无变更再次同步检查：仍应继续保留文档降级提示，直到下次无警告写入成功
            await sync.SyncNow();
            Assert.Equal(1, document.Calls);
            Assert.Contains("飞书文档提示：部分嵌套样式已简化", sync.Status);

            // 模拟重新启动同步协调器后无变更：从持久化元数据恢复并保留提示
            var restarted = new ArchiveSyncCoordinator(store, syncPath, table, document, _ => Task.CompletedTask, () => when);
            await restarted.SyncNow();
            Assert.Equal(1, document.Calls);
            Assert.Contains("飞书文档提示：部分嵌套样式已简化", restarted.Status);

            // 有新变动且这次文档无警告写入成功：警告应清除
            document.WarningsToReturn = [];
            store.Add("无警告的新待办", TodoCategory.Today);
            await restarted.SyncNow();
            Assert.Equal(2, document.Calls);
            Assert.Equal("已保存到每日档案", restarted.Status);
            Assert.Null(ArchiveSyncCoordinator.Warning(restarted.Status));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void ValidateDocumentExtractsWarningsFromSuccessPayload()
    {
        const string json = """{"ok":true,"identity":"user","data":{"result":"success","warnings":[{"message":"空行已规范化"},"普通警告字符串"]}}""";
        var warnings = FeishuArchive.ValidateDocument(json);
        Assert.Equal(["空行已规范化", "普通警告字符串"], warnings);
    }

    [Fact]
    public void LookupAcceptsOneDateAndRejectsDuplicates()
    {
        const string empty = """{"ok":true,"identity":"user","data":{"data":[],"fields":["日期"],"field_id_list":["fldDATE"],"record_id_list":[],"has_more":false}}""";
        Assert.Null(FeishuArchive.ParseList(empty, "2026-11-16"));
        const string one = """{"ok":true,"identity":"user","data":{"data":[["2026-11-16"]],"fields":["日期"],"field_id_list":["fldDATE"],"record_id_list":["recDAILY"],"has_more":false}}""";
        Assert.Equal("recDAILY", FeishuArchive.ParseList(one, "2026-11-16"));
        const string two = """{"ok":true,"identity":"user","data":{"data":[["2026-11-16"],["2026-11-16"]],"fields":["日期"],"field_id_list":["fldDATE"],"record_id_list":["recA","recB"],"has_more":false}}""";
        Assert.Throws<ArchiveSyncException>(() => FeishuArchive.ParseList(two, "2026-11-16"));
    }

    [Fact]
    public async Task FailedTableWriteRetriesWithoutChangingLocalText()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-archive", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var when = new DateTime(2026, 11, 16, 2, 0, 0, DateTimeKind.Utc);
        var store = new TodoStore(Path.Combine(directory, "todos.json"), () => when);
        store.Add("离线也要保存");
        var transport = new FakeTable { FailFirst = true };
        var sync = new ArchiveSyncCoordinator(store, Path.Combine(directory, "sync.json"), transport, document: null, _ => Task.CompletedTask, () => when);
        await sync.SyncNow();
        Assert.Equal("本地已保存，飞书表格稍后重试", sync.Status);
        Assert.Equal("离线也要保存", store.Load().Single().Text);
        await sync.SyncNow();
        Assert.Equal("已保存到每日档案", sync.Status);
        Assert.Equal(2, transport.Calls);
        Assert.Contains("☐ 离线也要保存", transport.Last!.TodoText);
    }

    [Fact]
    public async Task UnchangedDayIsNotWrittenAgain()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-archive", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var when = new DateTime(2026, 11, 16, 2, 0, 0, DateTimeKind.Utc);
        var store = new TodoStore(Path.Combine(directory, "todos.json"), () => when);
        store.Add("事项一");
        var transport = new FakeTable();
        var sync = new ArchiveSyncCoordinator(store, Path.Combine(directory, "sync.json"), transport, document: null, _ => Task.CompletedTask, () => when);
        await sync.SyncNow();
        await sync.SyncNow();
        Assert.Equal(1, transport.Calls);
    }

    [Fact]
    public void NotesStopAtTwentyAndStillAllowTodayItems()
    {
        var directory = Path.Combine(Path.GetTempPath(), "edgetodo-archive", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var store = new TodoStore(Path.Combine(directory, "todos.json"));
        for (var i = 0; i < TodoStore.NotesLimit; i++) store.Add("随记" + i, TodoCategory.Notes);
        Assert.Throws<TodoStoreException>(() => store.Add("再来一条", TodoCategory.Notes));
        var kept = store.Load().Single(todo => todo.Text == "随记0");
        store.SaveDraft(kept.Id, "随记0已改", TodoCategory.Notes);
        store.Add("今天还能加", TodoCategory.Today);
        Assert.Equal(TodoStore.NotesLimit, TodoStore.NotesCount(store.Load()));
        Assert.Contains(store.Load(), todo => todo.Text == "今天还能加");
    }

    [Fact]
    public void CompletionHoldReturnsTheRowToItsPreviousIndex()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        var rows = new[] { first, second };
        var holds = new Dictionary<Guid, CompletionPlacement.Hold> { [second] = new(0, false) };
        var placed = CompletionPlacement.Apply(rows, id => id, holds);
        Assert.Equal([second, first], placed);
    }

    private static Todo Item(string text, TodoCategory category, DateTime created) => new()
    {
        Id = Guid.NewGuid(),
        Text = text,
        CreatedAt = created,
        Category = category,
        LastNonemptyText = text
    };

    private sealed class FakeTable : IDailyArchiveTransport
    {
        public int Calls { get; private set; }
        public bool FailFirst { get; set; }
        public DailyArchiveRecord? Last { get; private set; }

        public Task Upsert(DailyArchiveRecord record, CancellationToken cancellation)
        {
            Calls++;
            if (FailFirst)
            {
                FailFirst = false;
                throw new ArchiveSyncException("表格失败");
            }
            Last = record;
            return Task.CompletedTask;
        }
    }

    private sealed class FakeDocument : IDailyDocumentTransport
    {
        public int Calls { get; private set; }
        public IReadOnlyList<string> WarningsToReturn { get; set; } = [];

        public Task<IReadOnlyList<string>> Update(IReadOnlyList<DailyArchiveRecord> records, CancellationToken cancellation)
        {
            Calls++;
            return Task.FromResult(WarningsToReturn);
        }
    }
}
