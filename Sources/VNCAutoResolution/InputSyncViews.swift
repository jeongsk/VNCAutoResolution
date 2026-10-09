import SwiftUI
import VNCAutoResolutionCore

/// 메뉴의 입력 동기화 섹션: 현재 입력(한/A), 동기화 상태, 일시정지/재개, "원격 세션 중에만" 토글.
struct InputSyncMenuSection: View {
    @ObservedObject var state: AppModel

    private var inputLabel: String {
        guard let input = state.currentInput else { return "알 수 없음" }
        return input.isKorean ? "한" : "A"
    }

    private var statusLabel: String {
        switch state.inputSyncStatus {
        case .active: return "활성"
        case .waiting: return "대기"
        case .paused: return "일시정지"
        }
    }

    var body: some View {
        Text("현재 입력: \(inputLabel) · 동기화: \(statusLabel)")
        if !state.inputSyncMessage.isEmpty {
            Text(state.inputSyncMessage)
        }
        Button(state.inputSyncEnabled ? "입력 동기화 일시정지" : "입력 동기화 재개") {
            state.inputSyncEnabled.toggle()
        }
        Toggle("원격 세션 중에만", isOn: $state.inputSyncOnlyDuringRemote)
    }
}
