import Cocoa
import Security
import Darwin

let appID = "local.aiusagebar.mac"
let fm = FileManager.default
let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AIusagebar")
enum BarError: Error { case message(String) }
func problem(_ text: String) -> BarError { .message(text) }
func errorText(_ error: Error) -> String {
    if case BarError.message(let text) = error { return text }
    return "연결 오류 — 네트워크/설치를 확인해 주세요"
}
func json(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw problem("응답 형식 오류") }
    return value
}
struct Usage { let percent: Double; let reset: Date? }
func codexUsage(_ result: [String: Any]) throws -> Usage {
    let byID = result["rateLimitsByLimitId"] as? [String: Any]
    guard let limits = (byID?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) else { throw problem("Codex 로그인/구독 확인 필요") }
    for name in ["primary", "secondary"] {
        if let window = limits[name] as? [String: Any],
           (window["windowDurationMins"] as? NSNumber)?.intValue == 10080,
           let percent = window["usedPercent"] as? NSNumber {
            return Usage(percent: min(100, max(0, percent.doubleValue)), reset: (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
    }
    throw problem("이 계정에서 주간 사용량을 제공하지 않습니다")
}
func claudeUsage(_ result: [String: Any]) throws -> Usage {
    guard let weekly = result["seven_day"] as? [String: Any], let percent = weekly["utilization"] as? NSNumber else { throw problem("이 계정에서 주간 사용량을 제공하지 않습니다") }
    var reset: Date?
    if let text = weekly["resets_at"] as? String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        reset = formatter.date(from: text)
        if reset == nil { formatter.formatOptions = [.withInternetDateTime]; reset = formatter.date(from: text) }
    }
    return Usage(percent: min(100, max(0, percent.doubleValue)), reset: reset)
}
func environment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let home = fm.homeDirectoryForCurrentUser.path
    env["PATH"] = "\(home)/.local/bin:\(home)/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
    return env
}
func executable(_ name: String) -> String? {
    for directory in (environment()["PATH"] ?? "").split(separator: ":") {
        let path = String(directory) + "/" + name
        if fm.isExecutableFile(atPath: path) { return path }
    }
    if name == "codex" {
        for root in ["/Applications", fm.homeDirectoryForCurrentUser.path + "/Applications"] {
            let path = root + "/Codex.app/Contents/Resources/codex"
            if fm.isExecutableFile(atPath: path) { return path }
        }
    }
    return nil
}

// Same newline-delimited app-server requests as the Windows widget.
final class CodexRPC {
    let process = Process(), input = Pipe(), output = Pipe()
    var pending = Data(), nextID = 0
    init(_ path: String) throws {
        process.executableURL = URL(fileURLWithPath: path); process.arguments = ["app-server", "--stdio"]
        process.environment = environment(); process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice; try process.run()
    }
    deinit {
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
    }
    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value); data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
    func request(_ method: String, _ params: [String: Any]? = nil) throws -> [String: Any] {
        nextID += 1
        var value: [String: Any] = ["id": nextID, "method": method]
        if let params = params { value["params"] = params }; try send(value)
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[..<end]); pending.removeSubrange(...end)
                guard !line.isEmpty else { continue }
                let response = try json(line)
                guard (response["id"] as? NSNumber)?.intValue == nextID else { continue }
                if response["error"] != nil { throw problem("Codex 로그인/계정 확인 필요") }
                return response["result"] as? [String: Any] ?? [:]
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let status = poll(&descriptor, 1, 250)
            if status < 0 { if errno == EINTR { continue }; throw problem("Codex 연결 오류") }
            if status > 0 {
                var buffer = [UInt8](repeating: 0, count: 8192)
                let size = Darwin.read(descriptor.fd, &buffer, buffer.count)
                if size <= 0 { throw problem("Codex 연결 종료 — 로그인/설치 확인 필요") }
                pending.append(contentsOf: buffer.prefix(size))
                if pending.count > 2_000_000 { throw problem("Codex 응답 형식 오류") }
            }
        }
        throw problem("Codex 응답 시간 초과")
    }
}
func readCodex() throws -> Usage {
    guard let path = executable("codex") else { throw problem("Codex CLI 설치 필요 — 안내를 눌러 주세요") }
    let rpc = try CodexRPC(path)
    _ = try rpc.request("initialize", ["clientInfo": ["name": "ai-usage-bar", "title": "AI Usage Bar", "version": "1.0.0"]])
    try rpc.send(["method": "initialized", "params": [:]])
    return try codexUsage(rpc.request("account/rateLimits/read"))
}

