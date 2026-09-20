# Harbor SSH

面向 **Windows、macOS、Android** 的 Flutter SSH 客户端首版。可实际连接 SSH 服务器，桌面与手机共用一套代码。

界面采用 **Material 3 Expressive（M3E）**：Expressive 色板、强调排版、非对称圆角标题区、分组列表、胶囊按钮与按压形变。主机卡片提供弹簧按压反馈、悬停状态和键盘焦点边框，并遵循系统减少动画设置。桌面使用侧栏和卡片，手机使用底部导航与单一新建按钮；支持浅色、深色及 200% 系统字体。

## 已实现

- 主机新增、编辑、删除、收藏、分组及搜索，配置保存在本机。
- 密码、PEM/OpenSSH 私钥和加密私钥口令认证。
- 填写的密码和私钥自动保存到系统安全存储；已信任指纹同样安全存储，不写入普通配置。
- 首次连接显示服务器 SHA256 指纹；后续指纹变化时拒绝连接，核实后可手动重置。
- 多会话标签、ANSI 终端、UTF-8、PTY 尺寸同步、保活、断开及手动重连。
- 终端复制、粘贴、字体大小调整；工具栏/快捷键的多行粘贴先显示内容确认。
- 手机提供 Esc、Tab、Ctrl C/D/L、方向键辅助栏。
- 深浅色响应式布局、桌面侧栏、手机底部导航、抽屉分组与分组筛选。
- WebDAV / GitHub Gist 加密云同步：连接、分组、收藏及凭证，支持手动/自动同步和冲突选择。
- SSH 终端 AI 任务：输入目标，自主执行命令、读取结果并继续处理，支持随时停止。

当前不包含跳板机、端口转发、SSH agent、交互式 MFA 和后台常驻连接。Android 后台连接可能被系统暂停；断开后可重新连接。

## 终端 AI

在「设置 → AI」选择服务商，预设包括 OpenAI、Anthropic、OpenCode、CommandCode、DeepSeek、通义千问、Moonshot、硅基流动及 Ollama，会自动填入 API 地址和接口类型。填写 API Key 与支持工具调用的模型名称后保存，也可选择「自定义」接入代理服务。切换厂商不会把原厂商的 Key 自动带到新厂商。

