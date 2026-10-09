import VNCAutoResolutionCore

/// 테스트용 입력 소스. `select`는 기록하고, `failuresBeforeSuccess`번은 반영하지 않는다(TIS 불안정 흉내).
final class FakeInputSource: InputSourcing {
    static let abc = InputState(id: "com.apple.keylayout.ABC", isKorean: false)
    static let dubeolsik = InputState(id: "com.apple.inputmethod.Korean.2SetKorean", isKorean: true)
    static let gureum = InputState(id: "org.youknowone.inputmethod.Gureum.han2", isKorean: true)
    static let us = InputState(id: "com.apple.keylayout.US", isKorean: false)

    var current: InputState? = FakeInputSource.abc
    var available: [InputState] = [FakeInputSource.us, FakeInputSource.abc, FakeInputSource.dubeolsik]
    var selected: [String] = []
    var failuresBeforeSuccess = 0

    func select(id: String) -> Bool {
        selected.append(id)
        if failuresBeforeSuccess > 0 { failuresBeforeSuccess -= 1; return true }
        if let match = available.first(where: { $0.id == id }) { current = match }
        return true
    }
}

final class FakeViewerApps: ViewerAppDetecting {
    var runningBundleIDs: [String] = ["com.apple.finder"]
}
