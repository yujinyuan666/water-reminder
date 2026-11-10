import Foundation
import Darwin

/// 单实例守卫：保证同一时间只有一个实例在跑。
///
/// 为什么不用 `LSMultipleInstancesProhibited`：那是未公开的 LaunchServices 键，
/// 行为不受支持；而且它拦不住「从终端直接跑二进制」「`open -n`」「同一 App 的
/// 不同拷贝」这几条路径 —— 而这正是「第二次打开」最常出现的形态（用户把 app
/// 拷到 dist 里试，或者装了两份）。
///
/// 这里用 `flock` 排他锁：进程退出（含崩溃、被 kill）时内核自动释放，不会留下
/// 需要手工清理的死锁文件；锁文件本身可以一直存在，是否被锁住才是判据。
enum SingleInstanceGuard {
    /// 第二个实例用来请求「把主页打开」的进程间通知名。
    static let showHomeRequest = Notification.Name("com.waterreminder.app.showHomeRequest")

    /// 已持有的锁文件描述符列表。**拿到锁后故意不关闭**：fd 活着锁才活着，
    /// 进程结束时内核回收。
    private static var lockDescriptors: [Int32] = []

    private static let lockFileName = "instance.lock"

    /// 返回 `true` 表示本进程是唯一实例；`false` 表示已有实例在跑，调用方应当退出。
    ///
    /// **必须把所有可写候选目录的锁全部拿到**，不能「拿到一个就成功」。原因是
    /// 两个实例看到的可写目录集合可能不同：`open`（launchd 上下文）能写
    /// `~/Library/Application Support`，而从终端直接跑二进制时那里可能被沙箱挡住、
    /// 只能退回 `$TMPDIR`（本机实测就是如此）。若各自只在「自己第一个可写目录」
    /// 上锁，两边锁的是不同文件，双双成功 —— 多开就漏了。
    static func acquire() -> Bool {
        var acquired: [Int32] = []
        var lockedByOther = false

        for directory in candidateDirectories() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent(lockFileName).path

            // 只在这里 open 一次，且**绝不能**顺手用 `FileManager.createFile` 探路：
            // 它会把已存在的文件删掉重建（实测 inode 每次都变），于是两个进程锁的是
            // 两个不同 inode，双方都成功 —— 这正是最初版「多开还是能开」的原因。
            let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
            guard descriptor >= 0 else { continue }

            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                acquired.append(descriptor)
                continue
            }
            close(descriptor)
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else { continue }
            // 这个目录的锁被别人握着 ⇒ 已有实例在跑
            lockedByOther = true
            break
        }

        if lockedByOther {
            // 已经拿到的锁随进程退出自动释放，这里显式关掉更干净
            for descriptor in acquired { close(descriptor) }
            return false
        }
        guard !acquired.isEmpty else {
            // 所有候选目录都打不开：宁可放行（多开总好过完全打不开）
            NSLog("[单实例] 无可用的锁文件位置，跳过检查")
            return true
        }
        lockDescriptors = acquired
        return true
    }

    /// 请求正在运行的那个实例打开主页。
    ///
    /// `deliverImmediately: true` 让它走同步投递 —— 本进程马上就要退出，
    /// 不这样做的话通知可能还没送出去就没了。
    static func requestShowHome() {
        DistributedNotificationCenter.default().postNotificationName(
            showHomeRequest,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// 依次尝试的锁文件所在目录：优先 Application Support，退回系统临时目录。
    ///
    /// 沙箱或受限环境下 Application Support 可能连目录都建不出来，
    /// 所以不能只依赖它 —— 退到临时目录仍能拦住多开（同一台机器上路径固定）。
    private static func candidateDirectories() -> [URL] {
        var directories: [URL] = []
        if let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directories.append(support.appendingPathComponent("WaterReminder", isDirectory: true))
        }
        directories.append(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        return directories
    }
}
