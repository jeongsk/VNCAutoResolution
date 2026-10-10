import AppKit
import CoreGraphics
import ObjectiveC
import VNCAutoResolutionCore

/// 가상 디스플레이 포트의 실제 구현: CoreGraphics 비공개 클래스(`CGVirtualDisplay` 등)를 ObjC 런타임으로만 쓴다.
///
/// - 링크 시점에는 이 클래스들을 참조하지 않는다. `NSClassFromString`으로 찾고, 필요한 셀렉터가 모두 있는지
///   `instancesRespond(to:)`로 확인한다. 하나라도 없으면 `isAvailable == false`가 되고 앱의 다른 기능은 그대로 동작한다.
/// - 속성은 KVC(`setValue(_:forKey:)`), 초기화·`applySettings:`는 `class_getMethodImplementation`/`method(for:)`로 얻은
///   함수 포인터를 `unsafeBitCast`해서 부른다. (비공개 헤더에 의존하지 않는다)
/// - 가상 디스플레이 객체는 `display`에 강한 참조로 보관한다. `remove()`에서 참조를 놓으면 시스템이 제거한다.
///   프로세스가 강제 종료돼도 시스템이 정리한다.
/// - 어떤 화면의 미러로도 만들지 않는다. (미러 설정 API를 호출하지 않는다. WindowServer가 죽는다는 보고가 있다)
///
/// 클래스·헤더 선언은 DeskPad(MIT)를 참고했다. THIRD_PARTY_NOTICES.md 참조.
/// 메인 스레드에서만 부른다.
final class RuntimeVirtualDisplay: VirtualDisplayControlling {
    /// 화면 공유 고성능 모드가 만드는 가상 디스플레이의 이름 조각.
    static let highPerformanceNameFragment = "Screen Sharing Virtual Display"
    /// 처음 만들 때 설명자에 넣는 최대 픽셀. 모드가 이보다 크면 모드 크기에 맞춘다.
    private static let defaultMaxPixels = (width: 3840, height: 2400)
    private static let refreshRate = 60.0
    /// 이 앱이 만드는 가상 디스플레이의 제조사·제품 번호. 남은 화면을 가려낼 때도 쓴다.
    private static let vendorID: UInt32 = 0x3A5
    private static let productID: UInt32 = 0x5A1

    private let descriptorClass: NSObject.Type?
    private let displayClass: NSObject.Type?
    private let settingsClass: NSObject.Type?
    private let modeClass: NSObject.Type?

    /// 강한 참조. 이 참조가 사라지면 가상 디스플레이도 사라진다.
    private var display: NSObject?
    private var descriptor: NSObject?
    private var maxPixels = (width: 0, height: 0)

    init() {
        descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type
        displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type
        settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type
        modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type
    }

    // MARK: 포트

    /// 클래스와 쓸 셀렉터가 모두 있을 때만 true.
    var isAvailable: Bool {
        func responds(_ cls: NSObject.Type?, _ names: [String]) -> Bool {
            guard let cls else { return false }
            return names.allSatisfy { cls.instancesRespond(to: NSSelectorFromString($0)) }
        }
        return responds(descriptorClass, [
            "setName:", "setMaxPixelsWide:", "setMaxPixelsHigh:", "setSizeInMillimeters:",
            "setProductID:", "setVendorID:", "setSerialNum:", "setDispatchQueue:",
        ])
            && responds(displayClass, ["initWithDescriptor:", "applySettings:", "displayID"])
            && responds(settingsClass, ["setHiDPI:", "setModes:"])
            && responds(modeClass, ["initWithWidth:height:refreshRate:"])
            && modeClass?.responds(to: NSSelectorFromString("alloc")) == true
            && displayClass?.responds(to: NSSelectorFromString("alloc")) == true
    }

    var hasHighPerformanceDisplay: Bool {
        NSScreen.screens.contains { $0.localizedName.contains(Self.highPerformanceNameFragment) }
    }

    var isActive: Bool { display != nil }

    /// 포인트 크기. `CGDisplayCopyDisplayMode`는 가상 디스플레이에서 nil이라 `CGDisplayBounds`로 읽는다.
    var activeSize: (width: Int, height: Int)? {
        guard let id = displayID else { return nil }
        let bounds = CGDisplayBounds(id)
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        return (Int(bounds.width.rounded()), Int(bounds.height.rounded()))
    }

