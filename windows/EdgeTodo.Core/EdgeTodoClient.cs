using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace EdgeTodo;

/**
 * 本地命名管道查询结果状态。
 */
public enum PipeQueryStatus
{
    Responded,
    NotListening,
    Failed
}

/**
 * 本地命名管道详细查询结果，明确区分“无人监听”与“实例在运行但通信失败”。
 */
public sealed record PipeQueryResult(PipeQueryStatus Status, string? Output, string? Error);

/**
 * 进程间通信封装，按物理数据目录隔离互斥锁与命名管道，限制仅当前用户访问并严格控制消息大小与超时。
 */
public static class EdgeTodoClient
{
    public const string PipePrefix = "EdgeTodo.Activation.";
    public const string MutexPrefix = @"Local\EdgeTodo.SingleInstance.";
    public const string StoreMutexPrefix = @"Local\EdgeTodo.Store.";
    public const int MaxLineBytes = 256 * 1024;
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromMilliseconds(3000);
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

    private sealed record ActivationEnvelope(string DataDirectory, string Payload);

    /**
     * 根据规范化后的数据目录生成专属命名管道名称。
     * @param {string} dataDirectory 数据目录路径
     * @returns {string} 专属管道名
     */
    public static string PipeNameFor(string dataDirectory) => PipePrefix + AppPaths.DirectoryKey(dataDirectory);

    /**
     * 根据规范化后的数据目录生成专属单实例互斥锁名称。
     * @param {string} dataDirectory 数据目录路径
     * @returns {string} 专属互斥锁名
     */
    public static string MutexNameFor(string dataDirectory) => MutexPrefix + AppPaths.DirectoryKey(dataDirectory);

    /**
     * 根据规范化后的数据目录生成专属跨进程数据文件锁名称。
     * @param {string} dataDirectory 数据目录路径
     * @returns {string} 专属存储互斥锁名
     */
    public static string StoreMutexNameFor(string dataDirectory) => StoreMutexPrefix + AppPaths.DirectoryKey(dataDirectory);

    /**
     * 将业务载荷打包为包含目标数据目录身份的单行 JSON 信封。
     * @param {string} dataDirectory 目标数据目录路径
     * @param {string} payload 业务指令或 URI 载荷
     * @returns {string} 序列化后的信封字符串
     */
    public static string WrapRequest(string dataDirectory, string payload) =>
        JsonSerializer.Serialize(new ActivationEnvelope(AppPaths.NormalizeDirectory(dataDirectory), payload));

    /**
     * 校验收到的通信信封是否与当前实例的数据目录匹配。
     * @param {string} rawLine 接收到的单行消息
     * @param {string} expectedDataDirectory 当前实例的数据目录路径
     * @param {out string} payload 解析出的真实业务载荷
     * @returns {bool} 是否校验通过且目录一致
     */
    public static bool TryUnwrapRequest(string rawLine, string expectedDataDirectory, out string payload)
    {
        payload = "";
        if (string.IsNullOrEmpty(rawLine) || Utf8NoBom.GetByteCount(rawLine) > MaxLineBytes) return false;
        try
        {
            var envelope = JsonSerializer.Deserialize<ActivationEnvelope>(rawLine);
            if (envelope is null || string.IsNullOrWhiteSpace(envelope.DataDirectory)) return false;
            var expected = AppPaths.NormalizeDirectory(expectedDataDirectory);
            var actual = AppPaths.NormalizeDirectory(envelope.DataDirectory);
            if (!string.Equals(actual, expected, StringComparison.OrdinalIgnoreCase)) return false;
            payload = envelope.Payload ?? "";
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /**
     * 检查目标数据目录是否已有桌面端主实例正在运行。
     * @param {string} dataDirectory 目标数据目录
     * @returns {bool} 主实例互斥锁是否已存在
     */
    public static bool IsPrimaryRunning(string dataDirectory)
    {
        try
        {
            if (Mutex.TryOpenExisting(MutexNameFor(dataDirectory), out var existing))
            {
                existing.Dispose();
                return true;
            }
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return true;
        }
        catch
        {
            return false;
        }
    }

    /**
     * 在指定超时和字节上限内从管道流读取单行文本，防止恶意超长行或阻塞读死。
     * @param {Stream} stream 已连接的管道流
     * @param {CancellationToken} cancellation 取消令牌
     * @returns {Task<string?>} 完整单行文本；若对端关闭且无数据则返回 null；超限返回 null
     */
    public static async Task<string?> ReadBoundedLineAsync(Stream stream, CancellationToken cancellation)
    {
        var buffer = new byte[1];
        using var ms = new MemoryStream();
        while (true)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(0, 1), cancellation).ConfigureAwait(false);
            if (read == 0)
                return ms.Length == 0 ? null : Utf8NoBom.GetString(ms.ToArray());

            var b = buffer[0];
            if (b == (byte)'\n')
            {
                var bytes = ms.ToArray();
                var len = bytes.Length > 0 && bytes[^1] == (byte)'\r' ? bytes.Length - 1 : bytes.Length;
                return Utf8NoBom.GetString(bytes, 0, len);
            }

            if (ms.Length >= MaxLineBytes)
                throw new InvalidDataException("通信消息超过长度限制。");
            ms.WriteByte(b);
        }
    }

