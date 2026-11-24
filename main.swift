import Cocoa
import Foundation
import IOKit.pwr_mgt

// 配置（可用环境变量覆盖，便于测试）
func envDouble(_ key: String, _ def: TimeInterval) -> TimeInterval {
    if let s = ProcessInfo.processInfo.environment[key], let v = Double(s) { return v }
    return def
}
func envInt(_ key: String, _ def: Int) -> Int {
    if let s = ProcessInfo.processInfo.environment[key], let v = Int(s) { return v }
    return def
}

let kIdleThreshold = envDouble("CACHEKEEPER_IDLE", 270)      // 真实活动后多少秒开始 ping（4:30）
var kPingInterval  = envDouble("CACHEKEEPER_INTERVAL", 270)  // 两次 ping 最小间隔（检测到 1h TTL 时自动改为 3000）
let kSessionWindow = envDouble("CACHEKEEPER_WINDOW", 1800)   // 只保活最近多少秒内活跃的会话
let kKeepWindow    = envDouble("CACHEKEEPER_KEEPWINDOW", 3600) // 最后活动后只保活这么久（1 小时）
var kCacheTtl      = envDouble("CACHEKEEPER_TTL", 300)       // 缓存有效期；超过即视为已过期，不再 ping
let kMaxSessions   = envInt("CACHEKEEPER_MAX", 4)            // 最多同时保活几个会话
let kTickInterval  = envDouble("CACHEKEEPER_TICK", 10)       // 扫描/检查周期（秒）
let kPingTimeout   = envDouble("CACHEKEEPER_TIMEOUT", 150)   // 单次 ping 超时
let kRetryDeadline = envDouble("CACHEKEEPER_RETRY_DEADLINE", 294) // 距上次缓存活动的最后发送时间（秒）
let kMaxRetries    = envInt("CACHEKEEPER_MAX_RETRIES", 3)    // 失败后最多立即重试几次

struct SessionState {
    let id: String
    let jsonlPath: String
    let cwd: String
    let version: String
    var title: String
    var model: String
    var mtime: Date
    var lastPing: Date?
    var userTurn: String?
    var pingCount: Int = 0
    var lastPingSucceeded: Bool?
    var cacheReadTotal: Int = 0
    var lastNote: String = "待首次 ping"
    var consecutiveMiss: Int = 0
    var blocked: Bool = false
    var selected: Bool = false
    var retryAt: Date? = nil
    var failCount: Int = 0
    var lastSuccess: Date? = nil
    var finalRetryDone: Bool = false

    var nextPingAt: Date {
        if let retry = retryAt { return retry }
        let idleAt = mtime.addingTimeInterval(kIdleThreshold)
        guard let lastPing = lastPing else { return idleAt }
        return max(idleAt, lastPing.addingTimeInterval(kPingInterval))
    }
}

struct RowView {
    let view: NSView
    let checkbox: NSButton
    let title: NSTextField
    let subtitle: NSTextField
    let status: NSTextField
    let detail: NSTextField
    let restore: NSButton
    let divider: NSBox
}

final class SessionListView: NSView {
    override var isFlipped: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow!
    var summaryLabel: NSTextField!
    var emptyLabel: NSTextField!
    var pingButton: NSButton!
    var menuSummary: NSMenuItem!
    var menuTiming: NSMenuItem!
    var menuPing: NSMenuItem!
    var scrollView: NSScrollView!
    var docView: NSView!
    var rows: [String: RowView] = [:]
    var rowOrder: [String] = []
    var timer: Timer?
    var fsStream: FSEventStreamRef?
    var sleepAssertion: IOPMAssertionID = 0
    var claudePath = ""
    var claudeVersion = ""
    var sessions: [String: SessionState] = [:]
    var pingingSessionID: String?
    var pingInFlight: Bool { pingingSessionID != nil }
    var lastPingSucceeded = UserDefaults.standard.object(forKey: "lastPingSucceeded") as? Bool
    let rowHeight: CGFloat = 48
    let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/ClaudeKeepalive.log")

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        rotateLogIfNeeded()
        detectPromptCacheTtl()
        setupStatusItem()
        setupWindow()
        scanSessions()
        startWatching()
        resolveClaude()
        if ProcessInfo.processInfo.environment["CACHEKEEPER_NO_WINDOW"] != "1" {
            showWindow()
        }
        scheduleTick()
        // 界面时间文本每秒刷新（不重新扫描）
        let refresh = Timer(timeInterval: 1, target: self, selector: #selector(updateUI), userInfo: nil, repeats: true)
        RunLoop.main.add(refresh, forMode: .common)
        log("启动: claude 路径解析中")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口关闭不退出，继续在菜单栏保活
    }