    /// 온라인 화면 중 이 앱의 제조사·제품 번호를 가졌지만 지금 들고 있는 것이 아닌 화면 수.
    var leftoverCount: Int {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return 0 }
        let mine = displayID
        return ids.prefix(Int(count)).filter {
            $0 != mine && CGDisplayVendorNumber($0) == Self.vendorID && CGDisplayModelNumber($0) == Self.productID
        }.count
    }

    func create(mode: VirtualDisplayMode) -> Bool {
        guard display == nil, isAvailable, mode.width > 0, mode.height > 0,
              let descriptorClass, let displayClass else { return false }

        let descriptor = descriptorClass.init()
        let maxWide = max(Self.defaultMaxPixels.width, mode.width)
        let maxHigh = max(Self.defaultMaxPixels.height, mode.height)
        descriptor.setValue("VNCAutoResolution Virtual", forKey: "name")
        descriptor.setValue(NSNumber(value: UInt32(maxWide)), forKey: "maxPixelsWide")
        descriptor.setValue(NSNumber(value: UInt32(maxHigh)), forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: CGSize(width: 300, height: 195)), forKey: "sizeInMillimeters")
        descriptor.setValue(NSNumber(value: Self.productID), forKey: "productID")
        descriptor.setValue(NSNumber(value: Self.vendorID), forKey: "vendorID")
        // macOS는 vendor·product·serial마다 마지막 모드를 기억한다. 1배율과 HiDPI가 서로의 기억을 덮지 않도록 나눈다.
        descriptor.setValue(NSNumber(value: UInt32(mode.hiDPI ? 2 : 1)), forKey: "serialNum")
        _ = descriptor.perform(NSSelectorFromString("setDispatchQueue:"), with: DispatchQueue.main)

        // display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor]  (+1 소유를 그대로 넘겨받는다)
        guard let initIMP = Self.implementation(displayClass, "initWithDescriptor:"),
              let allocated = (displayClass as AnyObject).perform(NSSelectorFromString("alloc")) else { return false }
        typealias InitFn = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeRawPointer) -> UnsafeMutableRawPointer?
        let initFn = unsafeBitCast(initIMP, to: InitFn.self)
        let descriptorPtr = UnsafeRawPointer(Unmanaged.passUnretained(descriptor).toOpaque())
        guard let result = initFn(allocated.toOpaque(), NSSelectorFromString("initWithDescriptor:"), descriptorPtr) else {
            return false
        }
        let created = Unmanaged<NSObject>.fromOpaque(result).takeRetainedValue()

        self.display = created
        self.descriptor = descriptor
        self.maxPixels = (maxWide, maxHigh)
        guard displayID != nil, applyMode(mode) else {
            release()
            return false
        }
        return true
    }

    func update(mode: VirtualDisplayMode) -> Bool {
        guard display != nil, mode.width > 0, mode.height > 0,
              mode.width <= maxPixels.width, mode.height <= maxPixels.height else { return false }
        return applyMode(mode)
    }

    func remove() {
        release()
    }

    // MARK: 내부

    /// 참조를 놓는다. 마지막 강한 참조가 사라지면 시스템이 가상 디스플레이를 제거한다.
    private func release() {
        display = nil
        descriptor = nil
        maxPixels = (0, 0)
    }

    private var displayID: CGDirectDisplayID? {
        guard let display, display.responds(to: NSSelectorFromString("displayID")),
              let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else { return nil }
        return id
    }

    /// `CGVirtualDisplaySettings`를 만들어 `applySettings:`로 적용한다.
    private func applyMode(_ mode: VirtualDisplayMode) -> Bool {
        guard let display, let settingsClass, let modeObject = makeMode(mode) else { return false }
        let settings = settingsClass.init()
        settings.setValue(NSNumber(value: UInt32(mode.hiDPI ? 1 : 0)), forKey: "hiDPI")
        settings.setValue([modeObject], forKey: "modes")

        let selector = NSSelectorFromString("applySettings:")
        guard let imp = Self.implementation(type(of: display), "applySettings:") else { return false }
        typealias ApplyFn = @convention(c) (UnsafeRawPointer, Selector, UnsafeRawPointer) -> ObjCBool
        let apply = unsafeBitCast(imp, to: ApplyFn.self)
        let displayPtr = UnsafeRawPointer(Unmanaged.passUnretained(display).toOpaque())
        let settingsPtr = UnsafeRawPointer(Unmanaged.passUnretained(settings).toOpaque())
        return apply(displayPtr, selector, settingsPtr).boolValue
    }

    /// `[[CGVirtualDisplayMode alloc] initWithWidth:height:refreshRate:]`
    /// `hiDPI = 1`이면 이 크기를 포인트로 보고 픽셀은 2배로 만든다. 그래서 HiDPI면 포인트 크기를 넘긴다.
    /// (픽셀 크기를 넘기면 4배 픽셀을 요구해 최대 픽셀을 넘고, macOS가 거부한 뒤 1배율로 만든다)
    private func makeMode(_ mode: VirtualDisplayMode) -> NSObject? {
        let size = mode.pointSize
        guard let modeClass,
              let imp = Self.implementation(modeClass, "initWithWidth:height:refreshRate:"),
              let allocated = (modeClass as AnyObject).perform(NSSelectorFromString("alloc")) else { return nil }
        typealias InitFn = @convention(c) (UnsafeMutableRawPointer, Selector, UInt, UInt, Double) -> UnsafeMutableRawPointer?
        let initFn = unsafeBitCast(imp, to: InitFn.self)
        guard let result = initFn(
            allocated.toOpaque(), NSSelectorFromString("initWithWidth:height:refreshRate:"),
            UInt(size.width), UInt(size.height), Self.refreshRate) else { return nil }
        return Unmanaged<NSObject>.fromOpaque(result).takeRetainedValue()
    }

    private static func implementation(_ cls: AnyClass, _ selector: String) -> IMP? {
        let sel = NSSelectorFromString(selector)
        guard class_respondsToSelector(cls, sel) else { return nil }
        return class_getMethodImplementation(cls, sel)
    }
}
