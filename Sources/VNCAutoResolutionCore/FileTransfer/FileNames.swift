import Foundation

/// 받은 파일 이름 정리. 상대가 보낸 이름을 그대로 경로로 쓰지 않는다.
public enum FileNames {
    static let fallback = "받은 파일"

    /// 경로 구분자(`/`, `:`)와 제어 문자를 없애고, 숨김 파일이 되지 않도록 선행 점을 없앤다.
    /// 남는 게 없으면 기본 이름을 쓴다. 너무 길면 확장자를 살려 자른다.
    public static func sanitize(_ name: String) -> String {
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter {
            $0 != "/" && $0 != ":" && !CharacterSet.controlCharacters.contains($0)
        }))
        // 공백과 점이 섞여 있어도("`. .x`") 숨김 파일이 되지 않도록 함께 없앤다.
        while let first = cleaned.first, first == "." || first.isWhitespace { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return fallback }
        // 파일 시스템 이름 상한(255바이트)보다 넉넉히 짧게 자른다. 번호를 붙일 자리도 남긴다.
        let maxBytes = 200
        guard cleaned.utf8.count > maxBytes else { return cleaned }
        let (base, ext) = split(cleaned)
        let keepsExtension = !ext.isEmpty && ext.utf8.count <= 20
        let suffix = keepsExtension ? "." + ext : ""
        var trimmed = keepsExtension ? base : cleaned
        while trimmed.utf8.count + suffix.utf8.count > maxBytes { trimmed.removeLast() }
        return trimmed + suffix
    }

    /// 이름이 겹칠 때 시도할 이름: `a.txt`, `a 2.txt`, `a 3.txt`, … (Finder와 같은 방식)
    public static func candidates(for name: String) -> some Sequence<String> {
        let (base, ext) = split(name)
        let suffix = ext.isEmpty ? "" : "." + ext
        return (1...).lazy.map { $0 == 1 ? name : "\(base) \($0)\(suffix)" }
    }

    /// 마지막 점 기준으로 이름과 확장자를 나눈다. 점으로 시작하는 이름은 확장자가 없다고 본다.
    private static func split(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }
}
