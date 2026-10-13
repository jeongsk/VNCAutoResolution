import SwiftUI
import VNCAutoResolutionCore

/// 메뉴의 파일 전송 섹션: 받은 제안(수락·거절), 파일 보내기, 받기 토글, 마지막 전송 상태.
struct FileTransferMenuSection: View {
    @ObservedObject var state: AppModel

    var body: some View {
        if let offer = state.incomingFileOffer {
            Text(FileOfferText.describe(offer))
            Button("수락") { state.acceptFileOffer(offer.transferID) }
            Button("거절") { state.declineFileOffer(offer.transferID) }
        }
        sendButton
        Toggle("파일 받기", isOn: $state.fileReceiveEnabled)
        if let status = Self.statusLabel(state.fileTransferStatus) {
            Text(status)
        }
    }

    @ViewBuilder
    private var sendButton: some View {
        let peers = state.peers
        if peers.count > 1 {
            Menu("파일 보내기") {
                ForEach(peers) { peer in
                    Button(state.canSendFile(to: peer) ? peer.name : "\(peer.name) (앱 업데이트 필요)") {
                        state.chooseFileAndSend(to: peer.deviceID)
                    }
                    .disabled(!state.canSendFile(to: peer))
                }
            }
        } else if let peer = peers.first {
            Button("파일 보내기…") { state.chooseFileAndSend(to: peer.deviceID) }
                .disabled(!state.canSendFile(to: peer))
            if !state.canSendFile(to: peer) {
                Text("상대 Mac 앱 업데이트 필요")
            }
        } else {
            Button("파일 보내기…") {}
                .disabled(true)
        }
    }

    static func statusLabel(_ status: FileTransferController.Status) -> String? {
        switch status {
        case .none: return nil
        case .waitingForAnswer(let file, let peer): return "\(file): \(peer)의 응답 기다리는 중"
        case .sending(let file): return "\(file): 보내는 중"
        case .sent(let file): return "\(file): 보냄"
        case .declined(let file, let reason): return "\(file): \(declineLabel(reason))"
        case .sendFailed(let file, let reason): return "\(file): \(sendFailureLabel(reason))"
        case .receiving(let file): return "\(file): 받는 중"
        case .received(let file): return "\(file): 다운로드 폴더에 저장함"
        case .receiveFailed(let file, let reason): return "\(file): \(receiveFailureLabel(reason))"
        }
    }

    private static func declineLabel(_ reason: FileDeclineReason) -> String {
        switch reason {
        case .declined: return "상대가 거절함"
        case .timeout: return "상대가 응답하지 않아 취소됨"
        case .disabled: return "상대 Mac의 파일 받기가 꺼져 있음"
        case .tooLarge: return "상대 Mac이 받을 수 있는 크기를 넘음"
        case .busy: return "상대 Mac이 다른 파일을 받는 중"
        }
    }

    private static func sendFailureLabel(_ reason: FileTransferController.SendFailure) -> String {
        switch reason {
        case .peerNeedsUpdate: return "상대 Mac 앱 업데이트 필요"
        case .tooLarge: return "\(FileOfferText.size(FileTransferController.maxFileBytes))를 넘어 보낼 수 없음"
        case .readFailed: return "파일을 읽을 수 없음"
        case .noPeer: return "상대 Mac이 연결돼 있지 않음"
        case .noAnswer: return "상대 Mac의 응답 없음"
        case .connectionFailed: return "연결 실패"
        }
    }

    private static func receiveFailureLabel(_ reason: FileTransferController.ReceiveFailure) -> String {
        switch reason {
        case .timedOut: return "응답하지 않아 거절함"
        case .checksumMismatch: return "검증 실패로 저장하지 않음"
        case .saveFailed: return "저장 실패"
        case .interrupted: return "받는 중 연결이 끊김"
        }
    }
}

/// "<피어 이름>에서 <파일 이름> (<크기>)"
enum FileOfferText {
    static func describe(_ offer: IncomingFileOffer) -> String {
        "\(offer.peerName)에서 \(offer.fileName) (\(size(offer.size)))"
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
