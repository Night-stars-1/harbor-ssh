# Harbor SSH

面向 Windows、macOS、Linux 和 Android 的 SSH 工作空间。用同一套界面管理主机、终端、文件，以及当前会话里的 AI 助手。

## 功能

- **主机**：新增、编辑、删除、收藏、标签、搜索和拖动排序。
- **登录**：密码、PEM/OpenSSH 私钥和加密私钥口令。密码、私钥和已信任的主机指纹保存在系统安全存储。
- **私钥格式**：支持 OpenSSH、PKCS#1 RSA、SEC1 EC，以及 `-----BEGIN PRIVATE KEY-----` 的未加密 PKCS#8（RSA、ECDSA P-256/P-384/P-521、Ed25519）。加密 PKCS#8（`-----BEGIN ENCRYPTED PRIVATE KEY-----`）暂不支持。
- **连接**：首次连接显示 SHA256 指纹；指纹变化时弹窗对照新旧指纹，核实后可确认更新并继续连接，取消则保留原指纹并阻止连接。
- **身份**：在「设置 → 身份」为连接设置替换用的地址和端口，用于内网、内网穿透和代理等不同网络场景。身份名称和规则支持加密同步，当前选择由各设备独立保存；切换后新建连接和重新连接改用新的地址和端口。
- **标题栏导航**：在「设置 → 外观」开启「导航放到标题栏」后，宽屏桌面的标题栏显示「返回终端」按钮，可从其他页面回到离开前选中的终端并保留内容。已在终端页或原会话已关闭时，按钮置灰不可点击。

- **端口转发**：本地转发、远程转发和 SOCKS5 代理；
- **文件**：SFTP 浏览和 UTF-8 文本编辑，可与本地目录互传。桌面端可拖放文件和文件夹。
- **AI**：在当前 SSH 会话中执行任务，支持图片和本机加密历史。宽屏下可左右拖动 AI 面板与终端之间的分隔条调整面板宽度，双击恢复默认；宽度在当前面板存续期间保留，窄屏仍使用全屏面板。Windows 可将面板弹出为独立窗口。
- **AI 连续执行**：不设每轮工具调用次数上限，任务可持续执行直到模型完成、手动停止、断线或发生错误；审批规则仍然生效。持续调用仍会消耗模型服务额度。
- **思考等级**：在 AI 模型选择面板中拖动滑块，可选择「自动、低、中、高、极高、最大」。选择随当前对话保存并在恢复历史时还原，独立 AI 窗口同样可用。自动档不额外传参数；具体支持的档位由模型和服务商决定。
- **同步**：用 WebDAV 或 GitHub Gist 加密同步连接、凭证和身份定义。不同步当前身份选择、终端内容、AI 历史和主机指纹。同步身份前，需将所有设备升级到支持此功能的版本。

## 截图


| 桌面                                      | 深色                                           |
| --------------------------------------- | -------------------------------------------- |
| ![桌面连接列表](docs/screenshots/desktop.png) | ![深色连接列表](docs/screenshots/desktop-dark.png) |



| 手机                                     | 文件                                       | AI                                    |
| -------------------------------------- | ---------------------------------------- | ------------------------------------- |
| ![手机连接列表](docs/screenshots/mobile.png) | ![SFTP 文件列表](docs/screenshots/files.png) | ![终端与 AI 助手](docs/screenshots/ai.png) |


## 编译

需要 [Flutter 3.47.4](https://docs.flutter.dev/install)。

```sh
flutter pub get
flutter run -d windows
flutter run -d macos
flutter run -d linux
flutter run -d <android-device-id>
```

发布构建：

```sh
# Windows，需要 Visual Studio 的「使用 C++ 的桌面开发」
flutter build windows --release

# macOS，需要 Xcode，且必须在 Mac 上执行
flutter build macos --release

# Linux x86_64，在 Ubuntu 24.04 上执行
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev libwayland-dev libx11-dev liblzma-dev libstdc++-12-dev rpm
flutter build linux --release
bash tool/package_linux.sh

# Android，需要 Android SDK 与 JDK
flutter build apk --release --split-per-abi
```

产物：

- Windows：`build/windows/x64/runner/Release/`。分发时保留整个目录，不要只拷贝 exe。
- macOS：`build/macos/Build/Products/Release/Harbor SSH.app`。
- Linux：`build/linux/packages/` 下的 `harbor-ssh-linux-amd64.deb`（Debian 安装包）、`harbor-ssh-linux-x86_64.rpm`（RPM 安装包）与 `harbor-ssh-linux-x64.tar.gz`（便携包）。原始 bundle 位于 `build/linux/x64/release/bundle/`，必须保留完整目录。
- Android：`build/app/outputs/flutter-apk/` 下按架构生成的 `app-*-release.apk`，安装与设备匹配的一个即可。

Android 正式签名使用 `android/key.properties.example` 对应的密钥。不要把 keystore 或密码提交到仓库。

### Linux 安装

Linux 包面向 x86_64，基于 Ubuntu 24.04 构建；需要兼容的 glibc、GTK 3、libsecret，以及 EGL/OpenGL ES 运行库，不支持 ARM64。RPM 包自动声明运行库依赖，包括 glibc 2.38 或更高版本，不适用于运行库过旧的发行版。

```sh
# 安装本地 deb，自动安装依赖，并添加 Harbor SSH 应用菜单入口
sudo apt install ./build/linux/packages/harbor-ssh-linux-amd64.deb

# 使用 DNF 的兼容发行版，安装 RPM 并自动解析依赖
sudo dnf install ./build/linux/packages/harbor-ssh-linux-x86_64.rpm
harbor-ssh

# 或解压便携包（仍需系统运行库，不是静态可执行文件）
tar -xzf build/linux/packages/harbor-ssh-linux-x64.tar.gz
./harbor-ssh-linux-x64/harbor_ssh
```

便携包需自行安装 GTK 3、libsecret、Wayland 客户端库（Ubuntu：`libwayland-client0`）、EGL/OpenGL ES 运行库和 `xdg-utils`，中文显示需安装 CJK 字体（例如 `fonts-noto-cjk`）。密码和主机指纹存储依赖已启动并解锁的 Secret Service（例如 GNOME Keyring）；本地文件选择依赖桌面的 XDG Desktop Portal 服务。

## macOS 自签名

工程没有绑定付费的 Apple 开发者证书。要在其他 Mac 上打开，构建完成后用本机的「代码签名」证书自签。自签名不能替代 Apple 公证，对方第一次仍需手动确认。

1. 打开「钥匙串访问」→「证书助理」→「创建证书」。
2. 名称填 `Harbor SSH`，身份类型选「自签名根证书」，证书类型选「代码签名」，存入「登录」钥匙串。
3. 在仓库根目录执行。必须带上 Release 权限，否则沙盒里没有出站网络，也不能访问用户选择的文件夹。

```sh
APP="build/macos/Build/Products/Release/Harbor SSH.app"
IDENTITY="Harbor SSH"

find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
  xargs -0 codesign --force --sign "$IDENTITY" --options runtime --timestamp=none

codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements macos/Runner/Release.entitlements \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
```

从浏览器、隔空投送或其他 Mac 拷来的 App 先去掉隔离标记，再在 Finder 里右键「打开」一次：

```sh
xattr -dr com.apple.quarantine "/path/to/Harbor SSH.app"
```