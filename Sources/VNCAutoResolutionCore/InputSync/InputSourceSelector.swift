/// 받은 입력 상태를 이 Mac의 선택 가능한 입력 소스 중 무엇으로 적용할지 고르는 순수 로직.
/// (HangulSync의 `InputSourceManager.apply` 대체 규칙을 옮김 — THIRD_PARTY_NOTICES.md 참고)
public enum InputSourceSelector {
    public static let abcID = "com.apple.keylayout.ABC"

    /// 1) 정확히 같은 ID  2) 한국어면 첫 한국어 입력기  3) 영문이면 ABC, 없으면 첫 비한국어 입력기.
    public static func select(id: String, isKorean: Bool, from available: [InputState]) -> InputState? {
        if let exact = available.first(where: { $0.id == id }) { return exact }
        if isKorean { return available.first { $0.isKorean } }
        return available.first { $0.id == abcID } ?? available.first { !$0.isKorean }
    }
}

/// 원격 데스크탑 뷰어 앱 판정. 번들 ID 접두사로 비교한다.
/// (HangulSync의 `viewerBundlePrefixes`를 옮김)
public enum ViewerApps {
    public static let bundlePrefixes = [
        "com.apple.ScreenSharing",   // macOS 화면 공유
        "com.edovia.screens",        // Screens
        "com.p5sys.jump",            // Jump Desktop
        "com.realvnc.vncviewer",     // VNC Viewer
        "com.microsoft.rdc",         // Windows App (MS Remote Desktop)
        "com.teamviewer.TeamViewer", // TeamViewer
        "com.philandro.anydesk",     // AnyDesk
        "com.carriez.rustdesk",      // RustDesk
        "tv.parsec.www",             // Parsec
        "com.splashtop",             // Splashtop
    ]

    public static func isViewer(bundleID: String) -> Bool {
        bundlePrefixes.contains { bundleID.hasPrefix($0) }
    }
}
