# 随记链接来源图标

随记列表使用各网站自己提供的 favicon，不再使用应用内手绘的近似标识。2026-10-15 从本机 Edge 已缓存的官网 favicon 中提取原始图像数据，保存为 32 × 32 PNG，随应用打包；运行时不请求这些网站。

| 本地文件 | 网站提供的图标地址 |
| --- | --- |
| `youtube.png` | `https://www.youtube.com/s/desktop/e2e75771/img/favicon.ico` |
| `xiaohongshu.png` | `https://www.xiaohongshu.com/favicon.ico` |
| `bilibili.png` | `https://www.bilibili.com/favicon.ico` |

这些是网站图标，不宣称是各平台的品牌素材包或手机 App 图标。小红书图标是红底完整“小红书”字样。若打包资源缺失，界面回退显示链接域名。

手工组装 `EdgeTodo.app` 时，须把构建产物中的 `EdgeTodo_EdgeTodoApp.bundle` 一起放进 `Contents/Resources/`，与可执行文件使用同一次构建的产物。