struct HTTPResult { let status: Int; let body: Data; let retry: String? }
// URLSession's callback finishes before the waiting worker reads this box.
final class HTTPBox { var result: HTTPResult? }
func http(_ request: URLRequest) throws -> HTTPResult {
    let semaphore = DispatchSemaphore(value: 0), box = HTTPBox()
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
    let session = URLSession(configuration: config)
    let task = session.dataTask(with: request) { data, response, _ in
        if let response = response as? HTTPURLResponse {
            box.result = HTTPResult(status: response.statusCode, body: data ?? Data(), retry: response.value(forHTTPHeaderField: "Retry-After"))
        }; semaphore.signal()
    }
    task.resume()
    if semaphore.wait(timeout: .now() + 22) == .timedOut { task.cancel(); session.invalidateAndCancel(); throw problem("Claude 연결 시간 초과") }
    session.finishTasksAndInvalidate()
    guard let result = box.result else { throw problem("Claude 연결 오류") }; return result
}
struct Credential {
    var value: [String: Any]; let file: URL?
    var oauth: [String: Any] { value["claudeAiOauth"] as? [String: Any] ?? [:] }
}
func credentials() throws -> Credential {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data, let value = try? json(data), value["claudeAiOauth"] != nil { return Credential(value: value, file: nil) }
    let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
        ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    let file = root.appendingPathComponent(".credentials.json")
    if let data = try? Data(contentsOf: file), let value = try? json(data), value["claudeAiOauth"] != nil { return Credential(value: value, file: file) }
    throw problem("Claude Code 로그인/키체인 접근 허용 필요")
}
func saveCredentials(_ value: [String: Any], file: URL?) throws {
    let data = try JSONSerialization.data(withJSONObject: value)
    if let file = file {
        try data.write(to: file, options: .atomic); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } else {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Claude Code-credentials"]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecSuccess { throw problem("키체인 갱신 실패 — Claude Code 재로그인 필요") }
    }
}
final class ClaudeClient {
    let defaults = UserDefaults.standard
    func checkCooldown() throws {
        let seconds = defaults.double(forKey: "claudeRetryUntil") - Date().timeIntervalSince1970
        if seconds > 0 { throw problem("Claude 요청 제한 — \(Int(ceil(seconds / 60)))분 후 자동 재시도") }
    }
    func throttle(_ reply: HTTPResult) -> BarError {
        let failures = min(5, defaults.integer(forKey: "claudeRetryFailures") + 1)
        var delay = min(600.0, 60 * pow(2.0, Double(failures - 1)))
        if let header = reply.retry {
            if let seconds = Double(header) { delay = max(delay, seconds) }
            else {
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
                if let date = formatter.date(from: header) { delay = max(delay, date.timeIntervalSinceNow) }
            }
        }
        defaults.set(Date().timeIntervalSince1970 + delay, forKey: "claudeRetryUntil"); defaults.set(failures, forKey: "claudeRetryFailures")
        return problem("Claude 요청 제한 — \(Int(ceil(delay / 60)))분 후 자동 재시도")
    }
    func token(force: Bool = false, rejected: String? = nil) throws -> String {
        let fd = Darwin.open(support.appendingPathComponent("claude-refresh.lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        guard fd >= 0 else { throw problem("Claude 인증 잠금 오류") }
        defer { _ = flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw problem("Claude 인증 갱신 중") }
        let credential = try credentials()
        guard let access = credential.oauth["accessToken"] as? String, !access.isEmpty else { throw problem("Claude Code 로그인 필요") }
        if force, let rejected = rejected, rejected != access { return access }
        let expires = (credential.oauth["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        if !force && (expires == 0 || expires > Date().timeIntervalSince1970 * 1000 + 60_000) { return access }
        guard let refresh = credential.oauth["refreshToken"] as? String, !refresh.isEmpty else { throw problem("Claude Code 재로그인 필요") }
        try checkCooldown()
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"]
        if let scopes = credential.oauth["scopes"] as? [String], !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("AIusagebar-mac/1.0.0", forHTTPHeaderField: "User-Agent")
        let reply = try http(request)
        if reply.status == 429 { throw throttle(reply) }
        guard reply.status == 200 else {
            let latest = try credentials()
            if let newer = latest.oauth["accessToken"] as? String, newer != access { return newer }
            throw problem("Claude 인증 갱신 실패 — Claude Code 재로그인 필요")
        }
        let response = try json(reply.body)
        guard let newAccess = response["access_token"] as? String, !newAccess.isEmpty,
              let lifetime = response["expires_in"] as? NSNumber, lifetime.doubleValue > 0 else { throw problem("Claude 인증 응답 오류") }
        var latest = try credentials()
        if let newer = latest.oauth["accessToken"] as? String, newer != access { return newer }
        guard latest.oauth["refreshToken"] as? String == refresh else { throw problem("Claude 로그인 변경됨 — 다시 새로고침해 주세요") }
        var oauth = latest.oauth
        oauth["accessToken"] = newAccess; oauth["expiresAt"] = (Date().timeIntervalSince1970 + lifetime.doubleValue) * 1000
        if let replacement = response["refresh_token"] as? String { oauth["refreshToken"] = replacement }
        if let scope = response["scope"] as? String { oauth["scopes"] = scope.components(separatedBy: " ") }
        if let expiry = response["refresh_token_expires_in"] as? NSNumber { oauth["refreshTokenExpiresAt"] = (Date().timeIntervalSince1970 + expiry.doubleValue) * 1000 }
        latest.value["claudeAiOauth"] = oauth; try saveCredentials(latest.value, file: latest.file); return newAccess
    }
    func usage() throws -> Usage {
        try checkCooldown(); var access = try token()
        for attempt in 0..<2 {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer " + access, forHTTPHeaderField: "Authorization"); request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            let reply = try http(request)
            if reply.status == 429 { throw throttle(reply) }
            if reply.status == 401 && attempt == 0 { access = try token(force: true, rejected: access); continue }
            if reply.status == 401 || reply.status == 403 { throw problem("Claude Code 재로그인/구독 확인 필요") }
            guard reply.status == 200 else { throw problem("Claude 연결 오류 (HTTP \(reply.status))") }
            let usage = try claudeUsage(json(reply.body))
            defaults.set(0, forKey: "claudeRetryUntil"); defaults.set(0, forKey: "claudeRetryFailures"); return usage
        }
        throw problem("Claude Code 재로그인 필요")
    }
}

final class UsageRow {
    let stack = NSStackView(), bar = NSProgressIndicator()
    let percent = NSTextField(labelWithString: "--% 사용 / 7일")
    let detail = NSTextField(wrappingLabelWithString: "로그인을 확인하는 중…")
    var last: Usage?
    init(_ title: String) {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        let heading = NSTextField(labelWithString: title); heading.font = .boldSystemFont(ofSize: 16)
        percent.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        detail.textColor = .secondaryLabelColor; detail.font = .systemFont(ofSize: 12)
        bar.isIndeterminate = false; bar.minValue = 0; bar.maxValue = 100; bar.style = .bar
        let views: [NSView] = [heading, percent, bar, detail]
        for view in views { stack.addArrangedSubview(view) }
        bar.widthAnchor.constraint(equalToConstant: 430).isActive = true
        detail.widthAnchor.constraint(equalToConstant: 430).isActive = true
    }
    func update(_ result: Result<Usage, Error>) {
        switch result {
        case .success(let value):
            last = value; bar.doubleValue = value.percent; percent.stringValue = "\(Int(value.percent.rounded()))% 사용 / 7일"
            percent.textColor = value.percent >= 90 ? .systemRed : value.percent >= 70 ? .systemOrange : .labelColor
            let formatter = DateFormatter(); formatter.dateFormat = "MM/dd HH:mm"
            detail.stringValue = "초기화: " + (value.reset.map { formatter.string(from: $0) } ?? "정보 없음")
        case .failure(let error):
            if last == nil { percent.stringValue = "--% 사용 / 7일"; bar.doubleValue = 0 }
            percent.textColor = .secondaryLabelColor
            detail.stringValue = errorText(error) + (last == nil ? "" : "\n이전 조회 결과를 표시 중입니다")
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let codex = UsageRow("ChatGPT · Codex"), claude = UsageRow("Claude · 전체 모델")
    let status = NSTextField(labelWithString: "2분마다 자동 새로고침")
    let refresh = NSButton(title: "새로고침", target: nil, action: nil)
    let client = ClaudeClient()
    var timer: Timer?, busy = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), root = NSMenuItem(); menu.addItem(root)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "AI Usage Bar 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 470), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "AI Usage Bar"; window.isReleasedWhenClosed = false; window.center(); window.setFrameAutosaveName("AIusagebarMainWindow")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        let title = NSTextField(labelWithString: "이번 주 AI 사용량"); title.font = .boldSystemFont(ofSize: 21)
        stack.addArrangedSubview(title); stack.addArrangedSubview(codex.stack); stack.addArrangedSubview(claude.stack)
        let buttons = NSStackView(); buttons.orientation = .horizontal; buttons.spacing = 8
        refresh.target = self; refresh.action = #selector(update); buttons.addArrangedSubview(refresh)
        for (label, action) in [("Codex 로그인", #selector(loginCodex)), ("Claude 로그인", #selector(loginClaude)), ("안내", #selector(help))] { buttons.addArrangedSubview(NSButton(title: label, target: self, action: action)) }
        stack.addArrangedSubview(buttons); status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor; stack.addArrangedSubview(status)
        window.contentView!.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer = Timer.scheduledTimer(timeInterval: 120, target: self, selector: #selector(update), userInfo: nil, repeats: true)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(update), name: NSWorkspace.didWakeNotification, object: nil); update()
    }
    @objc func update() {
        guard !busy else { return }; busy = true; refresh.isEnabled = false; status.stringValue = "사용량 조회 중…"
        DispatchQueue.global(qos: .utility).async {
            let a = Result { try readCodex() }; DispatchQueue.main.async { self.codex.update(a) }
            let b = Result { try self.client.usage() }
            DispatchQueue.main.async {
                self.claude.update(b); self.busy = false; self.refresh.isEnabled = true
                let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"
                self.status.stringValue = "조회 완료 \(formatter.string(from: Date())) · 2분마다 자동 새로고침"
            }
        }
    }
    func login(_ name: String, arguments: String) {
        guard let path = executable(name) else { help(); return }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/bash\nexport PATH=\(quote(environment()["PATH"]!))\ncd \"$HOME\"\nunset OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN\n\(quote(path)) \(arguments)\necho '\n로그인 후 AI Usage Bar에서 새로고침을 눌러 주세요.'\nread -r -p 'Enter를 누르면 종료합니다.'\n"
        let url = support.appendingPathComponent("\(name)-login.command")
        do { try script.write(to: url, atomically: true, encoding: .utf8); try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path); NSWorkspace.shared.open(url) }
        catch { let alert = NSAlert(); alert.messageText = "로그인 창 열기 실패"; alert.informativeText = "사용설명서의 터미널 명령을 이용해 주세요."; alert.runModal() }
    }
    @objc func loginCodex() { login("codex", arguments: "login") }
    @objc func loginClaude() { login("claude", arguments: "auth login") }
    @objc func help() {
        if let url = Bundle.main.url(forResource: "사용설명서", withExtension: "txt") { NSWorkspace.shared.open(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}
func selfTest() throws {
    let a = try codexUsage(["rateLimits": ["primary": ["windowDurationMins": 300, "usedPercent": 99], "secondary": ["windowDurationMins": 10080, "usedPercent": 42, "resetsAt": 1700000000]]])
    guard a.percent == 42 && a.reset != nil else { throw problem("Codex weekly selection failed") }
    let b = try codexUsage(["rateLimits": [:], "rateLimitsByLimitId": ["codex": ["primary": ["windowDurationMins": 10080, "usedPercent": 120]]]])
    guard b.percent == 100 else { throw problem("Named limits/clamping failed") }
    let c = try claudeUsage(["seven_day": ["utilization": 25.5, "resets_at": "2026-10-12T12:00:00.123Z"]])
    guard c.percent == 25.5 && c.reset != nil else { throw problem("Claude weekly parsing failed") }
    var rejected = false
    do { _ = try codexUsage(["rateLimits": ["primary": ["windowDurationMins": 300, "usedPercent": 20]]]) } catch { rejected = true }
    guard rejected else { throw problem("Non-weekly data accepted") }
    print("PASS: weekly selection, named limits, clamping, Claude dates, missing weekly data")
}
if CommandLine.arguments.contains("--self-test") { do { try selfTest(); exit(0) } catch { print(errorText(error)); exit(1) } }
try? fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
let application = NSApplication.shared
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: appID).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    existing.activate(options: [.activateAllWindows, .activateIgnoringOtherApps]); exit(0)
}
application.setActivationPolicy(.regular)
let delegate = AppDelegate(); application.delegate = delegate; application.run()
