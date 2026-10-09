// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VNCAutoResolution",
    platforms: [.macOS(.v13)],
    targets: [
        // 순수 앱 코어: Foundation만 사용한다. OS API는 Ports/ 의 프로토콜로만 접근한다.
        .target(name: "VNCAutoResolutionCore"),
        // 메뉴바 앱: SwiftUI UI + 실제 OS 어댑터(포트 구현).
        .executableTarget(
            name: "VNCAutoResolution",
            dependencies: ["VNCAutoResolutionCore"]
        ),
        // 입력 소스 전환 도우미: AppKit 없는 별도 프로세스에서 전환해야 유지된다 (#12).
        .executableTarget(name: "VNCInputSourceHelper"),
        .testTarget(
            name: "VNCAutoResolutionCoreTests",
            dependencies: ["VNCAutoResolutionCore"]
        ),
    ]
)
