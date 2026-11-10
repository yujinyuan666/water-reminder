# AGENTS.md — 给在本仓库工作的 AI 代理的硬性约定

本文件记录**踩过的坑与不可回退的决定**。改动本仓库前先读完，违反其中任何一条都会
造成用户可感知的回归。

---

## 一、签名与通知身份（最容易误伤、最难发现的一类）

### 铁律

> **代码签名不指定 designated requirement（即裸 `codesign --sign -`）
> ⇒ DR 自动取 cdhash ⇒ 每次构建都是新的「系统通知身份」
> ⇒ 旧版本排下的通知既看不见也清不掉，会一直弹。**
>
> 修法只有一条：**签名时显式嵌入一条身份型 DR**（`-r='designated => identifier "<bundle id>"'`）。
> 这条 DR 只绑 bundle id，不绑 cdhash、不绑证书 —— 不需要证书、不需要钥匙串、
> 不需要任何 Secret，CI 与本地行为完全一致。

这不是推测，是实测结论（2026-11-10）。展开说明：

- macOS `UNUserNotificationCenter` 的待发/已送达通知，按**代码签名身份**隔离，
  与 bundle id、可执行路径、可执行文件名都无关。
- ad-hoc 签名时 `codesign -d -r-` 输出 `designated => cdhash H"..."`，
  而 cdhash 每次构建都不同（同一份源码连编两次也能差）。
- 于是新版本 `removeAllPendingNotificationRequests()` 的作用域跨不过 cdhash：
  它只能清自己，清不到历史版本。
- **删除 App 也不会清掉它的待发通知**；改 bundle id 想「旁路清理」会被通知系统
  以 `Notifications are not allowed for this application` 拒绝。
- `willPresent` 也拦不住：跨身份的通知根本不进入当前进程的 delegate。

### 必须遵守

1. **签名一律走 `./Scripts/sign-app.sh`，不要手写 `codesign`。**
   它总是带 `-r` 嵌入身份型 DR；手写 `codesign --sign -` 会退回 cdhash 型，
   等于把已经修好的问题重新引入一遍。
   - 脚本仍然支持证书（`SIGNING_IDENTITY`），但**证书只是加强，不是必需**。
   - `codesign` 失败时可能已经删掉旧签名并退回 cdhash DR，所以脚本把
     签名失败当**致命错误**（`exit 1`）—— 不要改成「失败也继续」。
2. **`.signing/` 目录（若你确实用了证书）一旦生成就永久备份，不要重新生成**。
   虽然身份型 DR 已经绑在 bundle id 上、换证书也不断身份（实测过：
   证书签名与 ad-hoc 身份型 DR 可以互相看见并清理），但保留它更省心。
3. `Scripts/check-notification-identity.sh` 的退出码是契约：
   `0` = 身份型（好），`1` = cdhash 型（有残留风险）。CI/脚本据此判断。
4. 判断 DR 类型时**不能** `grep '^designated'`：App 没嵌入 DR 时，
   `codesign -d -r-` 打印的是计算出来的结果，行首带 `# `（`# designated => ...`）。
   正确写法：`grep 'designated' | sed 's/^# *//'`。
5. **嵌入的 DR 必须是 ad-hoc 真能满足的**。ad-hoc 没有证书链，
   所以 `anchor apple generic` / `certificate leaf` 这类条件它满足不了；
   写成那样会得到「签名成功、但产物不满足自己声明的 DR」的坏包
   （`codesign --verify --strict --verbose=2` 报
   `valid on disk` + `does not satisfy its designated Requirement`）。
   默认的 `designated => identifier "<bundle id>"` 是安全写法。
   `sign-app.sh` 已经把这种情况当致命错误，别把它降级成警告。

### 已确认做不到的事（别再试）

- 用 App 自己读系统通知库来清理孤儿通知：需要「完整磁盘访问」，
  而 `com.waterreminder.app` 不在 TCC 白名单里，也不该为了这个去要那个权限。
- 用 `DYLD_INSERT_LIBRARIES` 注入探针查 `getPendingNotificationRequests` 来
  判断「有没有孤儿」：探针是新进程、身份与 usernoted 里登记的 `src` 对不上，
  只能看见自己新建的通知，**会给出假阴性**。系统通知库才是权威。
- 让 xcodebuild 内部签证书：macOS target 要求「Mac Development」证书，
  而 `Apple Development` 会被拒绝（`No signing certificate "Mac Development" found`）。
  必须 `CODE_SIGNING_ALLOWED=NO` 构建后用 `codesign` 单独签。