OpenCode 使用 [Zen API](https://opencode.ai/docs/zen/)（`https://opencode.ai/zen/v1`），CommandCode 使用 [Provider API](https://commandcode.ai/docs/provider)（`https://api.commandcode.ai/provider/v1`）。均可通过模型旁的「获取」读取模型列表，默认使用 OpenAI Chat Completions；使用 Claude 时将接口类型切换为「Anthropic 兼容」。模型须支持所选接口及工具调用：OpenCode 的 GPT 等仅提供 Responses 接口的模型目前不能使用，模型列表中出现不代表应用已支持该模型的接口。

接口类型支持 **OpenAI 兼容（Chat Completions）** 和 **Anthropic 兼容（Messages）**，均支持自主任务所需的工具调用与执行结果回传。地址可填写服务根地址、含 `/v1` 的地址，或完整 `/chat/completions`、`/messages` 地址。本机 Ollama 默认使用 `http://localhost:11434/v1`，Key 可留空。配置保存在当前设备的系统安全存储，不参与云同步；已有配置继续使用 OpenAI 兼容格式。

填写地址和 API Key 后，点击模型旁的「获取」读取可用模型并展开列表，可输入文字筛选后选择。获取使用当前尚未保存的配置，不需要预先填写模型名称；Anthropic 列表会自动翻页。服务不支持模型列表时仍可手动填写，获取失败不会覆盖原模型。

连接 SSH 后，点击终端顶部的 AI 图标，在当前 SSH 窗口内展开 AI 面板：宽屏左右排列，窄屏上下排列，不遮挡其他会话。输入消息并点击输入框右侧的发送按钮。AI 会通过当前 SSH 连接的独立执行通道处理任务；面板显示命令、实时输出、退出码与总结，原有交互终端仍可操作。任务目标、AI 执行的命令及其输出会发给所配置的模型服务；不会自动附带原终端的滚屏记录或 SSH 凭据。

输入区支持选择图片、粘贴截图（桌面 Ctrl+V / macOS Cmd+V，手机使用粘贴菜单）和拖入图片。图片先显示为可移除的缩略图，点击发送后才随消息提交给当前配置的模型服务，支持纯图片或图文消息；图片仅保存在当前面板记录中，不写入云同步。支持 PNG、JPEG、WebP 和静态 GIF，每条消息最多 4 张，单张不超过 5 MB，总大小不超过 12 MB。模型需要同时支持图片输入和工具调用；OpenAI 兼容接口使用图片 data URL，Anthropic 兼容接口使用 base64 图片内容块。新增系统插件后需重新构建并启动应用，截图粘贴和桌面拖放才能生效。

普通检查和任务所需的可逆操作可自动执行。模型标记为高影响的操作以及应用识别出的常见删除、覆盖、提权等命令，会先显示具体命令供确认。此检查不是 shell 沙箱；执行权限仍由 SSH 登录账号决定。取消确认会终止任务。点击「停止」、关闭 AI 面板或断开 SSH 都会取消后续步骤，并对当前执行通道请求终止；服务器是否停止已派生的进程取决于远端实现。

同一 SSH 会话内支持连续对话，追问会携带之前的文字、图片、模型回复和命令结果。关闭再打开 AI 面板仍可续聊；顶部「新对话」按钮会清空当前记录与上下文。对话只保存在内存中，不写入云同步，关闭该 SSH 会话或退出应用后不保留。停止或出错后可继续发送消息，未完成的命令会记录为未执行或执行结果待确认，迟到的响应不会影响新一轮。

每条命令使用独立非交互 shell，从登录目录启动，目录和环境变量不跨命令保留。每轮最多执行 24 条命令，每条最长 60 秒，输出保留最多 16000 字符。处理过程中以紧凑状态行显示思考、执行、整理结果或等待确认，并显示本轮耗时；启用系统减少动画时关闭呼吸动效。

## 云同步

设置 → 云同步中可选择 WebDAV 或 GitHub Gist。

### GitHub Gist

选择「GitHub Gist」→「网页登录」，应用先自动复制验证码，再打开系统浏览器中的 GitHub 设备授权页面。在网页粘贴并授权后，应用自动保存登录凭据并显示 GitHub 用户名；不需要手动创建或粘贴 Token。验证码旁的复制图标可再次复制，剪贴板不可用时仍可手动输入。等待期间可取消，验证码过期或拒绝授权后可重试。「退出登录」清除本机 GitHub 凭据并关闭 Gist 自动同步，不删除云端 Gist；要撤销 GitHub 上的授权，可在 GitHub 的 Settings → Applications → Authorized OAuth Apps 中操作。

设置至少 12 个字符的同步加密密码。点击「保存并同步」时，应用自动查找当前 GitHub 账号下包含 `harbor-ssh-sync.v1.json` 的存档；没有存档则创建 Secret Gist 并记住位置，无需填写或记忆 Gist ID。「测试连接」只检查登录和存档读取访问，不创建或修改云端文件，写入权限在同步时验证。

其他设备登录同一 GitHub 账号并填写相同加密密码，即可找回同步存档。不同账号使用各自的存档；切换账号或退出登录会清除缓存地址并关闭 Gist 自动同步，本地连接不自动删除，重新开启同步会合并本地与新账号的数据。Token 和加密密码保存在系统安全存储，上传的 `harbor-ssh-sync.v1.json` 为加密数据；Secret Gist 本身不是私有访问控制，获取链接的人仍可读取密文。同一 Gist 中的其他文件不会被修改。

自动查找会分页检查账号自己的 Gist，不使用其他账号的公开存档。若发现多个匹配存档，或列表读取失败，会停止同步；不会随意选一个或另建存档。已有缓存指向的存档/同步文件被删除时也会停止，请在 GitHub 恢复后重试。加密密码仍需保管，GitHub 登录不能找回加密密码。

Gist 沿用下述自动同步、三方合并与冲突选择。提交前会再次检查版本，发现变化就停止写入；GitHub Gist API 没有保证原子条件写入，因此极短时间内的同时提交仍可能相互覆盖，历史版本可在 GitHub Gist 查看。

#### 网页登录应用配置

本项目已配置 Harbor SSH 的公开 OAuth Client ID，正常启动和构建即可使用网页登录。下面的步骤用于自行发行或更换 OAuth App。

1. 打开 [GitHub OAuth App 注册页](https://github.com/settings/applications/new)。Application name 填 `Harbor SSH`，Homepage URL 填你的项目仓库或项目主页地址。
2. Authorization callback URL 可填 `http://127.0.0.1/`。本项目使用 Device Flow，不会访问此回调地址，不需要部署回调服务器。
3. 注册后在该 OAuth App 设置中勾选 **Enable Device Flow** 并保存。复制页面上的 **Client ID**；不需要创建或填写 Client Secret。
4. 启动或构建时传入 Client ID，例如：

```sh
flutter run -d windows --dart-define=GITHUB_OAUTH_CLIENT_ID=你的ClientID
flutter build windows --release --dart-define=GITHUB_OAUTH_CLIENT_ID=你的ClientID
flutter build apk --release --dart-define=GITHUB_OAUTH_CLIENT_ID=你的ClientID
```

Client ID 是公开的应用标识，可随安装包分发，最终用户无需注册 OAuth App。GitHub Actions 构建从仓库的 Settings → Secrets and variables → Actions → Variables 中读取变量 `HARBOR_GITHUB_CLIENT_ID`，未设置时使用项目默认值（GitHub 不允许仓库变量以 `GITHUB_` 开头）。通过 `--dart-define` 覆盖此编译配置后需要重新启动/构建，不能仅热更新。

授权只请求 `gist` 权限，遵循 GitHub 的轮询间隔与限流退避，设备验证码只保留在内存中。此实现不请求 `offline_access`；如果为 OAuth App 启用了访问令牌过期，令牌失效后需要重新网页登录。旧版已保存的 Token 仍可继续同步，并可通过「重新登录」替换为网页授权。

### WebDAV

点击设置图标（Windows 在独立窗口中打开，手机在设置页打开），在“云同步”中填写已有的 HTTPS WebDAV 目录、用户名和应用密码。坚果云可使用 `https://dav.jianguoyun.com/dav/HarborSSH/`，请先在网盘中创建 `HarborSSH` 文件夹并开通 WebDAV 应用密码。

设置至少 12 个字符的同步加密密码，各设备使用相同的目录和加密密码。点击「测试连接」检查账号和目录，再点击「保存并同步」。开启「自动同步」后，保存连接/凭证的更改会触发同步，应用运行时每两分钟检查云端更新。

同步文件为目录下的 `harbor-ssh-sync.v1.json`，使用 PBKDF2-HMAC-SHA256（210,000 次）派生密钥、AES-256-GCM 加密和校验。WebDAV 账号及加密密码保存在系统安全存储。加密密码无法通过 WebDAV 账号找回。同步范围包含连接、分组、收藏、密码和私钥/公钥，不包含终端输出、命令历史、SFTP 文件或设备的主机信任指纹。

同步会合并两端不同记录的更改并传播删除；同一记录被两端同时修改时，由用户选择冲突项保留本机还是云端版本。上传使用 ETag 条件写入，服务端必须支持强 ETag 和 `If-Match`/`If-None-Match`。同步文件缺失、解密失败或版本变化时不会直接覆盖；本地写入带有可恢复的安全存储日志。

## 运行

使用 Flutter **3.47.4**（Dart **3.13.3**）：

```sh
flutter pub get
flutter run -d windows
# 在 Mac 上
flutter run -d macos
# Android 设备需先打开 USB 调试
flutter devices
flutter run -d <android-device-id>
```

首次打开没有演示主机。新建连接时填写地址、端口和用户名，选择密码登录并填写密码，或选择已有私钥凭证。凭证页只管理私钥和公钥，可生成密钥对或导入已有私钥并复制公钥。密码随连接安全保存，私钥在凭证页安全保存。底部「测试连接」验证 SSH 登录后自动断开；「保存连接」只保存配置。

点击主机卡片即可连接。PC 右键或手机长按可打开管理菜单，进行收藏/取消收藏、编辑连接、重置主机指纹或删除连接。键盘可用 Tab 聚焦卡片，再按 Shift+F10 或菜单键打开菜单。主机卡片不显示三点按钮，底部以 tag 显示分组；凭证卡片额外保留「更多」按钮。

没有保存任何主机时，标题下方显示「熟悉的终端。随行的工作空间。」欢迎卡片，桌面端带 QUICK START 步骤；已有主机时不显示欢迎卡片，只保留紧凑标题和操作区。搜索无结果不会触发欢迎卡片。

地址支持域名、IPv4、裸 IPv6；端口单独填写，不输入 ssh:// 前缀。首次信任前请通过服务器管理界面或管理员核对指纹。

## 构建

```sh
# 在 Windows 上，需要 Visual Studio 的“使用 C++ 的桌面开发”
flutter build windows --release

# 在 macOS 上，需要 Xcode
flutter build macos --release

# 需要 Android SDK、JDK 及对应 SDK 许可
flutter build apk --release
```

- Windows：`build/windows/x64/runner/Release/harbor_ssh.exe`。分发时请保留整个 Release 目录的 DLL 和 data 文件夹。
- macOS：`build/macos/Build/Products/Release/Harbor SSH.app`。对外分发需要自行签名与公证。
- Android：`build/app/outputs/flutter-apk/app-release.apk`。未配置正式签名时使用开发签名，仅适合本地试用。

Android 正式签名可复制 `android/key.properties.example` 为 `android/key.properties` 并填写自己的密钥信息。此文件与 keystore 不应提交到版本库。

macOS 已配置出站网络权限；凭据采用不共享的传统 Keychain，避免将应用绑定到开发机器的 Keychain Sharing provisioning profile。Android 关闭应用备份，避免凭据与设备加密密钥分离。

`.github/workflows/build.yml` 包含测试及三端构建任务，在推送代码或手动触发时运行。

### 本机 Java 回环错误

若本机 Windows Gradle 在进入编译前报 `Unable to establish loopback connection`，且堆栈包含 `UnixDomainSockets.connect`，可仅对本次构建设置一个**不存在**的本地域套接字临时目录，使 Java 回退为 TCP 回环：

```powershell
$env:JAVA_TOOL_OPTIONS = '-Djdk.net.unixdomain.tmpdir=H:/Project/Github/SSHAPP/.tools/no-unix-sockets'
flutter build apk --release
```

替换为当前项目下的不存在路径；不要创建该目录。不需要修改系统网络或安全设置。本项目本机验证使用了此临时进程设置。

## 测试

```sh
flutter analyze
flutter test
```

真实 SSH 测试使用只监听 127.0.0.1 的 Paramiko fixture，随机端口与临时密钥，不会执行系统命令，不需要用户服务器：

```powershell
python -m pip install --target .tools/python -r tool/requirements-test.txt
$env:HARBOR_SSH_INTEGRATION = '1'
flutter test
```

在 macOS/Linux 可使用 `HARBOR_SSH_INTEGRATION=1 flutter test`。涵盖密码、加密私钥、中文分段解码、PTY 缩放、键盘输入、远程退出的最后输出、取消连接及主机指纹拒绝。

Windows 原生插件冒烟检查：

```sh
flutter run -d windows --release -t tool/native_storage_smoke.dart
# 看到 HARBOR_NATIVE_STORAGE_OK 后，重新构建正式入口
flutter build windows --release -t lib/main.dart
```

冒烟程序只读写临时测试键，完成后自行退出。界面预览可通过 `flutter test tool/render_preview_test.dart` 生成；预览中的主机是测试数据，不写入实际配置。Windows 上设置 `HARBOR_PREVIEW_FONT=C:/Windows/Fonts/msyh.ttc` 可加载中文字体。

## 结构

```text
lib/
  domain/host.dart             # 不可变主机与凭据模型
  data/host_repository.dart    # 配置、安全存储与主机信任
  data/ssh_connection.dart     # SSH 生命周期与终端数据流
  ui/workspace_model.dart      # 工作空间状态
  ui/app.dart                  # 自适应主界面
  ui/host_editor.dart          # 主机及认证表单
  ui/terminal_pane.dart        # 终端与输入辅助
test/                         # 存储、状态、界面和真实 SSH 测试
tool/                         # 本地 SSH fixture 与验证工具
```

SSH 使用 [dartssh2](https://pub.dev/packages/dartssh2)，终端使用 [xterm](https://pub.dev/packages/xterm)，凭据使用 [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage)。具体依赖版本固定在 `pubspec.lock`。

## 本次界面验证（2026-09-18）

- 34 项测试通过（包括界面渲染）；5 项 opt-in loopback SSH 协议测试未启用。
- Dart 静态检查通过；320、390、800、1280 宽度下的 200% 字体布局及主机/凭证表单测试通过。
- 覆盖终端前景与 ANSI 彩色文字对比度、错误文字、Android 触控尺寸、导航选中语义、键盘菜单和减少动画行为。
- 已渲染桌面/手机的深浅色、表单、大字体及终端预览；图片使用内存示例数据，不写入实际配置。
- 本轮未重新构建 Windows/Android Release，也未进行 Android/macOS 真机验证。

[桌面预览](artifacts/desktop.png) · [手机预览](artifacts/mobile.png) · [深色预览](artifacts/desktop-dark.png) · [大字体预览](artifacts/mobile-large.png)
