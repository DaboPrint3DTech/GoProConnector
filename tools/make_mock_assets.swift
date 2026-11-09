// Generates test images and a short video for the mock GoPro server.
// Usage: swift tools/make_mock_assets.swift <output-folder>
import AppKit
import AVFoundation

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/mock_assets")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func makeImage(w: Int, h: Int, hue: CGFloat, label: String) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c1 = NSColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).cgColor
    let c2 = NSColor(hue: hue + 0.15, saturation: 0.8, brightness: 0.4, alpha: 1).cgColor
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [c1, c2] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: w, y: h), options: [])
    let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = ns
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: CGFloat(h) / 6),
                                                .foregroundColor: NSColor.white]
    NSString(string: label).draw(at: CGPoint(x: CGFloat(w) * 0.08, y: CGFloat(h) * 0.4), withAttributes: attrs)
    return ctx.makeImage()!
}

func writeJPEG(_ img: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: out.appendingPathComponent(name))
}

let palette: [CGFloat] = [0.0, 0.08, 0.15, 0.3, 0.45, 0.55, 0.62, 0.75, 0.85, 0.93]
for (i, hue) in palette.enumerated() {
    writeJPEG(makeImage(w: 320, h: 180, hue: hue, label: "GoPro \(i)"), "thumb\(i).jpg")
}
writeJPEG(makeImage(w: 2000, h: 1500, hue: 0.55, label: "FOTO"), "photo.jpg")

// 4-second video
let videoURL = out.appendingPathComponent("video.mp4")
try? FileManager.default.removeItem(at: videoURL)
let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 640,
    kCVPixelBufferHeightKey as String: 360,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for f in 0..<120 {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
    let buf = pb!
    CVPixelBufferLockBaseAddress(buf, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: 640, height: 360, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    ctx.draw(makeImage(w: 640, h: 360, hue: CGFloat(f) / 120, label: "Frame \(f)"), in: CGRect(x: 0, y: 0, width: 640, height: 360))
    CVPixelBufferUnlockBaseAddress(buf, [])
    adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
print("Assets created in \(out.path)")