### 系统通知库（供诊断，仅供诊断）

- 活动库：`~/Library/Group Containers/group.com.apple.usernoted/db2/db`
- 本 App 的表行：`app.identifier = 'com.waterreminder.app'`（库里 identifier 可能是小写）
- `record.data` 是 bplist，含 `srce`（16 字节来源身份指纹）、`req.iden`、`req.trig`
- `requests.list` / `delivered.list` 是加密 blob，解不开，别浪费时间
- `app` 表上的 `app_deleted` trigger 会级联删记录；但清理时**应保留 app 行**，
  否则用户要重新授权一次通知

---

## 二、构建环境

1. **本机（DSH 沙箱）跑 xcodebuild 必须带 `OTHER_SWIFT_FLAGS="-disable-sandbox"`**，
   否则报 `external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`
   （根因是嵌套 `sandbox-exec` 在本机不可用）。CI 干净 runner 不需要。
2. `swiftc` 直接编译还需要 `-module-cache-path <可写目录>` 与预先存在的 `TMPDIR`，
   否则报 `error opening '.../ModuleCache/Swift-*.swiftmodule' for output: Operation not permitted`。
3. 沙箱只允许写 workspace 与部分临时目录：`~/Library/...`、`~/Desktop`、`~/Applications`
   一律 `Operation not permitted`。Xcode GUI 若报 DerivedData 写不进去，是同源问题。
4. 顶层表达式只能在名为 `main.swift` 的文件里；与 `@main` 不能共存。
5. 裸 CLI 调 `UNUserNotificationCenter.current()` 会崩（`Abort trap: 6`），
   测试必须打成 `.app` 并给 `CFBundleIdentifier`。

## 三、这个项目自身的不可回退决定

1. **不能给 `ReminderRule` 加非 Optional 字段**。Swift 合成的 `Decodable`
   不给缺失 key 默认值，旧 JSON 解码失败会让 `AppSettings.init` 落进 else 分支，
   **重置用户全部配置**。需要加字段就走 `ReminderRule` 的宽容 `init(from:)`。
2. **「仅一次」的目标时刻要钉死在 `onceFireTargets`**，不能每次重排都重算
   「下一次该时刻」——否则「仅一次」会变成每天都提醒。
3. **两条触发路径严格分流**：`schedule()` 只处理 `method == .notification`，
   `checkAndFire()` 只处理 `method == .fullScreen`。别为了「顺手」让全屏规则也排通知。
4. **全屏弹窗不能用 `contentViewController`**：`NSWindow` 会按内容理想尺寸重排，
   而该窗口 contentRect 原点在 (0,0)，会把弹窗缩到屏幕左下角。
   必须用 `NSHostingView` 直接作 `contentView` 并显式设 frame。
5. **`PanelWindowSync` 的三个必须点**（改任何一条都会引入 bug）：
   顶边锚定（`setContentSize` 只保持左下角）、放宽 `contentMinSize/contentMaxSize`、
   尺寸差 ≤0.5pt 即 no-op（否则「改窗口→重排→再改窗口」死循环）。
6. **`beginActivity` 用 `.userInitiatedAllowingIdleSystemSleep`**，不是 `.userInitiated`。
   后者含 `NSActivityIdleSystemSleepDisabled`，而令牌永不归还 ⇒ 整机无法空闲睡眠。
7. **不要在前端加「显示快捷操作」开关**（用户 2026-08-11 明确要求配置放在
   `AppSettings.showQuickActions` 即可，不加 UI）。同理不要引入全局 `fullScreenMode`。
8. `MenuBarExtra(.window)` 的面板必须真实点击状态栏才求值 —— 程序内
   `makeKeyAndOrderFront` 或合成 `CGEvent` 都打不开，别用这些方式做自动化验证。

## 四、验证方式（改动后至少跑这些）

```bash
# 1) 只查语法，最快
TMPDIR=/tmp/wr_tc/TMPDIR xcrun --sdk macosx swiftc -disable-sandbox \
  -module-cache-path /tmp/wr_tc/mcache -typecheck \
  -target arm64-apple-macos13.0 -swift-version 5 WaterReminder/*.swift

# 2) 真实构建
TMPDIR=/tmp/wr_tc/TMPDIR xcodebuild -project WaterReminder.xcodeproj \
  -scheme WaterReminder -configuration Debug -derivedDataPath /tmp/wr_dd \
  build CODE_SIGNING_ALLOWED=NO OTHER_SWIFT_FLAGS="-disable-sandbox"

# 3) 脚本语法
bash -n Scripts/*.sh
```
