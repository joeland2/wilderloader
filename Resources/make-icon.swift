// Ritar appikonen (nr 3, Kabeln). Kör: swift Resources/make-icon.swift && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
import AppKit
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    c.scaleBy(x: s, y: -s); c.translateBy(x: 0, y: -1024)
    func color(_ r: Int, _ g: Int, _ b: Int) -> CGColor { CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    let bg = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.addPath(bg); c.setFillColor(color(15, 15, 15)); c.fillPath()
    c.addPath(bg); c.setStrokeColor(color(51, 51, 51)); c.setLineWidth(6); c.strokePath()
    c.move(to: CGPoint(x: 322, y: 322))
    c.addCurve(to: CGPoint(x: 702, y: 702), control1: CGPoint(x: 322, y: 620), control2: CGPoint(x: 702, y: 404))
    c.setStrokeColor(color(255, 255, 255)); c.setLineWidth(54); c.setLineCap(.round); c.strokePath()
    c.setFillColor(color(251, 191, 36)); c.fillEllipse(in: CGRect(x: 236, y: 236, width: 172, height: 172))
    c.setFillColor(color(34, 197, 94)); c.fillEllipse(in: CGRect(x: 616, y: 616, width: 172, height: 172))
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}
let dir = URL(fileURLWithPath: "/tmp/AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for (n, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: dir.appendingPathComponent("icon_\(n).png"))
}
