import SwiftUI
import VNCAutoResolutionCore

/// 메뉴의 클립보드 공유 섹션: 켜기/끄기 토글, 상대 버전 안내, 마지막 공유 상태.
struct ClipboardMenuSection: View {
    @ObservedObject var state: AppModel

    private var needsUpdate: Bool { state.clipboardPeerSupport == .needsUpdate }

    var body: some View {
        Toggle("클립보드 공유", isOn: $state.clipboardSyncEnabled)
            .disabled(needsUpdate)
        if needsUpdate {
            Text("상대 Mac 앱 업데이트 필요")
        } else if state.clipboardSyncEnabled, let status = Self.statusLabel(state.clipboardStatus) {
            Text("클립보드: \(status)")
        }
    }

    static func statusLabel(_ status: ClipboardSyncController.Status) -> String? {
        switch status {
        case .none: return nil
        case .sent: return "보냄"
        case .received: return "받음"
        case .skipped(let reason):
            switch reason {
            case .noSession: return "건너뜀 (원격 세션 아님)"
            case .tooLarge: return "건너뜀 (256KB 초과)"
            case .concealed: return "건너뜀 (비밀번호·임시 항목)"
            case .peerNeedsUpdate: return "건너뜀 (상대 Mac 앱 업데이트 필요)"
            }
        }
    }
}
