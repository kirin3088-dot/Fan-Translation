import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 背景：白色圆角方（macOS Big Sur+ 风格 ~22.5% 圆角）
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let cornerRadius: CGFloat = 225
let bg = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
NSColor.white.setFill()
bg.fill()

// 细灰色描边
NSColor(calibratedWhite: 0.0, alpha: 0.08).setStroke()
bg.lineWidth = 4
bg.stroke()

// 居中黑色 "Fan" 文字（粗体、占约 60% 宽度）
let para = NSMutableParagraphStyle()
para.alignment = .center
let font = NSFont.systemFont(ofSize: 360, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.black,
    .paragraphStyle: para
]
let text = "Fan"
let textSize = text.size(withAttributes: attrs)
let textRect = NSRect(
    x: (size - textSize.width) / 2,
    y: (size - textSize.height) / 2 - 20,
    width: textSize.width,
    height: textSize.height
)
NSString(string: text).draw(in: textRect, withAttributes: attrs)

image.unlockFocus()

if let tiff = image.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("图标已生成")
}
