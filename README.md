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

## 📦 安装（给使用的人）

提供两种预编译包，放在仓库 `dist/` 目录，也可在 [Releases](../../releases) 下载：

| 文件 | 说明 |
|------|------|
| `dist/WaterReminder-1.0.0.dmg` | 磁盘镜像，双击打开后拖拽安装 |
| `dist/WaterReminder-1.0.0-macos.zip` | 压缩包，解压即用 |

### 安装步骤

1. 下载 `WaterReminder-1.0.0.dmg` 并双击打开
2. 把 `WaterReminder.app` 拖到「应用程序」文件夹
3. **首次打开**：在「应用程序」中**右键点击** App → 「打开」，按提示允许通知权限

> ⚠️ **关于「无法验证的开发者」提示**
> 当前预编译包为未付费签名的临时自签名版本，别的 Mac 下载后会触发 Gatekeeper 拦截（"无法打开，因为无法验证开发者"）。两种解决办法：
> - **推荐**：右键点击 App 选「打开」，在弹窗里点「打开」——只需一次，之后可正常启动；
> - 或在终端执行：`sudo xattr -rd com.apple.quarantine /Applications/WaterReminder.app`
>
> 若要彻底免提示地分发给所有人，请按下方「正式分发：签名与公证」处理。

## 🛠 构建方法（从源码）

### 环境要求

- macOS 13.0+（运行环境）
- Xcode 15+（含命令行工具：`xcode-select --install`）

### 方式一：命令行构建（推荐，可复现）

```bash
cd WaterReminder

# Release 构建，输出到 build/dd/Build/Products/Release/WaterReminder.app
xcodebuild -project WaterReminder.xcodeproj \
  -scheme WaterReminder -configuration Release \
  -derivedDataPath build/dd \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=NO build
```

### 方式二：Xcode 图形界面

1. `open WaterReminder.xcodeproj`
2. 顶部选择Scheme `WaterReminder`、设备 `My Mac`
3. `⌘B` 构建，`⌘R` 运行；构建产物在 `Products` 分组右键 `Show in Finder`

### 打包成可分发文件

```bash
APP=build/dd/Build/Products/Release/WaterReminder.app

# 1) 生成 DMG（拖拽安装样式）
rm -rf dist/dmg_staging && mkdir -p dist/dmg_staging
cp -R "$APP" dist/dmg_staging/
ln -sf /Applications dist/dmg_staging/Applications
hdiutil create -volname "WaterReminder 喝水提醒" \
  -srcfolder dist/dmg_staging -ov -format UDZO \
  dist/WaterReminder-1.0.0.dmg

# 2) 生成 ZIP 备用
cd dist && zip -r -q WaterReminder-1.0.0-macos.zip WaterReminder.app && cd ..
```

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