    /**
     * 向指定数据目录对应的运行中桌面实例发送命令行或激活请求，明确区分「无人监听」与「实例正忙/超时」。
     * @param {string} dataDirectory 目标数据目录
     * @param {string} line 待发送的指令载荷
     * @param {TimeSpan?} timeout 单次连接与读写总超时，默认 3 秒
     * @returns {PipeQueryResult} 查询结果（Responded / NotListening / Failed）
     */
    public static PipeQueryResult QueryDetailed(string dataDirectory, string line, TimeSpan? timeout = null)
    {
        var wrapped = WrapRequest(dataDirectory, line);
        if (Utf8NoBom.GetByteCount(wrapped) > MaxLineBytes)
            return new PipeQueryResult(PipeQueryStatus.Failed, null, "请求内容过长，无法通过本地管道发送。");

        var connected = false;
        var effectiveTimeout = timeout ?? DefaultTimeout;
        try
        {
            using var cts = new CancellationTokenSource(effectiveTimeout);
            using var client = new NamedPipeClientStream(".", PipeNameFor(dataDirectory), PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            client.ConnectAsync(cts.Token).GetAwaiter().GetResult();
            connected = true;

            using var writer = new StreamWriter(client, Utf8NoBom, leaveOpen: true) { AutoFlush = true };
            writer.WriteLineAsync(wrapped.AsMemory(), cts.Token).GetAwaiter().GetResult();
            writer.FlushAsync(cts.Token).GetAwaiter().GetResult();

            var response = ReadBoundedLineAsync(client, cts.Token).GetAwaiter().GetResult();
            if (string.IsNullOrWhiteSpace(response))
                return new PipeQueryResult(PipeQueryStatus.Failed, null, "桌面端未返回有效响应，为避免数据冲突已取消直接写盘，请稍后重试。");

            return new PipeQueryResult(PipeQueryStatus.Responded, response, null);
        }
        catch (Exception)
        {
            if (!connected && !IsPrimaryRunning(dataDirectory))
                return new PipeQueryResult(PipeQueryStatus.NotListening, null, null);
            return new PipeQueryResult(PipeQueryStatus.Failed, null, "桌面端正忙或本地通信超时，为避免覆盖数据未直接写盘，请稍后重试。");
        }
    }

    /**
     * 向指定数据目录对应的运行中桌面实例发送激活或指令消息（不等待业务结果但受限超时和同用户校验）。
     * @param {string} dataDirectory 目标数据目录
     * @param {string} message 激活消息文本
     * @param {TimeSpan?} timeout 通信超时时间
     */
    public static void Notify(string dataDirectory, string message, TimeSpan? timeout = null)
    {
        var wrapped = WrapRequest(dataDirectory, message);
        if (Utf8NoBom.GetByteCount(wrapped) > MaxLineBytes) return;
        try
        {
            using var cts = new CancellationTokenSource(timeout ?? DefaultTimeout);
            using var client = new NamedPipeClientStream(".", PipeNameFor(dataDirectory), PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            client.ConnectAsync(cts.Token).GetAwaiter().GetResult();
            using var writer = new StreamWriter(client, Utf8NoBom, leaveOpen: true) { AutoFlush = true };
            writer.WriteLineAsync(wrapped.AsMemory(), cts.Token).GetAwaiter().GetResult();
            writer.FlushAsync(cts.Token).GetAwaiter().GetResult();
            _ = ReadBoundedLineAsync(client, cts.Token).GetAwaiter().GetResult();
        }
        catch
        {
        }
    }

    /**
     * 向指定数据目录对应的运行中桌面实例发送请求，仅当实例正常返回时给出输出文本。
     * @param {string} dataDirectory 目标数据目录
     * @param {string} line 待发送的指令载荷
     * @returns {string?} 桌面端响应内容；若未响应则返回 null
     */
    public static string? Query(string dataDirectory, string line)
    {
        var result = QueryDetailed(dataDirectory, line);
        return result.Status == PipeQueryStatus.Responded ? result.Output : null;
    }
}
