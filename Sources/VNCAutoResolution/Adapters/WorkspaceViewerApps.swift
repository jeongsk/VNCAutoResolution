import AppKit
import VNCAutoResolutionCore

/// 뷰어 앱 감지 포트의 실제 구현: NSWorkspace. 앱 실행/종료는 `onChange`로 알린다 (메인 큐).
final class WorkspaceViewerApps: ViewerAppDetecting {
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.onChange?()
            })
        }
    }

    deinit {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    var runningBundleIDs: [String] {
        NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    }
}
