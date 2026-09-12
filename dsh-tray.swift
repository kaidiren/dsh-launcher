// DSH 菜单栏图标 —— 一个黑鲸鱼：在菜单栏出现就代表 DSH 在运行。
// 左键打开/聚焦窗口，右键出菜单；菜单里的「退出 DSH」会停掉服务进程并撤掉图标。
// 编译：swiftc -O -o dsh-tray dsh-tray.swift
import Cocoa

let launcherDir = ProcessInfo.processInfo.environment["DSH_LAUNCHER_DIR"] ?? "/Users/rkd/dsh/dsh-launcher"
let port = ProcessInfo.processInfo.environment["DSH_WEB_PORT"] ?? "3080"
// 模板图标：菜单栏是黑鲸鱼，深色菜单栏下由系统自动反白
let iconFile = "\(launcherDir)/icons/tray-iconTemplate@2x.png"
let launcher = "\(launcherDir)/launch-dsh-web.sh"
let trayLog = "\(launcherDir)/tray.log"

// 每个动作都写日志：菜单点了没反应时，先看这里能分清是「没点到」还是「点了没执行」。
func log(_ msg: String) {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    guard let data = "[\(fmt.string(from: Date()))] \(msg)\n".data(using: .utf8) else { return }
    if let fh = FileHandle(forWritingAtPath: trayLog) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: trayLog))
    }
}

func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = Pipe()
    p.standardError = Pipe()
    do { try p.run() } catch { log("  执行失败 \(path): \(error)") }
}

func serviceRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return !out.fileHandleForReading.readDataToEndOfFile().isEmpty
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var menu: NSMenu!
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if let img = NSImage(contentsOfFile: iconFile) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            item.button?.image = img
        }

        let m = NSMenu()
        m.addItem(makeItem("打开 DSH 窗口", #selector(openWindow), "o"))
        m.addItem(.separator())
        m.addItem(makeItem("退出 DSH（停服务并退出）", #selector(quitAll), "q"))
        menu = m

        refreshTooltip()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshTooltip() }
        log("托盘启动（port=\(port), pid=\(ProcessInfo.processInfo.processIdentifier)）")
    }

    func makeItem(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    func refreshTooltip() {
        item.button?.toolTip = serviceRunning()
            ? "DSH 后台服务运行中（端口 \(port)）"
            : "DSH 后台服务未运行"
    }

    @objc func clicked() {
        let type = NSApp.currentEvent?.type
        if type == .rightMouseUp {
            // 用 popUpMenu 同步弹菜单。早先「临时挂 item.menu → performClick → 立刻摘掉」
            // 的写法会让菜单项的 action 来不及派发——症状就是点菜单项完全没反应。
            log("图标被点击（右键，弹菜单）")
            item.popUpMenu(menu)
        } else {
            openWindow()
        }
    }

    @objc func openWindow() {
        // 必须经 open -a 拉起 app，而不是自己 bash 跑脚本：
        // AppleScript 权限按「发起进程」判定，托盘（裸二进制）发的会被 TCC 拒掉
        // （-1743 未授权发送 Apple 事件），而经 app/launchd 启动就和点 Dock 图标一致。
        log("动作：打开窗口（经 DSH Web.app）")
        run("/usr/bin/open", ["-a", "/Applications/DSH Web.app"])
    }

    /// 整体退出：关窗口 + 停服务 + 撤图标。
    /// 关窗口要走 AppleScript，而它的权限按发起进程判定——托盘直接发会被 TCC 拒
    /// （-1743），所以这里写下停止标志、让 app 去执行（和点 Dock 图标同一个主体）。
    @objc func quitAll() {
        log("动作：退出 DSH（关窗口 + 停服务 + 退图标）")
        try? "".write(toFile: "\(launcherDir)/.dsh-stop-request", atomically: true, encoding: .utf8)
        run("/usr/bin/open", ["-a", "/Applications/DSH Web.app"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            if let it = self?.item { NSStatusBar.system.removeStatusItem(it) }
            log("  撤掉菜单栏图标，退出")
            NSApp.terminate(nil)
            exit(0)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 只驻留菜单栏，不占 Dock
app.run()
