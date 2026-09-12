// 生成 DSH Web 应用图标：白底圆角方形 + 居中 DeepSeek Harness logo。
// 用法: swift make-icon.swift <源图> <输出1024png>
import Foundation
import CoreGraphics
import ImageIO

let args = CommandLine.arguments
guard args.count >= 3 else { FileHandle.standardError.write("usage: make-icon.swift <src> <out>\n".data(using: .utf8)!); exit(2) }
let srcURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let source = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write("无法读取源图\n".data(using: .utf8)!); exit(1)
}

let S = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

let inset: CGFloat = 56
let rect = CGRect(x: inset, y: inset, width: CGFloat(S) - inset * 2, height: CGFloat(S) - inset * 2)
let radius = rect.width * 0.2237   // macOS Big Sur 风格的圆角比例

// 1) 圆角白底 + 柔和投影
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()

// 2) 清掉阴影后把 logo 等比居中贴入
ctx.setShadow(offset: .zero, blur: 0, color: nil)
let logoW = rect.width * 0.90
let scale = logoW / CGFloat(logo.width)
let logoH = CGFloat(logo.height) * scale
ctx.interpolationQuality = .high
ctx.draw(logo, in: CGRect(x: rect.midX - logoW / 2, y: rect.midY - logoH / 2,
                          width: logoW, height: logoH))

guard let image = ctx.makeImage() else { exit(1) }
guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
print("已生成 \(args[2]) (\(image.width)x\(image.height))")
