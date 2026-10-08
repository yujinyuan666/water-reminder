# 💧 喝水提醒（WaterReminder）

一款轻量级 macOS 菜单栏喝水提醒工具，帮助你养成规律饮水的好习惯。

驻留在顶部菜单栏，按你自定义的规则定时提醒喝水——支持系统通知和居中弹窗两种方式，开机自动启动，后台静默运行，不打扰你的工作流。

## ✨ 功能特性

- **菜单栏常驻** — 水滴图标显示在 macOS 顶部菜单栏，点击即可展开管理面板
- **两种提醒规则**
  - **固定时间** — 在指定时刻提醒，支持「仅一次 / 每天 / 指定周几」三种重复模式
  - **循环间隔** — 在起止时间段内按固定间隔（15~240 分钟）循环提醒
- **两种提醒方式**
  - **系统通知** — 通过 macOS 原生通知中心推送，应用退出后依然生效
  - **居中弹窗** — 屏幕正中心弹出提醒窗口，支持「稍后提醒（5 分钟后）」和键盘快捷操作
- **灵活的周几设置** — 按需勾选周一至周日，工作日/周末分开管理
- **开机自启动** — 基于 macOS 13+ 原生 `SMAppService`，无需额外 helper
- **即时操作** — 一键「立即提醒」发送通知，一键「测试弹窗」预览效果
- **状态一览** — 面板实时显示下次提醒时间及倒计时
- **数据持久化** — 规则自动保存，重启后恢复

## 🛠 技术栈

| 项目 | 说明 |
|------|------|
| 语言 | Swift |
| UI 框架 | SwiftUI（`MenuBarExtra`） |
| 系统框架 | `UserNotifications`、`AppKit`（`NSPanel`）、`ServiceManagement` |
| 最低系统 | macOS 13.0+ |
| 存储 | `UserDefaults`（JSON 序列化） |
| 构建工具 | Xcode |
| 持续集成 | GitHub Actions（macOS runner，自动出 DMG / ZIP 并发布 Release） |

## 📦 下载安装（给使用的人）

预编译安装包由 GitHub Actions **自动构建并发布**，直接到 **[Releases](../../releases)** 页面下载即可，不需要自己编译。

| Release | 说明 |
|---------|------|
| **最新构建**（tag `latest`） | 跟随 `master` 分支自动滚动，永远是最新代码构建出来的版本 |
| **v1.x.x** | 正式发布版本，长期保留、不会变动 |

每个 Release 里有两个文件，任选其一：

| 文件 | 说明 |
|------|------|
| `WaterReminder-<版本>.dmg` | 磁盘镜像，双击打开后拖拽或运行安装脚本 |
| `WaterReminder-<版本>-macos.zip` | 压缩包，解压即用 |

两者都内置了 `安装.command`，双击它会自动完成「安装到「应用程序」→ 清除系统隔离标记 → 启动应用」，是最省事的安装方式。

### 安装步骤

**方式一：一键安装脚本（推荐）**

1. 下载并打开 DMG（或解压 ZIP）
2. 双击 `安装.command`，按提示回车即可
3. 万一被系统拦住：**右键点击** `安装.command` → 选「打开」→ 再点「打开」

**方式二：手动拖拽**

1. 把 `WaterReminder.app` 拖到「应用程序」文件夹
2. 在「应用程序」中**右键点击** App → 选「打开」→ 弹窗里再点「打开」
3. 按提示允许通知权限

> ⚠️ **关于「无法验证的开发者」提示**
> 预编译包采用 **ad-hoc 自签名**（没有 Apple 开发者公证），在别的 Mac 上首次打开会被 Gatekeeper 拦一次：
> - 右键点击 App → 「打开」→ 弹窗里点「打开」，只需一次，之后可正常启动；
> - **macOS 15 (Sequoia) 及以上**若没出现「打开」按钮：打开「系统设置 → 隐私与安全性」，下拉到页面底部点「仍要打开」；
> - 或终端执行一条命令：`xattr -rd com.apple.quarantine /Applications/WaterReminder.app`
>
> 若要彻底免提示地分发给所有人，请按下方「正式分发：签名与公证」处理。

## 🛠 构建方法（从源码）

### 环境要求

- macOS 13.0+（运行环境）
- Xcode 15+（含命令行工具：`xcode-select --install`）

### 方式一：命令行构建（推荐，可复现）

```bash
# 在仓库根目录执行
xcodebuild -project WaterReminder.xcodeproj \
  -scheme WaterReminder -configuration Release \
  -derivedDataPath build/dd \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  build

# 产物：build/dd/Build/Products/Release/WaterReminder.app
```

