using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace EdgeTodo;

public enum CountdownStatus
{
    Running,
    Paused,
    Expired
}

public sealed class Countdown
{
    public CountdownStatus Mode { get; private set; }
    public DateTime? Deadline { get; private set; }
    public double PausedSeconds { get; private set; }
    public double MaximumSeconds { get; private set; }

    public static Countdown Start(double duration, DateTime now)
    {
        var seconds = Math.Max(0, duration);
        return new Countdown
        {
            Mode = CountdownStatus.Running,
            Deadline = now.AddSeconds(seconds),
            PausedSeconds = seconds,
            MaximumSeconds = seconds
        };
    }

    public double Remaining(DateTime now)
    {
        return Mode switch
        {
            CountdownStatus.Running => Math.Min(MaximumSeconds, Math.Max(0, Deadline is null ? 0 : (Deadline.Value - now).TotalSeconds)),
            CountdownStatus.Paused => Math.Max(0, PausedSeconds),
            _ => 0
        };
    }

    public CountdownStatus Status(DateTime now) =>
        Mode == CountdownStatus.Running && Remaining(now) <= 0 ? CountdownStatus.Expired : Mode;

    public bool ExpireIfNeeded(DateTime now)
    {
        if (Mode != CountdownStatus.Running || Remaining(now) > 0) return false;
        Mode = CountdownStatus.Expired;
        Deadline = null;
        PausedSeconds = 0;
        return true;
    }

    public void Pause(DateTime now)
    {
        if (Mode != CountdownStatus.Running) return;
        PausedSeconds = Remaining(now);
        Deadline = null;
        Mode = PausedSeconds > 0 ? CountdownStatus.Paused : CountdownStatus.Expired;
    }

    public void Resume(DateTime now)
    {
        if (Mode != CountdownStatus.Paused) return;
        MaximumSeconds = PausedSeconds;
        Deadline = now.AddSeconds(PausedSeconds);
        Mode = CountdownStatus.Running;
    }

    public static string Format(double remaining)
    {
        var seconds = Math.Max(0, (int)Math.Ceiling(remaining));
        var hours = seconds / 3600;
        var mins = seconds % 3600 / 60;
        var secs = seconds % 60;
        return hours > 0
            ? string.Format(CultureInfo.InvariantCulture, "{0}:{1:00}:{2:00}", hours, mins, secs)
            : string.Format(CultureInfo.InvariantCulture, "{0:00}:{1:00}", mins, secs);
    }

    internal CountdownDto ToDto() => new()
    {
        Mode = Mode switch
        {
            CountdownStatus.Paused => "paused",
            CountdownStatus.Expired => "expired",
            _ => "running"
        },
        Deadline = Deadline is null ? null : (Deadline.Value.ToUniversalTime() - TodoJson.SwiftReference).TotalSeconds,
        PausedSeconds = PausedSeconds,
        MaximumSeconds = MaximumSeconds
    };

    internal static Countdown FromDto(CountdownDto dto)
    {
        var mode = dto.Mode switch
        {
            "paused" => CountdownStatus.Paused,
            "expired" => CountdownStatus.Expired,
            _ => CountdownStatus.Running
        };
        return new Countdown
        {
            Mode = mode,
            Deadline = dto.Deadline is null ? null : DateTime.SpecifyKind(TodoJson.SwiftReference.AddSeconds(dto.Deadline.Value), DateTimeKind.Utc),
            PausedSeconds = dto.PausedSeconds,
            MaximumSeconds = dto.MaximumSeconds
        };
    }
}

internal sealed class CountdownDto
{
    public string Mode { get; set; } = "running";
    public double? Deadline { get; set; }
    public double PausedSeconds { get; set; }
    public double MaximumSeconds { get; set; }
}

