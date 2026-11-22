# 一角（Windows 版）

本目录是「一角」（Edge Todo）的 Windows 桌面端实现，基于 **.NET 10** 与 WPF 构建，与仓库现有的浏览器收藏扩展（`../browser/extension`）及飞书每日归档格式保持兼容。

如果你希望由 AI 助手为你自动安装配置（包括引导选择 Edge / Chrome、创建隔离数据目录与可选开启飞书同步），直接对 AI 说「**帮我配置这个项目**」，AI 会按 [AGENTS.md](./AGENTS.md) 执行。

## 1. 目录结构

- [EdgeTodo.sln](./EdgeTodo.sln)：Windows 解决方案文件
- [EdgeTodo.Core](./EdgeTodo.Core)：核心领域逻辑、待办/随记存储、倒计时、多实例目录隔离、`edgetodo://` 浏览器协议捕获及飞书每日档案同步
- [EdgeTodo.App](./EdgeTodo.App)：WPF 屏幕边缘悬浮面板桌面程序（输出程序名 `EdgeTodo.exe`）
- [EdgeTodo.Cli](./EdgeTodo.Cli)：命令行辅助工具（输出程序名 `EdgeTodoCmd.exe`）
- [EdgeTodo.Core.Tests](./EdgeTodo.Core.Tests)：核心逻辑与归档同步单元测试
- [package-win.ps1](./package-win.ps1)：一键打包发布 Windows 客户端与 CLI
- [configure-data-dir.ps1](./configure-data-dir.ps1)：为指定应用副本绑定独立数据目录与协议策略
- [AGENTS.md](./AGENTS.md)：面向 AI 助手的 Windows 安装与验收工作流说明

## 2. 构建与运行（.NET 10）

确保本机已安装 Microsoft .NET 10 SDK（Windows），在仓库根目录执行相对路径命令：

```powershell
# 编译并运行单元测试
dotnet build ./windows/EdgeTodo.sln -c Release
dotnet test ./windows/EdgeTodo.sln -c Release --no-build

# 一键发布到相对目录 ./dist/windows，并安全绑定独立数据目录（不主动抢占已有的 edgetodo:// 主入口）
powershell -ExecutionPolicy Bypass -File ./windows/package-win.ps1
powershell -ExecutionPolicy Bypass -File ./windows/configure-data-dir.ps1 -AppDir ./dist/windows -DataDir ../EdgeTodo数据

# 仅当确认由该新副本接管全局浏览器收藏入口时，再显式注册协议（覆盖旧版请追加 -ForceRegisterProtocol）
powershell -ExecutionPolicy Bypass -File ./windows/configure-data-dir.ps1 -AppDir ./dist/windows -DataDir ../EdgeTodo数据 -RegisterProtocol
```

启动 `./dist/windows/EdgeTodo.exe` 后，程序常驻系统托盘，并在屏幕左侧边缘提供悬浮小把手：
- 鼠标移入屏幕左侧把手停留约 `0.18s` 自动展开，移开约 `0.25s` 自动收起；
- 支持快捷键 `Ctrl+Shift+O` 或双击托盘图标在鼠标所在显示器展开面板；
- 点击面板右上角图钉可固定在桌面并启用毛玻璃透明材质；
- 在「今日待办」某条待办上右键可选择「移到随记」；随记达到 20 条上限时会提示已满并保留原待办。

## 3. 多版本数据与协议隔离

- **数据目录解析优先级**：
  1. 命令行参数 `--data-dir "<目录>"`
  2. 环境变量 `EDGE_TODO_DATA_DIRECTORY`
  3. 应用同目录下的配置文件 `edgetodo-config.json`（`dataDirectory` 字段）
  4. 默认路径 `%LOCALAPPDATA%\EdgeTodo`
  - 当命令行参数为空、`edgetodo-config.json` 损坏或格式非法时，程序直接报错停止，**绝不会静默回退到默认目录**。
- **隔离机制**：单实例互斥锁、跨进程数据存储锁与本地通信命名管道均基于规范化后的**物理数据目录路径哈希**生成，限制仅当前 Windows 用户访问，并在通信载荷中强校验目标目录一致性。不同数据目录的桌面应用与 `EdgeTodoCmd.exe` 可同时运行且互不串线；若同目录桌面端在线但通信超时，CLI 会拒绝盲目直接写盘，防止并发覆盖。
- **浏览器入口保护**：若本机注册表中 `edgetodo://` 已指向其他现存版本的 `EdgeTodo.exe` 或同一程序绑定的其他数据目录（或原有命令行无法解析），未明确指定 `-ForceRegisterProtocol` / `--register-protocol` 启动的测试副本**绝不会覆盖**原有浏览器收藏入口。

## 4. 飞书每日归档（默认关闭）

- 程序默认**不开启**飞书同步，所有待办、随记与网页链接仅保存在本机数据目录（`todos.json`、`countdowns.json`、`settings.json`）。
- 仅在用户主动选择开启并完成飞书授权后，由 AI 创建专用多维表格与专用空白飞书云文档，并在数据目录写入 `feishu-settings.json`。
- 同步时，**专用飞书云文档会被程序整篇覆盖更新**（通过 `document:v2` 渲染，完整保留带标题网页链接、URL、多行正文缩进、空行及项目符号）；断网时本地照常保存，恢复联网后自动补同步。

## 5. 命令行工具用法

当对应数据目录的桌面程序正在托盘运行时，`EdgeTodoCmd.exe` 会精准通知该数据目录的实例并实时刷新界面；未运行时直接读写对应数据目录：

```powershell
# 操作默认目录或配置目录
./dist/windows/EdgeTodoCmd.exe list
./dist/windows/EdgeTodoCmd.exe add today 待办内容
./dist/windows/EdgeTodoCmd.exe add notes 随记内容
./dist/windows/EdgeTodoCmd.exe done <id>
./dist/windows/EdgeTodoCmd.exe undo <id>
./dist/windows/EdgeTodoCmd.exe delete <id>
./dist/windows/EdgeTodoCmd.exe move <id> today|notes

# 显式指定目标数据目录（互不干扰）
./dist/windows/EdgeTodoCmd.exe --data-dir ../EdgeTodo数据 list
```
