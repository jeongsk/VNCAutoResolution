import VNCAutoResolutionCore

final class FakeSettingsStore: SettingsStoring {
    var autoChangeEnabled = true
    var targetResolutionID = ""
    var originalResolutionID: String?
}
