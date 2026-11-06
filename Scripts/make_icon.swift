import AppKit
import Foundation

// 用 AppKit 直接画图标，避免引入任何第三方依赖。
// 用法：swift Scripts/make_icon.swift <输出的 .iconset 目录>

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("用法：swift Scripts/make_icon.swift <iconset 目录>\n".data(using: .utf8)!)
    exit(1)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let entries: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func makeIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        return nil
    }

    let size = CGFloat(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    // 圆角底板 + 深色渐变
    let inset = size * 0.06
    let background = NSBezierPath(
        roundedRect: NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2),
        xRadius: size * 0.22,
        yRadius: size * 0.22
    )
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.24, alpha: 1),
        ending: NSColor(calibratedRed: 0.07, green: 0.09, blue: 0.14, alpha: 1)
    )
    gradient?.draw(in: background, angle: -90)

    // 主标题
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.30, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    ("FCP" as NSString).draw(
        in: NSRect(x: 0, y: size * 0.34, width: size, height: size * 0.42),
        withAttributes: attributes
    )

    // 橙色强调条
    let bar = NSBezierPath(
        roundedRect: NSRect(x: size * 0.35, y: size * 0.24, width: size * 0.30, height: size * 0.055),
        xRadius: size * 0.03,
        yRadius: size * 0.03
    )
    NSColor(calibratedRed: 0.96, green: 0.58, blue: 0.18, alpha: 1).setFill()
    bar.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for entry in entries {
    guard let data = makeIcon(pixels: entry.pixels) else {
        FileHandle.standardError.write("图标生成失败：\(entry.name)\n".data(using: .utf8)!)
        exit(2)
    }
    try data.write(to: outputDirectory.appendingPathComponent(entry.name))
}
