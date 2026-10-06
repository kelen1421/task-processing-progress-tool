# 任务处理进度小工具

在其他应用工作时，也能看到 Codex 的任务进度。macOS 原生置顶浮窗，每个聊天任务独占一个圆角方框；可以缩成带环形进度的圆球，任务结束时高亮提醒。

**[下载最新版本](https://github.com/kelen1421/task-processing-progress-tool/releases/latest)** · [安装与使用说明](docs/安装与使用.txt) · [完整功能说明](docs/功能说明.md)

## 下载安装

支持 **macOS 13 及以上，Apple 芯片和 Intel Mac**。先在本机使用 Codex，软件通过本机聊天记录识别任务；无需 API 密钥。

1. 打开上面的下载页，下载 `task-processing-progress-1.7.0-macos-universal.zip`。
2. 解压，把「任务处理进度.app」拖入「应用程序」。
3. 双击打开，浮窗默认出现在屏幕右上角。

普通使用只需要应用包，无需编译、无需安装个人插件。

当前公开版本为本地临时签名，**尚未经过 Apple Developer ID 签名和公证**。如果 macOS 提示无法验证开发者，请确认下载来源，再按照 [Apple 官方说明](https://support.apple.com/zh-cn/102445)处理。双击最小化聊天窗口，需要按应用提示开启「任务处理进度」的辅助功能权限。

## 怎么使用

| 操作 | 结果 |
| --- | --- |
| 单击任务方框 | 打开该任务的聊天 |
| 双击任务方框 | 将 ChatGPT/Codex 的当前普通窗口最小化到 Dock，保留任务及固定状态 |
| 右键任务 | 固定到任务栏、取消锁定、查看进度详情 |
| 点击空白方框 | 进入已有任务，或填写新任务草稿；在 Codex 里发送后开始执行 |
| 点击浮窗右上角减号 | 缩成圆球，中心显示任务数，描边显示领先任务的进度 |
| 点击圆球 | 恢复四格浮窗 |
| 拖动窗口边缘或底部手柄 | 调整大小，重启后记住尺寸 |
| 菜单栏波形图标 | 隐藏、显示、复位或退出 |

浮窗每 3 秒刷新，任务和项目名称跟随本机 Codex 侧边栏。每页四个方框，超过四个任务可翻页。固定任务排在前面，随后优先显示进行中任务。未开始任务显示「等待中」；已完成任务显示 100%，保留到单击查看，固定任务查看后仍保留。

圆球外圈优先参考进度最高的进行中任务；有任务完成待查看时绿色高亮，直到打开对应任务。双击任务方框不会清除完成提示。

## 进度代表什么

- 有明确计划时：百分比为已完成计划步骤占比，各步骤工作量可能不同。
- 没有计划时：显示「≈」和阶段估计，准备 ≈10%、实现 ≈45%、验证 ≈75%、收尾 ≈90%。再次修改可能回到实现阶段。
- 「已完成」表示当前一轮请求结束，不保证整个项目全部完成。

这些百分比帮助判断阶段，不预测精确剩余时间。

## 隐私与兼容性

只在本机读取 Codex 的数据库、项目配置和会话记录，不上传聊天、不收集遥测、不读取登录凭据，也不修改 Codex 数据。方框标题会显示工作内容，屏幕共享时可从菜单栏隐藏。

读取位置为 `${CODEX_HOME:-~/.codex}` 中的 `state_5.sqlite`、`.codex-global-state.json` 及数据库索引的 JSONL 会话文件。这些本机数据结构会随 Codex 版本变化，升级后可能需要适配。云端且未保存到本机的聊天不在监测范围。暂不支持 Windows/Linux；部分独占全屏应用可能遮挡浮窗。

## 可选：安装到个人插件

下载 `task-processing-progress-1.7.0-codex-plugin.zip`，完整解压后双击「安装个人插件.command」。需要 Python 3 和支持 `codex plugin` 命令的 Codex CLI。安装后可在新聊天中输入「打开任务处理进度浮窗」。

该安装器只更新「任务处理进度」及其个人插件目录条目，保留其他个人插件。普通使用可以直接打开包里的应用。

## 从源码构建

需要 Apple Command Line Tools（或 Xcode）、Python 3。没有第三方运行库依赖。

```sh
git clone https://github.com/kelen1421/task-processing-progress-tool.git
cd task-processing-progress-tool
zsh build.command
python3 tests/check.py
zsh package.command --skip-build
python3 tests/check_release.py
```

构建输出为 `dist/任务处理进度.app`，包含 arm64 和 x86_64 两种架构。默认使用当前开发工具的 SDK；如 SDK 与编译器不匹配，可通过 `TASK_PROGRESS_SDK=/实际路径/MacOSX.sdk zsh build.command` 指定兼容 SDK。

`zsh install-personal.command` 从源码构建并更新个人插件；`zsh package.command` 生成应用 ZIP、插件 ZIP 和 SHA-256 校验文件。诊断命令：

```sh
'dist/任务处理进度.app/Contents/MacOS/CodexProgress' --diagnose
```

GitHub Actions 在 Apple 芯片和 Intel 两种 macOS 环境构建和测试。主分支检查通过后，如果 `VERSION` 的版本尚无 Release，会自动发布两个下载包和校验文件。发布新版本时同步修改 `VERSION`、`build.command`、两个插件清单及对应发布说明；已存在的 Release 不会被覆盖。

## 反馈与许可

欢迎在 [Issues](https://github.com/kelen1421/task-processing-progress-tool/issues)反馈问题，请附 macOS 版本、应用版本和不含私人聊天内容的错误信息。

软件可以免费下载使用。源码暂未指定开源许可证；修改和再分发授权待确认。本项目是独立制作的工具，与 OpenAI 无官方关联。
