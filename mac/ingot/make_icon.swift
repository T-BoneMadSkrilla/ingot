// Ingot's app icon: icon.png's artwork cut to Apple's icon grid (an
// 824-point rounded square on a transparent 1024 canvas) with the standard
// drop shadow. swiftc it and run with the source and the PNG to write;
// build.sh makes the .icns of it.
import AppKit

let args = CommandLine.arguments
guard args.count > 2, let src = NSImage(contentsOfFile: args[1]),
      let art = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: make_icon <icon.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let plate = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185,
                   transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(colorSpace: cs, components: [0, 0, 0, 0.45])!)
ctx.addPath(plate)
ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, 1])!)
ctx.fillPath()
ctx.restoreGState()

ctx.addPath(plate)
ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(art, in: CGRect(x: 0, y: 0, width: size, height: size))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
