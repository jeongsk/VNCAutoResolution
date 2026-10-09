/// 뷰어 앱 감지 포트: 지금 실행 중인 앱의 번들 ID 목록. (원격 데스크탑 뷰어 판정은 코어가 한다.)
/// 앱 실행/종료 변화는 앱이 `InputSyncController.viewerAppsChanged()`로 알린다.
public protocol ViewerAppDetecting: AnyObject {
    var runningBundleIDs: [String] { get }
}
