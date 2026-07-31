import Cocoa
import CoreGraphics
import UniformTypeIdentifiers

// 生成 1024x1024 蓝色渐变圆角方块 + 白色水滴图标
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)


image.lockFocus()

let ctx = NSGraphicsContext.current!.cgContext
ctx.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))

// 蓝色渐变背景（圆角）
let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let path = NSBezierPath(roundedRect: rect, xRadius: 228, yRadius: 228)
path.addClip()

let colors = [NSColor(red: 0.20, green: 0.60, blue: 1.00, alpha: 1.0).cgColor,
              NSColor(red: 0.08, green: 0.40, blue: 0.90, alpha: 1.0).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors,
                          locations: [0.0, 1.0])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024),
                       end: CGPoint(x: 1024, y: 0), options: [])

// 重置裁剪，绘制水滴
NSGraphicsContext.current?.cgContext.saveGState()
let dropRect = CGRect(x: 312, y: 232, width: 400, height: 560)
let dropPath = makeWaterDropPath(in: dropRect)
NSColor.white.setFill()
dropPath.fill()

// 水滴上的高光
let highlight = NSBezierPath(ovalIn: CGRect(x: 392, y: 520, width: 90, height: 150))
NSColor(white: 1.0, alpha: 0.55).setFill()
highlight.fill()

image.unlockFocus()

// 保存为 PNG
let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("Saved icon to \(outPath)")

/// 绘制经典水滴形状：上尖下圆
func makeWaterDropPath(in rect: CGRect) -> NSBezierPath {
    let path = NSBezierPath()
    let w = rect.width
    let cx = rect.midX
    let topY = rect.maxY
    let bottomY = rect.minY
    let r = w / 2.0

    // 顶部尖点
    path.move(to: NSPoint(x: cx, y: topY))
    // 右侧曲线到底部右
    path.curve(to: NSPoint(x: cx + r, y: bottomY + r * 0.55),
               controlPoint1: NSPoint(x: cx + r * 0.92, y: topY - r * 0.85),
               controlPoint2: NSPoint(x: cx + r, y: bottomY + r * 1.55))
    // 底部圆弧到左
    path.curve(to: NSPoint(x: cx - r, y: bottomY + r * 0.55),
               controlPoint1: NSPoint(x: cx + r, y: bottomY - r * 0.25),
               controlPoint2: NSPoint(x: cx - r, y: bottomY - r * 0.25))
    // 左侧曲线回顶
    path.curve(to: NSPoint(x: cx, y: topY),
               controlPoint1: NSPoint(x: cx - r, y: bottomY + r * 1.55),
               controlPoint2: NSPoint(x: cx - r * 0.92, y: topY - r * 0.85))
    path.close()
    return path
}