    func windowDidResize(_ notification: Notification) {
        updateUI()
    }

    /// 若 Claude Code 开启了 1h prompt cache TTL，ping 间隔放宽到 50 分钟
    func detectPromptCacheTtl() {
        guard ProcessInfo.processInfo.environment["CACHEKEEPER_INTERVAL"] == nil else { return }
        let path = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (d["promptCacheTtl"] as? String) == "1h" else { return }
        kPingInterval = 3000
        kCacheTtl = 3600
        log("检测到 promptCacheTtl=1h，ping 间隔改为 50 分钟")
    }

    // MARK: - 启动解析

    func resolveClaude() {
        let candidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                          NSHomeDirectory() + "/.local/bin/claude"]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            claudePath = p
            break
        }
        guard !claudePath.isEmpty else {
            log("未找到 claude 可执行文件")
            updateUI()
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch {
            log("claude --version 启动失败: \(error)")
            return
        }
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let text = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ver = text.components(separatedBy: " ").first ?? text
            DispatchQueue.main.async {
                self.claudeVersion = ver
                self.log("claude 版本 \(ver) @ \(self.claudePath)")
                self.updateUI()
                self.tick()
            }
        }
    }

    // MARK: - 定时检查

    @objc func tick() {
        defer { scheduleTick() }
        guard !pingInFlight else { updateUI(); return }
        let now = Date()
        let candidates = sessions.values
            .filter { canKeepAlive($0) && cacheFresh($0, now: now) && withinSendDeadline($0, now: now) && $0.nextPingAt <= now }
            .sorted { $0.mtime > $1.mtime }
            .prefix(kMaxSessions)
        if ProcessInfo.processInfo.environment["CACHEKEEPER_DEBUG"] == "1" {
            log("tick: sessions=\(sessions.count) eligible=\(candidates.count) ver=\(claudeVersion)")
        }
        if let next = candidates.first {
            ping(next.id)
        } else {
            updateUI()
        }
    }

    func nextAutoPingDate() -> Date? {
        sessions.values.lazy.compactMap(self.automaticPingDate).min()
    }

    func automaticPingDate(for session: SessionState) -> Date? {
        guard kMaxSessions > 0, canKeepAlive(session) else { return nil }
        let now = Date()
        guard cacheFresh(session, now: now) else { return nil }
        guard withinSendDeadline(session, now: now) else { return nil }
        return session.nextPingAt
    }

    func scheduleTick() {
        timer?.invalidate()
        let dueIn = pingInFlight ? nil : nextAutoPingDate()?.timeIntervalSinceNow
        let delay = min(kTickInterval, max(0.05, dueIn ?? kTickInterval))
        let next = Timer(timeInterval: delay, target: self, selector: #selector(tick), userInfo: nil, repeats: false)
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    // MARK: - 文件监听（替代定时轮询，有变化才扫描）

    func startWatching() {
        let path = NSHomeDirectory() + "/.claude/projects"
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.scanSessions()
                delegate.updateUI()
                delegate.scheduleTick()
            }
        }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               1.0,
                                               0) else { return }
        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        fsStream = stream
        log("已启动文件监听 \(path)")
    }

    // MARK: - 会话扫描

    func scanSessions() {
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/.claude/projects"
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return }
        let now = Date()
        var found: [String: SessionState] = [:]
        let activeIDs = activeSessionIDs()
        for d in dirs {
            let dirPath = root + "/" + d
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let path = dirPath + "/" + f
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let m = attrs[.modificationDate] as? Date else { continue }
                let id = String(f.dropLast(6))
                // 仍开着的会话（有活动锁）不受 30 分钟窗口限制，可以一直保活
                if now.timeIntervalSince(m) >= kSessionWindow && !activeIDs.contains(id) { continue }
                if var old = sessions[id] {
                    if old.mtime != m { refreshUserTurn(&old) }
                    old.mtime = m
                    found[id] = old
                } else {
                    let meta = readMeta(path: path)
                    guard let cwd = meta.cwd else { continue }
                    var s = SessionState(id: id, jsonlPath: path, cwd: cwd, version: meta.version ?? "",
                                         title: meta.title ?? "会话 \(id.prefix(8))",
                                         model: readTailModel(path: path) ?? "", mtime: m)
                    s.userTurn = readLastUserTurn(path: path)
                    if let saved = UserDefaults.standard.dictionary(forKey: "pingCount." + id),
                       saved["turn"] as? String == (s.userTurn ?? "") {
                        s.pingCount = saved["count"] as? Int ?? 0
                        s.lastPingSucceeded = saved["succeeded"] as? Bool
                    }
                    s.lastNote = "待首次 ping"
                    let key = "keep." + id
                    if let v = UserDefaults.standard.object(forKey: key) as? Bool {
                        s.selected = v
                    } else {
                        s.selected = true   // 默认勾选，手动取消才不 ping
                    }
                    found[id] = s
                }
            }
        }
        // 只保留仍可能活动的会话：有活动锁（Claude Code 正在运行）或 2 分钟内刚活跃
        sessions = found.filter { id, s in
            activeIDs.contains(id) || now.timeIntervalSince(s.mtime) < 120
        }
    }

    func activeSessionIDs() -> Set<String> {
        var ids = Set<String>()
        let dir = NSHomeDirectory() + "/.claude/sessions"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return ids }
        for f in files where f.hasSuffix(".json") {
            let path = dir + "/" + f
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = obj["sessionId"] as? String else { continue }
            if let pid = obj["pid"] as? Int, pid > 0, kill(pid_t(pid), 0) != 0 { continue }
            ids.insert(sid)
        }
        return ids
    }

    func refreshUserTurn(_ session: inout SessionState) {
        guard let turn = readLastUserTurn(path: session.jsonlPath), turn != session.userTurn else { return }
        session.userTurn = turn
        session.pingCount = 0
        session.lastPingSucceeded = nil
        session.finalRetryDone = false
        session.failCount = 0
        session.retryAt = nil
        UserDefaults.standard.removeObject(forKey: "pingCount." + session.id)
    }

    func savePingHistory(_ session: SessionState) {
        var history: [String: Any] = ["turn": session.userTurn ?? "", "count": session.pingCount]
        if let succeeded = session.lastPingSucceeded { history["succeeded"] = succeeded }
        UserDefaults.standard.set(history, forKey: "pingCount." + session.id)
    }

    func readLastUserTurn(path: String) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard var offset = try? file.seekToEnd() else { return nil }
        var partial = Data()
        while offset > 0 {
            let length = Int(min(offset, 64 * 1024))
            offset -= UInt64(length)
            guard (try? file.seek(toOffset: offset)) != nil,
                  var chunk = try? file.read(upToCount: length) else { return nil }
            chunk.append(partial)
            let firstComplete: Data.Index
            if offset == 0 {
                firstComplete = chunk.startIndex
            } else if let newline = chunk.firstIndex(of: 10) {
                firstComplete = chunk.index(after: newline)
                partial = Data(chunk[..<newline])
            } else {
                partial = chunk
                continue
            }
            for line in chunk[firstComplete...].split(separator: 10).reversed() {
                guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      entry["type"] as? String == "user", let id = entry["uuid"] as? String,
                      entry["isMeta"] as? Bool != true, entry["isSidechain"] as? Bool != true,
                      entry["isCompactSummary"] as? Bool != true,
                      entry["isVisibleInTranscriptOnly"] as? Bool != true,
                      let message = entry["message"] as? [String: Any] else { continue }
                if let text = message["content"] as? String, isUserText(text) { return id }
                if let blocks = message["content"] as? [[String: Any]], blocks.contains(where: { block in
                    let type = block["type"] as? String
                    return type == "image" || type == "document" ||
                        (type == "text" && isUserText(block["text"] as? String ?? ""))
                }) { return id }
            }
        }
        return nil
    }

    func isUserText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let internalPrefixes = ["<local-command-", "<command-name>", "<system-reminder>", "<task-notification>"]
        return !trimmed.isEmpty && !internalPrefixes.contains(where: trimmed.hasPrefix)
    }

    func readMeta(path: String) -> (cwd: String?, version: String?, title: String?) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return (nil, nil, nil) }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 200_000)
        let text = String(decoding: data, as: UTF8.self)
        var cwd: String?
        var ver: String?
        var title: String?
        var firstUserText: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if cwd == nil, let c = d["cwd"] as? String { cwd = c }
            if ver == nil, let v = d["version"] as? String { ver = v }
            let t = d["type"] as? String
            if title == nil && t == "ai-title", let at = d["aiTitle"] as? String, !at.isEmpty {
                title = at
            }
            if firstUserText == nil && t == "user" && (d["isMeta"] as? Bool) != true {
                if let m = d["message"] as? [String: Any] {
                    var txt = ""
                    if let c = m["content"] as? String { txt = c }
                    else if let arr = m["content"] as? [[String: Any]] {
                        txt = arr.compactMap { $0["text"] as? String }.joined(separator: " ")
                    }
                    txt = txt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !txt.isEmpty && !txt.hasPrefix("<") { firstUserText = String(txt.prefix(40)) }
                }
            }
            if cwd != nil && ver != nil && title != nil { break }
        }
        return (cwd, ver, title ?? firstUserText)
    }

    /// 从会话文件尾部找最近一次 assistant 使用的模型（避免 resume 时被 auto-mode 模型覆盖）
    func readTailModel(path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        let readSize = min(200_000, size)
        fh.seek(toFileOffset: UInt64(max(0, size - readSize)))
        let data = fh.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        var last: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let m = d["message"] as? [String: Any],
               (m["role"] as? String) == "assistant",
               let model = m["model"] as? String, !model.isEmpty {
                last = model
            }
        }
        return last
    }

    // MARK: - Ping

    // 完整 JSON 输出；用 CLAUDE_CODE_MAX_OUTPUT_TOKENS=1 把输出压到 ~2 token
    func ping(_ id: String, retryNoCap: Bool = false) {
        guard var s = sessions[id], !claudePath.isEmpty else {
            if retryNoCap, pingingSessionID == id {
                finishPing(id: id, read: 0, creation: 0, outTok: 0, note: "会话已退出保活范围")
            }
            return
        }
        if !retryNoCap { refreshUserTurn(&s) }
        pingingSessionID = id
        s.lastPing = Date()
        s.lastNote = "ping 中…"
        sessions[id] = s
        updateUI()

        let model = readTailModel(path: s.jsonlPath) ?? s.model
        if !model.isEmpty && model != s.model {
            s.model = model
            sessions[id] = s
        }
        var args = ["-p", "--resume", id, "--no-session-persistence",
                    "--permission-prompts", "none", "--permission-mode", "dontAsk",
                    "--max-turns", "1",
                    "--output-format", "json"]
        if !model.isEmpty { args.append(contentsOf: ["--model", model]) }
        args.append("Do not use any tools. Reply with just: ok")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: s.cwd)
        proc.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        if env["PATH"]?.contains("/opt/homebrew/bin") != true {
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                + ":" + NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        }
        // 只限回复长度上限（不碰 thinking 开关）：实测 out 稳定在 2~3 token
        if !retryNoCap { env["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = "1" }
        proc.environment = env
        log("[ping] \(id.prefix(8)) 启动 cap=\(retryNoCap ? "none" : "1") model=\(model.isEmpty ? "default" : model)")
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        do { try proc.run() } catch {
            finishPing(id: id, read: 0, creation: 0, outTok: 0, note: "启动失败: \(error.localizedDescription)")
            return
        }
        if !retryNoCap {
            s.pingCount += 1
            sessions[id] = s
            savePingHistory(s)
            updateUI()
        }
        // 超时不超过发送截止时间（294s）；最后补发至少给 30 秒机会
        let lastTouch = max(s.mtime, s.lastSuccess ?? .distantPast)
        let untilDeadline = kRetryDeadline - Date().timeIntervalSince(lastTouch)
        let timeout = min(kPingTimeout, max(30, untilDeadline))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if proc.isRunning {
                self.log("ping 超时，终止子进程 \(id.prefix(8))")
                proc.terminate()
            }
        }
        DispatchQueue.global().async {
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            var read = 0
            var creation = 0
            var outTok = 0
            var note = ""
            var failed = false
            if let obj = (try? JSONSerialization.jsonObject(with: outData)) as? [String: Any] {
                if let u = obj["usage"] as? [String: Any] {
                    read = u["cache_read_input_tokens"] as? Int ?? 0
                    creation = u["cache_creation_input_tokens"] as? Int ?? 0
                    outTok = u["output_tokens"] as? Int ?? 0
                }
                let isErr = obj["is_error"] as? Bool ?? false
                failed = isErr
                let result = (obj["result"] as? String ?? "").prefix(60)
                if read > 0 {
                    note = "读缓存 \(self.fmt(read))"
                } else if isErr {
                    note = "错误: \(result)"
                } else {
                    note = "读缓存 0"
                }
            } else {
                failed = true
                let e = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                note = "失败: \(e.suffix(100))"
            }
            if failed && read == 0 && !retryNoCap {
                // 某些模型要求 max_tokens 大于 thinking 预算，1 会报错：去掉上限重试一次
                self.log("[ping] \(id.prefix(8)) 带 cap 失败，去掉上限重试")
                DispatchQueue.main.async { self.ping(id, retryNoCap: true) }
                return
            }
            DispatchQueue.main.async {
                self.finishPing(id: id, read: read, creation: creation, outTok: outTok, note: note)
            }
        }
    }

    func finishPing(id: String, read: Int, creation: Int, outTok: Int, note: String) {
        if var s = sessions[id] {
            s.cacheReadTotal += read
            if s.pingCount > 0 {
                s.lastPingSucceeded = read > 0
                savePingHistory(s)
            }
            var finalNote = note
            if read == 0 && creation > 0 {
                // 前缀变了导致花大价钱重写缓存：再试一次让付费的 1h 重写刷新 TTL，连续两次才暂停
                s.consecutiveMiss += 1
                if s.consecutiveMiss >= 2 {
                    s.blocked = true
                    finalNote = "前缀不匹配（连续 miss），已暂停"
                } else {
                    finalNote = "未命中，下一轮再试一次"
                }
            } else if read > 0 {
                s.consecutiveMiss = 0
                s.failCount = 0
                s.retryAt = nil
                s.lastSuccess = Date()
                s.finalRetryDone = false
            } else {
                // 出错立即重试（最多 kMaxRetries 次）；到 294s 仍没回复则最后补发一次，再无果就停
                s.failCount += 1
                let now = Date()
                let lastTouch = max(s.mtime, s.lastSuccess ?? .distantPast)
                let deadline = lastTouch.addingTimeInterval(kRetryDeadline)
                if now < deadline && s.failCount <= kMaxRetries {
                    s.retryAt = now.addingTimeInterval(1)
                    finalNote = "\(note)（立即重试 \(s.failCount)/\(kMaxRetries)）"
                } else if !s.finalRetryDone {
                    s.finalRetryDone = true
                    s.retryAt = nil
                    finalNote = "\(note)（已到最后时刻，补发一次）"
                    sessions[id] = s
                    pingingSessionID = nil
                    log("[ping] \(id.prefix(8)) 到 \(Int(kRetryDeadline))s 未成功，最后补发一次")
                    updateUI()
                    scheduleTick()
                    ping(id)
                    return
                } else {
                    s.retryAt = nil
                    finalNote = "\(note)（已停止发送，等下次活动）"
                }
            }
            s.lastNote = finalNote
            sessions[id] = s
        }
        pingingSessionID = nil
        lastPingSucceeded = read > 0
        UserDefaults.standard.set(read > 0, forKey: "lastPingSucceeded")
        log("[ping] \(id.prefix(8)) read=\(read) creation=\(creation) out=\(outTok) \(note)")
        updateUI()
        scheduleTick()
    }

    // MARK: - UI

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menuSummary = NSMenuItem(title: "尚未选择会话", action: nil, keyEquivalent: "")
        menuSummary.isEnabled = false
        menu.addItem(menuSummary)
        menuTiming = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menuTiming.isEnabled = false
        menu.addItem(menuTiming)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "管理会话…", action: #selector(showWindow), keyEquivalent: ""))
        menuPing = NSMenuItem(title: "立即保活", action: #selector(pingNow), keyEquivalent: "p")
        menuPing.isEnabled = false
        menu.addItem(menuPing)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Claude保活工具", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu
        updateStatusIcon(needsRestore: false)
    }

    func setupWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 638, height: 414),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Claude保活工具"
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 440, height: 250)
        w.center()
        w.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 638, height: 414))

        summaryLabel = NSTextField(labelWithString: "0 个保活中 · 最多 \(kMaxSessions) 个")
        summaryLabel.frame = NSRect(x: 20, y: 375, width: 598, height: 20)
        summaryLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        summaryLabel.autoresizingMask = [.width, .minYMargin]
        content.addSubview(summaryLabel)

        scrollView = NSScrollView(frame: NSRect(x: 16, y: 62, width: 606, height: 298))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]
        docView = SessionListView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        scrollView.documentView = docView
        content.addSubview(scrollView)

        emptyLabel = NSTextField(labelWithString: "最近 \(Int(kSessionWindow / 60)) 分钟内没有活跃的 Claude Code 会话")
        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.frame = NSRect(x: 0, y: (docView.bounds.height - 20) / 2,
                                  width: docView.bounds.width, height: 20)
        docView.addSubview(emptyLabel)

        for offset in [CGFloat(60), 363] {
            let divider = NSBox(frame: NSRect(x: 20, y: offset, width: 598, height: 1))
            divider.boxType = .separator
            divider.autoresizingMask = offset == 60 ? [.width, .maxYMargin] : [.width, .minYMargin]
            content.addSubview(divider)
        }

        let logButton = NSButton(title: "打开日志", target: self, action: #selector(openLog))
        logButton.frame = NSRect(x: 16, y: 14, width: 96, height: 32)
        content.addSubview(logButton)

        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(manualRefresh))
        refreshButton.frame = NSRect(x: 120, y: 14, width: 64, height: 32)
        content.addSubview(refreshButton)

        pingButton = NSButton(title: "立即保活", target: self, action: #selector(pingNow))
        pingButton.frame = NSRect(x: 510, y: 14, width: 112, height: 32)
        pingButton.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(pingButton)

        w.contentView = content
        window = w
        updateUI()
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateUI()
    }

    @objc func updateUI() {
        guard window != nil else { return }
        let sorted = sessions.values.sorted {
            $0.mtime == $1.mtime ? $0.id < $1.id : $0.mtime > $1.mtime
        }
        let selected = sorted.filter(\.selected)
        let restoreCount = selected.filter(\.blocked).count
        let keptIDs = Set(selected.lazy.filter(self.canKeepAlive).prefix(kMaxSessions).map(\.id))
        summaryLabel.stringValue = "\(keptIDs.count) 个保活中 · 最多 \(kMaxSessions) 个"

        var summary = "\(keptIDs.count) 个会话保活中"
        if restoreCount > 0 { summary += " · \(restoreCount) 个待恢复" }
        menuSummary.title = selected.isEmpty ? "尚未选择会话" : summary
        let result = lastPingSucceeded.map { $0 ? "成功" : "失败" } ?? "暂无记录"
        let next = pingInFlight ? "发送中…" : nextAutoPingDate().map(countdown) ?? "暂无安排"
        let timing = "上次保活：\(result) · 下次：\(next)"
        if menuTiming.title != timing { menuTiming.title = timing }
        let canPing = !keptIDs.isEmpty && !pingInFlight
        menuPing.isEnabled = canPing
        menuPing.title = pingInFlight ? "保活中…" : "立即保活"
        pingButton.isEnabled = canPing
        pingButton.title = menuPing.title
        updateStatusIcon(needsRestore: restoreCount > 0)

        syncSessionRows(ids: sorted.prefix(10).map(\.id))
        for id in rowOrder {
            guard let session = sessions[id], let row = rows[id] else { continue }
            updateRow(row, session: session, keptAlive: keptIDs.contains(id))
        }
        setSleepBlock(!keptIDs.isEmpty)
    }

    /// 有保活任务时阻止系统睡眠；没有则释放，不影响正常休眠
    func setSleepBlock(_ on: Bool) {
        if on {
            guard sleepAssertion == 0 else { return }
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Claude Cache Keepalive" as CFString,
                &id)
            if result == kIOReturnSuccess {
                sleepAssertion = id
                log("已阻止系统睡眠（有保活任务）")
            }
        } else if sleepAssertion != 0 {
            IOPMAssertionRelease(sleepAssertion)
            sleepAssertion = 0
            log("已恢复系统睡眠策略（无保活任务）")
        }
    }

    func canKeepAlive(_ session: SessionState) -> Bool {
        !claudeVersion.isEmpty && session.selected && !session.blocked &&
            (session.version.isEmpty || session.version == claudeVersion) &&
            Date().timeIntervalSince(session.mtime) < kKeepWindow
    }

    /// 缓存是否可能仍然有效：以真实活动或上次 ping 中较晚者起算，超过 TTL 就视为已过期
    func cacheFresh(_ s: SessionState, now: Date) -> Bool {
        let last = max(s.mtime, s.lastPing ?? .distantPast)
        return now.timeIntervalSince(last) < kCacheTtl
    }

    /// 是否还在允许发送保活的时间窗内（距上次缓存活动 < 294 秒）
    func withinSendDeadline(_ s: SessionState, now: Date) -> Bool {
        let lastTouch = max(s.mtime, s.lastSuccess ?? .distantPast)
        return now.timeIntervalSince(lastTouch) < kRetryDeadline
    }

    func countdown(to date: Date) -> String {
        let seconds = max(0, Int(ceil(date.timeIntervalSinceNow)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func updateStatusIcon(needsRestore: Bool) {
        let label = needsRestore ? "Claude保活工具，有会话待恢复" : "Claude保活工具"
        guard let button = statusItem.button, button.toolTip != label else { return }
        let symbol = needsRestore ? "bolt.badge.exclamationmark" : "bolt.heart.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    func syncSessionRows(ids: [String]) {
        let visible = Set(ids)
        let order = rowOrder.filter { visible.contains($0) } + ids.filter { rows[$0] == nil }
        let viewport = scrollView.contentSize
        let width = viewport.width
        let height = max(CGFloat(order.count) * rowHeight, viewport.height)
        let orderChanged = order != rowOrder
        let size = NSSize(width: width, height: height)
        guard orderChanged || docView.bounds.size != size else { return }
        for id in rowOrder where !visible.contains(id) {
            rows.removeValue(forKey: id)?.view.removeFromSuperview()
        }
        rowOrder = order
        docView.setFrameSize(size)
        emptyLabel.isHidden = !order.isEmpty
        emptyLabel.frame = NSRect(x: 0, y: (viewport.height - 20) / 2, width: width, height: 20)
        for (index, id) in order.enumerated() {
            let row = rows[id] ?? makeSessionRow(id: id)
            row.view.frame = NSRect(x: 0, y: CGFloat(index) * rowHeight, width: width, height: rowHeight)
            row.divider.frame = NSRect(x: 8, y: 0, width: width - 24, height: 1)
            row.divider.isHidden = index == order.count - 1
            rows[id] = row
        }
        if orderChanged { window.recalculateKeyViewLoop() }
    }

    func makeSessionRow(id: String) -> RowView {
        let row = NSView()
        row.identifier = NSUserInterfaceItemIdentifier(id)
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        row.addGestureRecognizer(click)
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSession(_:)))
        checkbox.frame = NSRect(x: 8, y: 14, width: 20, height: 20)
        checkbox.identifier = NSUserInterfaceItemIdentifier(id)

        let title = NSTextField(labelWithString: "")
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = NSFont.systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        status.alignment = .right
        let detail = NSTextField(labelWithString: "")
        detail.font = subtitle.font
        detail.textColor = .secondaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingHead

        let restore = NSButton(title: "恢复", target: self, action: #selector(restoreSession(_:)))
        restore.controlSize = .small
        restore.identifier = checkbox.identifier
        let divider = NSBox()
        divider.boxType = .separator
        for view in [checkbox, title, subtitle, status, detail, restore, divider] as [NSView] {
            row.addSubview(view)
        }
        docView.addSubview(row)
        return RowView(view: row, checkbox: checkbox, title: title, subtitle: subtitle,
                       status: status, detail: detail, restore: restore, divider: divider)
    }

    func updateRow(_ row: RowView, session: SessionState, keptAlive: Bool) {
        let title = session.title == "会话 \(session.id.prefix(8))" ? "未命名会话" : session.title
        row.checkbox.state = session.selected ? .on : .off
        row.checkbox.setAccessibilityLabel("启用「\(title)」的保活")
        row.title.stringValue = title
        row.title.toolTip = title
        let project = (session.cwd as NSString).lastPathComponent
        var subtitleParts = [project]
        if !session.model.isEmpty {
            var m = session.model.components(separatedBy: "/").last ?? session.model
            m = m.replacingOccurrences(of: "[1m]", with: "")
            subtitleParts.append(m)
        }
        subtitleParts.append("\(timeAgo(session.mtime))活跃")
        row.subtitle.stringValue = subtitleParts.joined(separator: " · ")

        let needsRestore = session.selected && session.blocked
        let status: String
        if pingingSessionID == session.id {
            status = "正在发送保活…"
        } else if !session.selected {
            status = "未启用"
        } else if needsRestore {
            status = "已暂停 · 连续未命中"
        } else if claudeVersion.isEmpty {
            status = claudePath.isEmpty ? "未找到 Claude Code" : "等待 Claude Code"
        } else if !canKeepAlive(session) {
            if !session.version.isEmpty && session.version != claudeVersion {
                status = "版本不匹配"
            } else {
                status = "已停止 · 超过 \(Int(kKeepWindow / 60)) 分钟未活动"
            }
        } else if !cacheFresh(session, now: Date()) {
            status = "缓存已过期 · 等待新消息"
        } else if let due = automaticPingDate(for: session) {
            let next = pingInFlight && due <= Date() ? "等待发送" : "距下次保活 \(countdown(to: due))"
            status = keptAlive ? next : "排队中 · \(next)"
        } else {
            status = "暂无保活安排"
        }
        row.status.stringValue = status
        row.status.textColor = needsRestore ? .systemOrange : (keptAlive ? .labelColor : .secondaryLabelColor)
        let sent = "本轮已发 \(session.pingCount) 次"
        if let succeeded = session.lastPingSucceeded, !needsRestore {
            row.detail.stringValue = "\(sent) · 上次\(succeeded ? "成功" : "失败")"
        } else {
            row.detail.stringValue = sent
        }
        row.detail.toolTip = "发送一条新消息后重新计数"
        row.restore.isHidden = !needsRestore
        row.restore.setAccessibilityLabel("恢复「\(title)」的保活")

        let width = row.view.bounds.width
        let statusX = width - 212
        let statusWidth = width - statusX - (needsRestore ? 77 : 16)
        row.title.frame = NSRect(x: 36, y: 24, width: statusX - 44, height: 18)
        row.subtitle.frame = NSRect(x: 36, y: 7, width: statusX - 44, height: 16)
        row.status.frame = NSRect(x: statusX, y: 24, width: statusWidth, height: 18)
        row.detail.frame = NSRect(x: statusX, y: 7, width: statusWidth, height: 16)
        row.restore.frame = NSRect(x: width - 69, y: 11, width: 58, height: 26)
    }

    func timeAgo(_ d: Date) -> String {
        let sec = max(0, Int(Date().timeIntervalSince(d)))
        if sec < 60 { return "\(sec) 秒前" }
        if sec < 3600 { return "\(sec / 60) 分钟前" }
        return "\(sec / 3600) 小时前"
    }

    func fmt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.0fK", Double(n) / 1000) }
        return "\(n)"
    }

    // MARK: - 动作

    @objc func rowClicked(_ g: NSClickGestureRecognizer) {
        guard let view = g.view, let raw = view.identifier?.rawValue,
              let session = sessions[raw] else { return }
        let p = g.location(in: view)
        if let cb = rows[raw]?.checkbox, cb.frame.contains(p) { return }
        if let rb = rows[raw]?.restore, !rb.isHidden, rb.frame.contains(p) { return }
        let on = !session.selected
        sessions[raw]?.selected = on
        UserDefaults.standard.set(on, forKey: "keep." + raw)
        log("会话 \(raw.prefix(8)) \(on ? "勾选" : "取消勾选")（行点击）")
        updateUI()
        scheduleTick()
    }

    @objc func toggleSession(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let on = sender.state == .on
        sessions[id]?.selected = on
        UserDefaults.standard.set(on, forKey: "keep." + id)
        log("会话 \(id.prefix(8)) \(on ? "勾选" : "取消勾选")")
        updateUI()
        scheduleTick()
    }

    @objc func pingNow() {
        guard !pingInFlight, kMaxSessions > 0, !claudePath.isEmpty else { return }
        let session = sessions.values.lazy.filter(self.canKeepAlive).max {
            $0.mtime == $1.mtime ? $0.id > $1.id : $0.mtime < $1.mtime
        }
        guard let session = session else { return }
        log("手动立即 ping \(session.id.prefix(8))")
        ping(session.id)
    }

    @objc func restoreSession(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, var session = sessions[id],
              session.selected, session.blocked else { return }
        session.blocked = false
        session.consecutiveMiss = 0
        session.lastNote = "已恢复"
        sessions[id] = session
        log("恢复会话 \(id.prefix(8))")
        if window.firstResponder === sender, let checkbox = rows[id]?.checkbox {
            window.makeFirstResponder(checkbox)
        }
        updateUI()
        scheduleTick()
    }

    @objc func manualRefresh() {
        scanSessions()
        updateUI()
        log("手动刷新会话列表")
    }

    @objc func openLog() {
        NSWorkspace.shared.open(logURL)
    }

    @objc func quit() {
        log("退出")
        NSApp.terminate(nil)
    }

    // MARK: - 日志

    func rotateLogIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int, size > 1_000_000 else { return }
        try? fm.removeItem(atPath: logURL.path + ".1")
        try? fm.moveItem(atPath: logURL.path, toPath: logURL.path + ".1")
    }

    func log(_ msg: String) {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
