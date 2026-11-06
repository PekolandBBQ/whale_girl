# macOS 实验版

原生 SwiftUI 启动器 + 现有 Node 内核 + 微信界面文字桥接。需要 macOS 14 或更高版本。
这是独立的 Mac 启动器，不能把 WPF 的 `WhaleLauncher.exe` 直接编译成 Mac 应用。

## 当前支持范围

- 模型地址、模型名称和 API Key 配置，内核启动/停止，退出应用时关闭子进程。
- 自带 Node 24.22.2，无 npm 运行时依赖；未填 Key 时可启动内核演示模式。
- 一个当前打开的**私聊**，只回复启用桥接之后出现的新文字消息。
- 使用 macOS Accessibility 读取界面、截图判断消息方向，通过输入框和定向到微信进程的 Return 按键发送。
- **不注入代码、不修改微信进程、不提取数据库密钥、不读取微信数据库、不模拟私有协议。**
- 界面读取依赖 [dustin573/wechat-mcp](https://github.com/dustin573/wechat-mcp)，固定到 `c6c600ae068c113224f984656db40f8cec4d0164`；只复用可见消息解析，未调用其搜索、切换会话、历史滚动或发送工具。

暂不支持群聊、后台跨会话监听、图片/表情包/语音发送、主动关怀、提醒投递和 Windows 启动器全部设置页。
不要把群聊填进私聊名称：此版本没有可靠的群类型识别或群成员身份映射。
本地已验证编译、启动器启停和模拟桥接；**开发验证环境未安装微信，真实微信收发尚待验收**。
上游界面适配器针对微信 4.x，但这不等于本实现已经通过某个具体微信版本的兼容性测试。
UI 自动化也可能触发微信风控，不能承诺不封号。

## 构建与运行

安装 Xcode Command Line Tools 后，在源码根目录执行：

```bash
bash scripts/build-macos.sh
```

脚本从 Node 官方站点下载当前架构运行时，验证官方 SHA256 清单，编译 SwiftUI 应用，生成：

- Intel：`dist/WhaleGirl-x64.app`、`dist/WhaleGirl-macos-x64.zip`
- Apple Silicon：`dist/WhaleGirl-arm64.app`、`dist/WhaleGirl-macos-arm64.zip`

脚本拒绝覆盖已有 `.app`；重建前先移走旧产物。CI `macos.yml` 分别在 Intel/Apple Silicon 上构建并上传 ZIP。
当前使用 ad-hoc 签名，**未使用 Developer ID 签名或 Apple 公证**，下载包可能被 Gatekeeper 拦截。
生产发布前需要维护者完成签名、公证和真实微信测试，不应宣传为已完成正式 Mac 发布。
解压后将应用放入固定位置（如 Applications），再授予权限；更新应用后 macOS 可能要求重新授权。

## 安装微信桥接环境

1. 自行安装并登录 Mac 微信，打开要接入的私聊。
2. 按 [uv 官方安装说明](https://docs.astral.sh/uv/getting-started/installation/) 安装 uv。
3. 在启动器中点击「安装桥接环境」。这会联网下载 Python 3.12 和固定版本的桥接源码及依赖。
   源码模式也可以运行 `bash scripts/setup-macos-bridge.sh`。
4. 在「系统设置 → 隐私与安全性」中，为鲸鲸及系统实际提示的宿主授予**辅助功能**和**屏幕录制**权限，然后彻底退出并重开鲸鲸。
5. 配置模型并启动内核，填写与微信会话标题完全一致的私聊名称。
6. 勾选私聊自动回复确认，点击「启用微信桥接」，在 5 秒内切回该微信私聊。
7. 保持微信在前台、聊天滚到最新消息、输入框留空。开启后让测试联系人发送一条新文字，观察只回复一次。

桥接只读取屏幕上可见的消息；不主动切换或滚动会话。历史回滚、可见消息失去重合锚点、未知消息方向会停止桥接。
重复且完全相同的界面快照无法区分为新消息，可能漏回；这比重复回复历史消息更安全。
窗口失焦、切换会话、已有草稿、模型调用超时或发送未确认也会停止，需用户重新启用；重新启用会建立新基线，不补发旧消息。
发送确认仅表示在界面看到新增的己方消息气泡，**不表示服务端送达或对方已读**。
若发送后未确认，检查微信是否留下草稿，手动决定如何处理，不要盲目重复发送。

## 数据与权限

数据位于 `~/Library/Application Support/WhaleGirl/`：

- `data/settings.json`：模型配置（含 API Key，文件权限 0600；不使用 Keychain）
- `config.json`：随机本机桥接令牌和内核配置
- `data/`：既有内核的记忆及日志；隐私规则见根目录 `PRIVACY.md`
- `macos.json`：私聊名称与桥接 Python 路径
- `bridge-venv/`：独立 Python 环境；`bridge-install.log`：安装输出

替换 `.app` 不覆盖上述目录。卸载应用不自动删除聊天记忆或 Key；如需彻底清除，在退出应用后自行删除数据目录。
内核仅绑定 `127.0.0.1` 的随机端口，沿用原有 Token、Origin 和远程访问检查，无网页界面。
桥接不保存截图或附件，不输出消息正文；进入模型的消息仍遵循内核已有的模型调用与记忆处理行为。
macOS 没有原子性的「检查会话并发送」操作，输入前后检查只能缩小竞态，无法保证用户同时操作微信时绝不误发。

## 验证

```bash
node tests/macos-bridge.test.js
node tests/macos-host.test.js
python3 -m unittest discover -s tests/macos -v
```

全量 Node 回归还需 Python 3.12、requests、Pillow、cryptography。macOS 下使用真实临时目录（系统 `/var` 是软链）：

```bash
export TMPDIR="$(python3 -c 'import os,tempfile; print(os.path.realpath(tempfile.gettempdir()))')"
export USERNAME="$USER"
npm test
```

发 PR 保持 Draft，直到安装微信并补齐：确切微信版本、权限拒绝、启动不回复历史、私聊新增消息只回复一次、已有草稿不覆盖、切换会话停止、回读未确认不重发、退出不残留进程。