public sealed class CountdownRepository
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly string _filePath;
    private readonly string _lockDirectory;
    private Dictionary<Guid, Countdown> _values;

    public CountdownRepository(string filePath)
    {
        _filePath = Path.GetFullPath(filePath);
        _lockDirectory = Path.GetDirectoryName(_filePath) ?? AppPaths.DefaultDataDirectory();
        _values = LoadFromDiskUnlocked();
    }

    public IReadOnlyCollection<Guid> Ids => _values.Keys.ToArray();
    public Countdown? this[Guid id] => _values.TryGetValue(id, out var value) ? value : null;

    /**
     * 快速检查当前内存快照中是否存在已到期的运行中倒计时，避免每秒无候选时无谓申请文件锁。
     * @param {DateTime} now 当前 UTC 时间
     * @returns {bool} 是否存在可能需要落盘标记到期的候选条目
     */
    public bool HasCandidateExpiration(DateTime now) =>
        _values.Values.Any(item => item.Mode == CountdownStatus.Running && item.Remaining(now) <= 0);

    /**
     * 在跨会话目录独占锁内先重读磁盘最新倒计时列表，再更新或删除目标条目并原子写回，避免多会话丢更新。
     * @param {Countdown?} timer 目标倒计时状态，为 null 时删除该条目
     * @param {Guid} id 待办条目标识
     */
    public void Set(Countdown? timer, Guid id)
    {
        DataDirectoryLock.Execute(_lockDirectory, () =>
        {
            var latest = LoadFromDiskUnlocked();
            if (timer is null) latest.Remove(id);
            else latest[id] = timer;
            PersistUnlocked(latest);
            _values = latest;
        });
    }

    /**
     * 在跨会话目录独占锁内读取磁盘上目标条目的最新状态并执行状态转换，仅在状态实际变更时原子写回。
     * @param {Guid} id 待办条目标识
     * @param {Func<Countdown?, Countdown?>} transform 基于磁盘最新状态计算目标状态的回调
     * @returns {bool} 是否发生了磁盘写回或内存快照同步变更
     */
    public bool Update(Guid id, Func<Countdown?, Countdown?> transform)
    {
        return DataDirectoryLock.Execute(_lockDirectory, () =>
        {
            var latest = LoadFromDiskUnlocked();
            latest.TryGetValue(id, out var current);
            var before = current?.ToDto();
            var next = transform(current);
            var after = next?.ToDto();
            var changedOnDisk = !AreSame(before, after);
            if (changedOnDisk)
            {
                if (next is null) latest.Remove(id);
                else latest[id] = next;
                PersistUnlocked(latest);
            }
            var snapshotChanged = changedOnDisk || !AreSameMap(_values, latest);
            _values = latest;
            return snapshotChanged;
        });
    }

    /**
     * 在单次跨会话目录独占锁内重读磁盘最新倒计时列表，仅对磁盘上真正已到期的条目落盘，防止旧缓存覆写另一实例重启后的新状态。
     * @param {DateTime} now 当前 UTC 时间
     * @returns {bool} 是否有条目新近到期落盘或本地快照因他端更新而发生变化
     */
    public bool RefreshExpired(DateTime now)
    {
        return DataDirectoryLock.Execute(_lockDirectory, () =>
        {
            var latest = LoadFromDiskUnlocked();
            var expiredAny = false;
            foreach (var item in latest.Values)
            {
                if (item.ExpireIfNeeded(now)) expiredAny = true;
            }
            if (expiredAny) PersistUnlocked(latest);
            var snapshotChanged = expiredAny || !AreSameMap(_values, latest);
            _values = latest;
            return snapshotChanged;
        });
    }

    /**
     * 在单次跨会话目录独占锁内重读最新待办与倒计时列表，仅保留仍属于未完成今日待办的倒计时并原子写回。
     * @param {string} todosFilePath todos.json 文件路径
     * @returns {bool} 是否发生了实际删除并写盘
     */
    public bool RetainActiveFromTodos(string todosFilePath)
    {
        return DataDirectoryLock.Execute(_lockDirectory, () =>
        {
            var activeIds = TodoStore.ReadActiveTodayIdsUnlocked(todosFilePath);
            var latest = LoadFromDiskUnlocked();
            var removed = false;
            foreach (var id in latest.Keys.ToArray())
            {
                if (!activeIds.Contains(id))
                {
                    latest.Remove(id);
                    removed = true;
                }
            }
            if (removed) PersistUnlocked(latest);
            _values = latest;
            return removed;
        });
    }

    /**
     * 在单次跨会话目录独占锁内重读最新倒计时列表，仅保留仍处于活跃集合内的条目并原子写回。
     * @param {IReadOnlySet<Guid>} ids 允许保留的未完成今日待办标识集合
     * @returns {bool} 是否发生了实际删除并写盘
     */
    public bool Retain(IReadOnlySet<Guid> ids)
    {
        return DataDirectoryLock.Execute(_lockDirectory, () =>
        {
            var latest = LoadFromDiskUnlocked();
            var removed = false;
            foreach (var id in latest.Keys.ToArray())
            {
                if (!ids.Contains(id))
                {
                    latest.Remove(id);
                    removed = true;
                }
            }
            if (removed) PersistUnlocked(latest);
            _values = latest;
            return removed;
        });
    }

    private static bool AreSame(CountdownDto? a, CountdownDto? b)
    {
        if (a is null && b is null) return true;
        if (a is null || b is null) return false;
        return a.Mode == b.Mode
            && a.Deadline == b.Deadline
            && a.PausedSeconds == b.PausedSeconds
            && a.MaximumSeconds == b.MaximumSeconds;
    }

    private static bool AreSameMap(Dictionary<Guid, Countdown> left, Dictionary<Guid, Countdown> right)
    {
        if (left.Count != right.Count) return false;
        foreach (var pair in left)
        {
            if (!right.TryGetValue(pair.Key, out var other)) return false;
            if (!AreSame(pair.Value.ToDto(), other.ToDto())) return false;
        }
        return true;
    }

    private Dictionary<Guid, Countdown> LoadFromDiskUnlocked()
    {
        string content;
        try
        {
            content = File.ReadAllText(_filePath);
        }
        catch (FileNotFoundException)
        {
            return [];
        }
        catch (DirectoryNotFoundException)
        {
            return [];
        }
        var raw = JsonSerializer.Deserialize<Dictionary<string, CountdownDto>>(content, JsonOptions) ?? [];
        return raw.ToDictionary(pair => Guid.Parse(pair.Key), pair => Countdown.FromDto(pair.Value));
    }

    private void PersistUnlocked(Dictionary<Guid, Countdown> values)
    {
        var payload = values.ToDictionary(pair => pair.Key.ToString("D").ToUpperInvariant(), pair => pair.Value.ToDto());
        AtomicFile.WriteAllText(_filePath, JsonSerializer.Serialize(payload, JsonOptions));
    }
}

