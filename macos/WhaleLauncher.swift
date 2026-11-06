import AppKit
import SwiftUI

final class LauncherModel: ObservableObject {
    static let shared = LauncherModel()
    @Published var baseURL = "https://api.deepseek.com"
    @Published var model = "deepseek-flash"
    @Published var apiKey = ""
    @Published var chat = ""
    @Published var privateChatConfirmed = false
    @Published var running = false
    @Published var busy = false
    @Published var bridging = false
    @Published var status = "内核未启动"
    @Published var bridgeStatus = "微信桥接未启用"
    @Published var serviceURL = ""
    @Published var python = ""
    let root: URL
    let payload: URL
    private var process: Process?
    private var installer: Process?
    private var input: Pipe?
    private let outputQueue = DispatchQueue(label: "whale.output")
    private var outputBuffer = Data()
    var onProcessExit: (() -> Void)?

    init() {
        root = ProcessInfo.processInfo.environment["WHALE_MAC_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WhaleGirl")
        payload = Bundle.main.resourceURL!.appendingPathComponent("app")
        python = root.appendingPathComponent("bridge-venv/bin/python").path
        let file = root.appendingPathComponent("data/settings.json")
        if let data = try? Data(contentsOf: file), let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            baseURL = settings["baseUrl"] as? String ?? baseURL
            model = settings["model"] as? String ?? model
            apiKey = settings["apiKey"] as? String ?? ""
        }
        if let data = try? Data(contentsOf: root.appendingPathComponent("macos.json")),
           let settings = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            chat = settings["chat"] ?? ""
            python = settings["python"] ?? python
        }
    }

    func save() throws {
        guard let url = URL(string: baseURL), ["http", "https"].contains(url.scheme ?? ""), url.host != nil,
              !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw NSError(domain: "WhaleGirl", code: 1, userInfo: [NSLocalizedDescriptionKey: "请填写有效的模型地址和模型名称"])
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("data/settings.json")
        var settings = ((try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        settings["provider"] = "custom"
        settings["baseUrl"] = baseURL.trimmingCharacters(in: .whitespaces)
        settings["model"] = model.trimmingCharacters(in: .whitespaces)
        settings["apiKey"] = apiKey.trimmingCharacters(in: .whitespaces)
        try write(settings, to: file)
        try write(["chat": chat, "python": python], to: root.appendingPathComponent("macos.json"))
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func start() {
        guard process == nil else { return }
        do {
            try save()
            let task = Process(), stdin = Pipe(), stdout = Pipe()
            task.executableURL = Bundle.main.resourceURL!.appendingPathComponent("node/bin/node")
            task.arguments = [payload.appendingPathComponent("macos/host.js").path, root.path]
            task.currentDirectoryURL = root
            task.standardInput = stdin
            task.standardOutput = stdout
            // 内核完整日志留在 data/；UI 只展示结构化生命周期事件。
            task.standardError = stdout
            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                self?.outputQueue.async { self?.consume(data) }
            }
            task.terminationHandler = { [weak self] task in
                stdout.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    guard let self = self, self.process === task else { return }
                    self.process = nil; self.input = nil
                    self.running = false; self.busy = false; self.bridging = false; self.serviceURL = ""
                    self.status = task.terminationStatus == 0 ? "内核已停止" : "内核异常退出（\(task.terminationStatus)），请检查数据目录日志"
                    self.onProcessExit?()
                    self.onProcessExit = nil
                }
            }
            process = task; input = stdin; busy = true; status = "正在启动…"
            try task.run()
        } catch {
            process = nil; input = nil; busy = false
            status = error.localizedDescription
        }
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = String(decoding: outputBuffer[..<newline], as: UTF8.self)
            outputBuffer.removeSubrange(...newline)
            guard line.hasPrefix("WHALE_MAC "),
                  let json = String(line.dropFirst(10)).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: json) as? [String: String] else { continue }
            DispatchQueue.main.async { [weak self] in self?.receive(event) }
        }
        if outputBuffer.count > 1_000_000 { outputBuffer.removeAll() }
    }

    private func receive(_ event: [String: String]) {
        let detail = event["detail"] ?? ""
        switch event["event"] {
        case "ready": running = true; busy = false; serviceURL = detail; status = "内核运行中"
        case "bridge-status": bridgeStatus = detail
        case "bridge-error": bridgeStatus = "桥接已停止：\(detail)"
        case "bridge-stopped": bridging = false
        default: break
        }
    }

    func command(_ object: [String: String]) {
        guard let pipe = input, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do { try pipe.fileHandleForWriting.write(contentsOf: data + Data([10])) }
        catch { status = "内核控制管道已关闭" }
    }

    func stop() {
        guard let owned = process else { return }
        busy = true; status = "正在保存记忆并停止…"
        command(["action": "shutdown"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if self.process === owned && owned.isRunning { owned.terminate() }
        }
    }

    func startBridge() {
        guard running && privateChatConfirmed && !chat.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard FileManager.default.isExecutableFile(atPath: python) else {
            bridgeStatus = "请先安装桥接环境，或填写正确的 Python 绝对路径"; return
        }
        do { try save() } catch { bridgeStatus = error.localizedDescription; return }
        bridging = true
        command(["action": "bridge-start", "python": python, "chat": chat.trimmingCharacters(in: .whitespaces)])
    }

    func stopBridge() {
        command(["action": "bridge-stop"])
        bridgeStatus = "微信桥接已停止"
    }

    func installBridge() {
        guard installer == nil && !running else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [payload.appendingPathComponent("scripts/setup-macos-bridge.sh").path, root.path]
        let log = root.appendingPathComponent("bridge-install.log")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log)
            task.standardOutput = handle; task.standardError = handle
            task.terminationHandler = { [weak self] task in
                try? handle.close()
                DispatchQueue.main.async {
                    self?.installer = nil; self?.busy = false
                    self?.bridgeStatus = task.terminationStatus == 0
                        ? "桥接环境安装完成，请为桥接 Python 授权辅助功能和屏幕录制"
                        : "安装失败。请先安装 uv；详情见数据目录 bridge-install.log"
                }
            }
            installer = task; busy = true; bridgeStatus = "正在下载 Python 和桥接依赖…"
            try task.run()
        } catch { installer = nil; busy = false; bridgeStatus = error.localizedDescription }
    }

    var hasChild: Bool { process != nil || installer != nil }
    var installing: Bool { installer != nil }
    func quit() { stop() }
    func openData() { NSWorkspace.shared.open(root) }
    var pythonExecutable: URL { URL(fileURLWithPath: python).resolvingSymlinksInPath() }
    func revealPython() { NSWorkspace.shared.activateFileViewerSelecting([pythonExecutable]) }
    func permissions(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}

