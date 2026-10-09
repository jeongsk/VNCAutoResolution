import SwiftUI
import VNCAutoResolutionCore

@main
struct VNCAutoResolutionApp: App {
    @StateObject private var state = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: state)
        } label: {
            Image(systemName: state.isConnected ? "display.and.arrow.down" : "display")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppModel

    private var currentLabel: String {
        state.options.first { $0.id == state.currentID }?.label ?? state.currentID ?? "알 수 없음"
    }

    var body: some View {
        if state.isConnected {
            Text("VNC 접속 중: \(state.clients.joined(separator: ", "))")
        } else {
            Text("VNC 접속 없음")
        }
        Text("현재 해상도: \(currentLabel)")
        if !state.lastMessage.isEmpty {
            Text(state.lastMessage)
        }

        Divider()

        Toggle("접속 시 자동 변경", isOn: $state.enabled)
        Picker("접속 시 해상도", selection: $state.targetID) {
            Text("선택 안 함").tag("")
            ForEach(state.options) { option in
                Text(option.label).tag(option.id)
            }
        }
        Button("지금 적용해 보기") { state.applyTargetNow() }
            .disabled(state.targetID.isEmpty)
        Button("원래 해상도로 복원") { state.restoreOriginal() }
            .disabled(!state.hasOriginal)

        Divider()

        Toggle("로그인 시 실행", isOn: Binding(
            get: { state.launchAtLogin },
            set: { state.setLaunchAtLogin($0) }
        ))
        Button("종료") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