public sealed class CountdownManager
{
    private readonly CountdownRepository? _repository;
    private readonly string _todosFilePath;
    public string? Error { get; private set; }
    public event Action? Changed;

    public CountdownManager(string filePath)
    {
        _todosFilePath = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(filePath)) ?? "", "todos.json");
        try
        {
            _repository = new CountdownRepository(filePath);
        }
        catch (Exception ex)
        {
            _repository = null;
            Error = "读取倒计时失败：" + ex.Message;
        }
    }

    public Countdown? Timer(Guid id) => _repository?[id];

    public void Set(Countdown? countdown, Guid id)
    {
        if (_repository is null) return;
        try
        {
            _repository.Set(countdown, id);
            Error = null;
            Changed?.Invoke();
        }
        catch (Exception ex)
        {
            Error = "保存倒计时失败：" + ex.Message;
            Changed?.Invoke();
        }
    }

    public void Start(double seconds, Guid id) => Set(Countdown.Start(seconds, DateTime.UtcNow), id);

    /**
     * 在文件锁内基于磁盘最新状态暂停指定待办的倒计时，避免旧内存缓存覆盖他端新状态。
     * @param {Guid} id 待办条目标识
     */
    public void Pause(Guid id) => Pause(id, DateTime.UtcNow);

    /**
     * 在文件锁内基于指定时间与磁盘最新状态暂停指定待办的倒计时。
     * @param {Guid} id 待办条目标识
     * @param {DateTime} now 当前 UTC 时间
     */
    public void Pause(Guid id, DateTime now)
    {
        if (_repository is null) return;
        try
        {
            var changed = _repository.Update(id, current =>
            {
                if (current is null) return null;
                current.Pause(now);
                return current;
            });
            if (changed)
            {
                Error = null;
                Changed?.Invoke();
            }
        }
        catch (Exception ex)
        {
            Error = "保存倒计时失败：" + ex.Message;
            Changed?.Invoke();
        }
    }

    /**
     * 在文件锁内基于磁盘最新状态继续指定待办的倒计时，避免旧内存缓存覆盖他端新状态。
     * @param {Guid} id 待办条目标识
     */
    public void Resume(Guid id) => Resume(id, DateTime.UtcNow);

    /**
     * 在文件锁内基于指定时间与磁盘最新状态继续指定待办的倒计时。
     * @param {Guid} id 待办条目标识
     * @param {DateTime} now 当前 UTC 时间
     */
    public void Resume(Guid id, DateTime now)
    {
        if (_repository is null) return;
        try
        {
            var changed = _repository.Update(id, current =>
            {
                if (current is null) return null;
                current.Resume(now);
                return current;
            });
            if (changed)
            {
                Error = null;
                Changed?.Invoke();
            }
        }
        catch (Exception ex)
        {
            Error = "保存倒计时失败：" + ex.Message;
            Changed?.Invoke();
        }
    }

    /**
     * 当检测到本地快照存在候选到期条目时，在文件锁内重读磁盘最新状态决定是否落盘到期，避免旧缓存覆写他端新启动的倒计时。
     * @param {DateTime} now 当前 UTC 时间
     */
    public void RefreshExpired(DateTime now)
    {
        if (_repository is null || !_repository.HasCandidateExpiration(now)) return;
        try
        {
            if (_repository.RefreshExpired(now))
            {
                Error = null;
                Changed?.Invoke();
            }
        }
        catch (Exception ex)
        {
            Error = "保存倒计时失败：" + ex.Message;
            Changed?.Invoke();
        }
    }

    /**
     * 在单次目录独占锁内重读磁盘最新待办与倒计时列表，清理不再活跃的倒计时，避免旧待办缓存误删他端新增的倒计时。
     */
    public void RetainActive()
    {
        if (_repository is null) return;
        try
        {
            if (_repository.RetainActiveFromTodos(_todosFilePath))
            {
                Error = null;
                Changed?.Invoke();
            }
        }
        catch (Exception ex)
        {
            Error = "保存倒计时失败：" + ex.Message;
            Changed?.Invoke();
        }
    }
}