`ARCHS="arm64 x86_64"` 会产出 Apple Silicon 与 Intel 都能运行的**通用二进制**，CI 用的就是这条命令。

> 💡 在容器 / 受限沙箱里构建时，Swift 宏插件可能因 `sandbox-exec` 被禁而报
> `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`，
> 加上 `OTHER_SWIFT_FLAGS="-disable-sandbox"` 即可绕过。CI 的干净 runner 不需要这个参数。

### 方式二：Xcode 图形界面

1. `open WaterReminder.xcodeproj`
2. 顶部选择 Scheme `WaterReminder`、设备 `My Mac`
3. `⌘B` 构建，`⌘R` 运行；构建产物在 `Products` 分组右键 `Show in Finder`

### 打包成可分发文件

```bash
APP=build/dd/Build/Products/Release/WaterReminder.app
VERSION=1.0.0
mkdir -p dist

# 0) ad-hoc 签名（Apple Silicon 上未签名的 App 会被系统直接杀掉，这步不能省）
codesign --force --deep --sign - "$APP"

# 1) 组装两份载荷：App + 一键安装脚本 + 安装说明
rm -rf dist/dmg_staging dist/zip_staging
for S in dist/dmg_staging dist/zip_staging; do
  mkdir -p "$S"
  cp -R "$APP" "$S/"
  cp packaging/安装.command packaging/安装说明.txt "$S/"
  chmod +x "$S/安装.command"
done

# 2) ZIP（用 zip -y 保留权限位，避免 __MACOSX/ 冗余条目）
( cd dist/zip_staging && zip -r -y -q "../WaterReminder-$VERSION-macos.zip" \
    WaterReminder.app 安装.command 安装说明.txt )

# 3) DMG（含指向 /Applications 的快捷方式）
ln -sf /Applications dist/dmg_staging/应用程序
hdiutil create -volname "WaterReminder 喝水提醒" \
  -srcfolder dist/dmg_staging -ov -format UDZO \
  "dist/WaterReminder-$VERSION.dmg"
```

> 以上命令与 `.github/workflows/build.yml` 里 CI 执行的完全一致，本地能出包就代表 CI 能出包。

## 🤖 自动构建与发布（CI）

`.github/workflows/build.yml` 负责在你推送代码后自动编译、打包，并把可下载的安装包挂到 GitHub Releases。

### 触发规则

| 事件 | 行为 |
|------|------|
| push 到 `master` / `main` | 构建 → 更新标签为 `latest` 的**预发布** Release（用户永远能从 Releases 页面下到最新版） |
| push `v*` 标签（如 `v1.0.1`） | 构建 → 创建同名**正式** Release，长期保留 |
| Actions 页面手动触发 | 按当前分支走上面同样的逻辑 |

产物同时会作为 Actions Artifact 保留 30 天，方便回看历史构建。

### 构建流程

```
checkout
  → xcodebuild Release 构建（arm64 + x86_64 通用二进制）
  → codesign --sign -  ad-hoc 签名 + 校验架构/签名/Info.plist
  → 打包 DMG / ZIP（内含 安装.command 与 安装说明.txt）
  → 上传 Actions Artifact
  → gh release 创建或更新 Release
```

### 仓库镜像：Gitee → GitHub

主仓库在 Gitee，GitHub 作为镜像。在 Gitee 配置好推送镜像后，**你只需要推 Gitee**，分支与标签会自动同步到 GitHub，进而触发上面的流水线。

配置位置：**Gitee 仓库 → 管理 → 仓库镜像管理 → 添加镜像**

| 字段 | 填写 |
|------|------|
| 镜像方向 | Push 方向（Gitee → GitHub） |
| 镜像仓库 | 选你在 GitHub 上建好的同名**空**仓库 |
| 私人令牌 | GitHub Personal Access Token，勾选 `repo` 权限（想自动生成 webhook 再加 `admin:repo_hook`） |

Gitee 官方限制，务必留意：

- 镜像**最短触发间隔 5 分钟**，推送后别急着刷新 GitHub
- 同步内容包含**分支、标签、提交记录**（所以打 tag 也会自动同步过去）
- 镜像会**覆盖**目标仓库的分支与标签 —— **不要直接在 GitHub 上改代码**。滚动 Release 用的 `latest` 标签也可能被清掉，流水线每次推送都会自动重建，不影响下载
- 想立刻同步，可以到镜像管理页面点「更新」

> 首次配置完成后，建议先到 GitHub 的 **Actions → 构建与发布 → Run workflow** 手动跑一次，确认流水线通了。

### 关于签名

