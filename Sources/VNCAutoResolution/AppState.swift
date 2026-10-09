import Foundation
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var clients: [String] = []
    @Published private(set) var options: [ResolutionOption] = []
    @Published private(set) var currentID: String?
    @Published private(set) var lastMessage: String = ""

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    @Published var targetID: String {
        didSet { defaults.set(targetID, forKey: Keys.target) }
    }
    @Published var launchAtLogin: Bool {
        didSet { updateLoginItem() }
    }

    var isConnected: Bool { !clients.isEmpty }

    private let defaults = UserDefaults.standard
    private let pollInterval: Duration = .seconds(2)
    /// 순간적인 끊김에 해상도가 왔다 갔다 하지 않도록, 연속으로 이만큼 비어 있어야 해제로 본다.
    private let disconnectThreshold = 2
    private var missedPolls = 0

    private enum Keys {
        static let enabled = "enabled"
        static let target = "targetResolution"
        static let original = "originalResolution"
    }

    /// 접속 전 해상도. 앱이 재시작돼도 복원할 수 있게 저장해 둔다.
    private var originalID: String? {
        get { defaults.string(forKey: Keys.original) }
        set { defaults.set(newValue, forKey: Keys.original) }
    }

    init() {
        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        targetID = defaults.string(forKey: Keys.target) ?? ""
        launchAtLogin = SMAppService.mainApp.status == .enabled
        refreshDisplay()
        Task { await pollLoop() }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            let found = await Task.detached { VNCMonitor.activeClients() }.value
            handle(found)
            refreshDisplay()
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func handle(_ found: [String]) {
        if !found.isEmpty {
            missedPolls = 0
            let wasConnected = isConnected
            clients = found
            if !wasConnected { onConnect() }
        } else if isConnected {
            missedPolls += 1
            if missedPolls >= disconnectThreshold {
                clients = []
                onDisconnect()
            }
        }
    }

    private func onConnect() {
        guard enabled, !targetID.isEmpty else { return }
        if originalID == nil { originalID = DisplayManager.currentOption()?.id }
        let ok = DisplayManager.apply(id: targetID)
        lastMessage = ok ? "접속 감지 → 해상도 변경" : "해상도 변경 실패"
    }

    private func onDisconnect() {
        restoreOriginal(reason: "접속 해제 → 원래 해상도 복원")
    }

    func restoreOriginal(reason: String = "원래 해상도 복원") {
        guard let original = originalID else { return }
        let ok = DisplayManager.apply(id: original)
        lastMessage = ok ? reason : "복원 실패 (원래 해상도를 찾지 못함)"
        originalID = nil
        refreshDisplay()
    }

    func applyTargetNow() {
        guard !targetID.isEmpty else { return }
        if originalID == nil { originalID = DisplayManager.currentOption()?.id }
        lastMessage = DisplayManager.apply(id: targetID) ? "해상도 적용됨" : "해상도 변경 실패"
        refreshDisplay()
    }

    var hasOriginal: Bool { originalID != nil }

    private func refreshDisplay() {
        let newOptions = DisplayManager.availableOptions()
        if newOptions != options { options = newOptions }
        let id = DisplayManager.currentOption()?.id
        if id != currentID { currentID = id }
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastMessage = "로그인 항목 설정 실패: \(error.localizedDescription)"
        }
    }
}
