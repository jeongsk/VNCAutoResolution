/// 피어 연결의 고정 값들.
public enum PeerDefaults {
    /// 리스너 고정 포트.
    public static let port: UInt16 = 52718
    /// Bonjour 서비스 타입. Resources/Info.plist 의 `NSBonjourServices` 와 반드시 같아야 한다.
    public static let serviceType = "_vncautores._tcp"
}