struct LauncherView: View {
    @ObservedObject var state = LauncherModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("🐋 鲸鲸").font(.largeTitle.bold())
                Text("macOS · 实验版").foregroundStyle(.secondary)
                Spacer()
                Text(state.status).font(.callout).foregroundStyle(state.running ? .green : .secondary)
            }
            GroupBox("模型服务") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow { Text("接口地址"); TextField("https://api.deepseek.com", text: $state.baseURL) }
                    GridRow { Text("模型名称"); TextField("deepseek-flash", text: $state.model) }
                    GridRow { Text("API Key"); SecureField("留空进入演示模式；本地模型无需 Key", text: $state.apiKey) }
                }.textFieldStyle(.roundedBorder).padding(10).disabled(state.running || state.busy)
            }
            HStack {
                Button("保存并启动内核") { state.start() }.disabled(state.running || state.busy).keyboardShortcut(.defaultAction)
                Button("停止内核") { state.stop() }.disabled(!state.running || state.busy)
                Spacer()
                Button("数据目录") { state.openData() }
            }
            if !state.serviceURL.isEmpty {
                Text("HTTP API：\(state.serviceURL)（无网页界面）").font(.caption).textSelection(.enabled)
            }
            GroupBox("微信文字桥接") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("只监听当前打开的一个私聊。请保持微信前台、停留在最新消息，输入框留空。启动前的消息不会回复。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack { Text("私聊名称"); TextField("与微信会话标题完全一致", text: $state.chat) }
                    HStack { Text("桥接 Python"); TextField("绝对路径", text: $state.python) }
                    Toggle("已确认目标是私聊，并允许自动回复新文字消息", isOn: $state.privateChatConfirmed)
                    HStack {
                        Button("启用微信桥接") { state.startBridge() }
                            .disabled(!state.running || state.bridging || !state.privateChatConfirmed || state.chat.isEmpty)
                        Button("停止桥接") { state.stopBridge() }.disabled(!state.bridging)
                        Spacer()
                        Button("安装桥接环境") { state.installBridge() }.disabled(state.running || state.busy)
                    }
                    Text(state.bridgeStatus).font(.callout).textSelection(.enabled)
                    HStack {
                        Button("辅助功能权限") { state.permissions("Privacy_Accessibility") }
                        Button("屏幕录制权限") { state.permissions("Privacy_ScreenCapture") }
                        Button("显示 Python") { state.revealPython() }
                            .disabled(!FileManager.default.isExecutableFile(atPath: state.python))
                        Link("安装 uv", destination: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
                    }.font(.caption)
                    Text("系统可能把桥接识别为 python3.12。请授权“显示 Python”定位的文件；权限也适用于通过同一解释器运行的其他脚本。")
                        .font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder).padding(10)
            }
            Text("UI 自动化：不注入进程、不读取微信数据库。群聊、图片和语音暂不支持。切换会话、有草稿或发送结果不明时停止；不能保证不触发微信风控。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 720)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = LauncherModel.shared
        if model.installing {
            model.bridgeStatus = "桥接环境安装进行中，请等待完成后退出"
            return .terminateCancel
        }
        guard model.hasChild else { return .terminateNow }
        // terminateLater 的退出流程不会驱动普通 Timer；直接由子进程退出回调答复。
        model.onProcessExit = { sender.reply(toApplicationShouldTerminate: true) }
        model.quit()
        return .terminateLater
    }
}

@main
struct WhaleLauncher: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("鲸鲸 · macOS") { LauncherView() }
            .windowResizability(.contentSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
