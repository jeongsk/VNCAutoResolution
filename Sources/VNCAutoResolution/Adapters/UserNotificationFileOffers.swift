import Foundation
import os
import UserNotifications
import VNCAutoResolutionCore

/// 파일 전송 제안 알림 포트의 실제 구현: 사용자 알림(수락·거절 버튼).
/// 앱 번들 밖(`swift run`)에서는 알림 센터를 쓸 수 없으므로 아무것도 하지 않는다(메뉴로만 응답).
/// 상태(`onAnswer`, `authorizationRequested`)는 메인 스레드에서만 만진다. 알림 응답도 메인 큐로 옮겨 처리한다.
final class UserNotificationFileOffers: NSObject, FileOfferNotifying, UNUserNotificationCenterDelegate,
                                        @unchecked Sendable {
    /// 알림에서 수락(true)·거절(false)을 눌렀을 때 불린다. (메인 큐)
    var onAnswer: ((_ transferID: String, _ accepted: Bool) -> Void)?

    private static let category = "FILE_OFFER"
    private static let acceptAction = "ACCEPT"
    private static let declineAction = "DECLINE"

    private let center: UNUserNotificationCenter?
    private static let log = Logger(subsystem: "com.jeongsk.VNCAutoResolution", category: "filetransfer")

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNNotificationAction(identifier: Self.acceptAction, title: "수락", options: []),
                UNNotificationAction(identifier: Self.declineAction, title: "거절", options: [.destructive]),
            ],
            intentIdentifiers: [])])
    }

    /// 알림 권한을 묻는다(처음 한 번만 실제로 묻는다). 파일 받기를 켤 때와, 켜진 채로 앱이 시작될 때 부른다.
    /// 제안이 온 뒤에 물으면 권한이 정해지기 전이라 첫 알림이 나가지 않는다.
    func requestAuthorization() {
        center?.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { Self.log.error("알림 권한 요청 실패: \(error.localizedDescription, privacy: .public)") }
            else if !granted { Self.log.info("알림 권한 없음: 메뉴에서만 응답할 수 있다") }
        }
    }

    func showOffer(_ offer: IncomingFileOffer) {
        guard let center else { return }
        // 권한이 아직 정해지지 않았으면 물은 뒤에 보낸다.
        center.getNotificationSettings { [self] settings in
            guard settings.authorizationStatus == .notDetermined else { return post(offer) }
            self.center?.requestAuthorization(options: [.alert, .sound]) { [self] granted, _ in
                if granted { post(offer) }
            }
        }
    }

    private func post(_ offer: IncomingFileOffer) {
        let content = UNMutableNotificationContent()
        content.title = "파일 받기 요청"
        content.body = FileOfferText.describe(offer)
        content.categoryIdentifier = Self.category
        content.sound = .default
        center?.add(UNNotificationRequest(identifier: offer.transferID, content: content, trigger: nil)) { error in
            if let error { Self.log.error("알림 표시 실패: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func removeOffer(transferID: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [transferID])
        center?.removePendingNotificationRequests(withIdentifiers: [transferID])
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let transferID = response.notification.request.identifier
        let accepted: Bool?
        switch response.actionIdentifier {
        case Self.acceptAction: accepted = true
        case Self.declineAction: accepted = false
        default: accepted = nil   // 알림 본문을 누르면 메뉴에서 답하게 둔다.
        }
        DispatchQueue.main.async { [weak self] in
            if let accepted { self?.onAnswer?(transferID, accepted) }
        }
        completionHandler()
    }
}
