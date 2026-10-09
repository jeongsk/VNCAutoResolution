import Carbon

// 입력 소스 전환 도우미: `VNCInputSourceHelper <입력 소스 ID>`
// 메뉴바 앱(AppKit 프로세스)이 직접 TISSelectInputSource를 부르면, 앞에 있는 앱의
// 입력 컨텍스트가 약 1초 뒤 이전 입력 소스로 되돌린다(2026-10-09 맥북 실측, #12).
// AppKit 없는 별도 프로세스에서 전환하면 유지되므로 전환만 이 도우미가 맡는다.
// 종료 코드: 0 성공, 1 사용법 오류, 2 입력 소스 없음, 3 전환 실패
let args = CommandLine.arguments
guard args.count == 2 else { exit(1) }

func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

let sources = (TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource]) ?? []
guard let source = sources.first(where: { stringProperty($0, kTISPropertyInputSourceID) == args[1] }) else { exit(2) }
exit(TISSelectInputSource(source) == noErr ? 0 : 3)
