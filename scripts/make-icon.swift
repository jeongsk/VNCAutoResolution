import AppKit
// 1024×1024 앱 아이콘: 남색 그라디언트 바탕 + 모니터 + 화면에 맞춰 늘어나는 모서리 화살표 + 한/A 배지
let N: CGFloat = 1024
let img = NSImage(size: NSSize(width: N, height: N))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
// macOS 아이콘 격자: 824 본체, 반경 185
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(bodyPath); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(bodyPath); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    NSColor(srgbRed: 0.17, green: 0.42, blue: 0.98, alpha: 1).cgColor,
    NSColor(srgbRed: 0.08, green: 0.16, blue: 0.48, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
ctx.restoreGState()

// 모니터
let white = NSColor.white.cgColor
let screen = CGRect(x: 222, y: 360, width: 580, height: 380)
ctx.setStrokeColor(white); ctx.setLineWidth(34); ctx.setLineJoin(.round)
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: 44, cornerHeight: 44, transform: nil)); ctx.strokePath()
// 받침
ctx.setFillColor(white)
ctx.fill(CGRect(x: 482, y: 268, width: 60, height: 92))
ctx.addPath(CGPath(roundedRect: CGRect(x: 372, y: 238, width: 280, height: 40), cornerWidth: 20, cornerHeight: 20, transform: nil)); ctx.fillPath()

// 화면 안: 작은 창이 화면에 맞춰 늘어나는 모서리 화살표
func arrow(_ from: CGPoint, _ to: CGPoint) {
    let dx = to.x - from.x, dy = to.y - from.y, len = sqrt(dx*dx + dy*dy)
    let ux = dx/len, uy = dy/len, h: CGFloat = 70
    // 선은 화살촉 밑동에서 멈춘다 (촉 끝 밖으로 선이 튀어나오지 않게)
    ctx.setStrokeColor(white); ctx.setLineWidth(28); ctx.setLineCap(.round)
    ctx.move(to: from); ctx.addLine(to: CGPoint(x: to.x - ux*h*0.9, y: to.y - uy*h*0.9)); ctx.strokePath()
    let p1 = CGPoint(x: to.x - ux*h - uy*h*0.65, y: to.y - uy*h + ux*h*0.65)
    let p2 = CGPoint(x: to.x - ux*h + uy*h*0.65, y: to.y - uy*h - ux*h*0.65)
    ctx.setFillColor(white); ctx.setLineJoin(.round); ctx.setLineWidth(10); ctx.move(to: to); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath(); ctx.drawPath(using: .fillStroke)
}
let c = CGPoint(x: screen.midX, y: screen.midY)
arrow(CGPoint(x: c.x - 50, y: c.y + 32), CGPoint(x: screen.minX + 70, y: screen.maxY - 62))
arrow(CGPoint(x: c.x + 50, y: c.y - 32), CGPoint(x: screen.maxX - 70, y: screen.minY + 62))

// 한/A 배지 (오른쪽 아래)
let badge = CGRect(x: 618, y: 150, width: 250, height: 170)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 46, cornerHeight: 46, transform: nil))
ctx.setFillColor(NSColor(srgbRed: 1, green: 0.62, blue: 0.16, alpha: 1).cgColor); ctx.fillPath()
ctx.restoreGState()
let style = NSMutableParagraphStyle(); style.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 104, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: style]
("한A" as NSString).draw(in: CGRect(x: badge.minX, y: badge.minY + 18, width: badge.width, height: 130), withAttributes: attrs)
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