CI 使用 `codesign --sign -`（ad-hoc 自签名），**不需要任何证书**，任何人 clone 下来都能复现。代价是下载者首次打开会被 Gatekeeper 拦一次（包内 `安装.command` 已自动处理）。要做到「下载即开、零提示」，见下一节。

## 🚀 正式分发：签名与公证（推荐用于公开发布）

临时自签名版本在别人的电脑上会被拦截。要像正规软件一样「下载即开」，需要 **Apple Developer 付费账号（$99/年）** 进行签名 + 公证（Notarization）。

### 1. 准备证书

- 在 [developer.apple.com](https://developer.apple.com) 加入开发者计划
- 在 Xcode → Settings → Accounts 登录，下载 **"Developer ID Application"** 证书
- 查看证书名称：

```bash
security find-identity -v -p codesigning
# 示例输出：1) ABC123... "Developer ID Application: Your Name (TEAMID)"
```

### 2. 用开发者证书构建

```bash
xcodebuild -project WaterReminder.xcodeproj \
  -scheme WaterReminder -configuration Release \
  -derivedDataPath build/dd \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  DEVELOPMENT_TEAM=TEAMID \
  ENABLE_HARDENED_RUNTIME=YES build
```

### 3. 公证（Notarization）

```bash
# 打包 DMG 后提交公证（需 Apple ID、团队、App 专用密码）
xcrun notarytool submit dist/WaterReminder-1.0.0.dmg \
  --apple-id "你的AppleID" --team-id TEAMID \
  --password "app专用密码" --wait

# 公证通过后，将票据"钉"到 DMG
xcrun stapler staple dist/WaterReminder-1.0.0.dmg
```

完成后分发的 DMG 在任意 Mac 上双击即可安装，不再有拦截提示。

> 💡 提示：应用内「开机自启动」依赖 macOS 的 `SMAppService`，需要 App **位于 `/Applications` 且已签名**，否则该功能可能不可用。

## 📖 使用说明

### 基本操作

1. **启动应用** — 应用启动后，菜单栏会出现一个水滴图标 💧（蓝色=已开启，灰色=已关闭）
2. **点击图标** — 展开管理面板
3. **开关提醒** — 顶部开关一键启用/关闭所有提醒

### 添加提醒规则

在「提醒列表」区域，点击底部按钮添加规则：

- **固定时间** — 设置一个具体时间点，选择重复方式（仅一次/每天/指定周几）
- **循环间隔** — 设置起止时间和间隔分钟数，在时段内自动循环提醒

每条规则可单独设置提醒方式（通知 / 全屏提示），点击规则卡片右侧箭头展开详细编辑。

### 提醒方式说明

| 方式 | 特点 | 是否需要应用运行 |
|------|------|------------------|
| 通知 | 系统通知中心推送，即使应用退出也生效 | ❌ 不需要 |
| 全屏提示 | 屏幕居中弹窗，带提示音，支持稍后提醒 | ✅ 需要保持运行 |

### 其他功能

- **立即提醒** — 随时发送一条喝水通知
- **测试弹窗** — 预览居中弹窗效果
- **开机自启动** — 底部开关，开启后登录系统时自动启动

## 📁 项目结构

```
WaterReminder/
├── .github/workflows/build.yml   # CI：自动构建、打包、发布 Release
├── packaging/
│   ├── 安装.command              # 一键安装脚本（清除隔离标记 + 装进「应用程序」）
│   └── 安装说明.txt              # 随包分发的安装说明
├── WaterReminder/
│   ├── WaterReminderApp.swift    # 应用入口、菜单栏场景、开机自启动
│   ├── MenuView.swift            # 菜单栏面板 UI、规则卡片视图
│   ├── ReminderManager.swift     # 通知调度、居中弹窗管理器
│   ├── AppSettings.swift         # 数据模型、规则定义、持久化
│   ├── Info.plist                # 应用配置
│   ├── Assets.xcassets/          # 应用图标资源
│   └── AppIcon.icns              # 应用图标
├── make_icon.swift               # 图标生成脚本（蓝色渐变 + 水滴）
└── WaterReminder.xcodeproj/      # Xcode 工程文件
```

## 🤝 参与贡献

1. Fork 本仓库
2. 新建 `feat_xxx` 分支（如 `feat/custom-sound`）
3. 提交代码
4. 新建 Pull Request

欢迎提交 Issue 反馈 bug 或提出功能建议。

## 📄 开源协议

本项目采用 [MIT License](LICENSE) 开源协议。

## 🙏 鸣谢

- 水滴图标使用 Swift + CoreGraphics 程序化生成（见 `make_icon.swift`）
- 感谢所有为健康生活习惯而努力的人 💪
