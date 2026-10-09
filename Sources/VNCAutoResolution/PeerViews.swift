import SwiftUI
import VNCAutoResolutionCore

/// 메뉴의 피어 섹션: 연결된 피어의 이름과 연결 경로, 설정 창 열기.
struct PeerMenuSection: View {
    @ObservedObject var state: AppModel

    var body: some View {
        if state.peers.isEmpty {
            Text("연결된 피어 없음")
        } else {
            ForEach(state.peers) { peer in
                Text("\(peer.name) · \(Self.routeLabel(peer.route))")
            }
        }
        if !state.peerStatus.isEmpty {
            Text(state.peerStatus)
        }
        Button("피어 설정…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            // macOS 14+ 는 showSettingsWindow:, 13 은 showPreferencesWindow:
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }

    static func routeLabel(_ route: PeerRoute) -> String {
        switch route {
        case .bonjour: return "자동 탐색"
        case .manual: return "직접 입력"
        }
    }
}

/// 설정 창: 페어링 암호와 직접 연결할 피어 주소.
struct PairingSettingsView: View {
    @ObservedObject var state: AppModel
    @State private var passphrase = ""
    @State private var address = ""
    @State private var loaded = false

    var body: some View {
        Form {
            SecureField("페어링 암호", text: $passphrase)
            TextField("직접 연결할 피어 주소", text: $address, prompt: Text("예: 100.64.0.2 또는 mac.example:\(PeerDefaults.port)"))
            Text("두 Mac에 같은 암호를 입력해야 연결됩니다. 같은 공유기 안에서는 주소 없이 자동으로 찾고, 외부 네트워크(Tailscale/VPN)는 주소를 입력하세요. 암호는 Keychain에 저장됩니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("저장") { state.savePairing(passphrase: passphrase, manualAddress: address) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            passphrase = state.pairingPassphrase
            address = state.manualPeerAddress
        }
    }
}
