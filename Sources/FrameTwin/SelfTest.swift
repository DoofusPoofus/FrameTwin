/*
 self test (run with --selftest)
 makes fake frames on the cpu so we can check the interpolator without a game running
 test 1 a red square moves 40px on a still background. the middle frame should have it halfway at 20px
 test 2 the whole background pans 24px like a camera turn. the middle frame should match the pattern shifted 12px
        and it has to beat a dumb 50/50 blend or something is broken
 pngs of evrything get saved so u can eyeball them
*/

import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

enum SelfTest {
    static let frameWidth = 640
    static let frameHeight = 360

    static func run(outputFolder: URL) -> Int32 {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else {
            print("no metal device")
            return 1
        }
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let interpolator: FrameInterpolator
        do {
            interpolator = try FrameInterpolator(device: device)
        } catch {
            print("shader setup failed: \(error)")
            return 1
        }

        var everythingPassed = true

        let squareStart = makePixels { x, y in squareScene(x: x, y: y, squareLeft: 200) }
        let squareEnd = makePixels { x, y in squareScene(x: x, y: y, squareLeft: 240) }
        let squareMiddle = interpolate(squareStart, squareEnd, interpolator, device, commandQueue)
        save(squareStart, to: outputFolder.appendingPathComponent("square_a.png"))
        save(squareEnd, to: outputFolder.appendingPathComponent("square_b.png"))
        save(squareMiddle, to: outputFolder.appendingPathComponent("square_middle.png"))

        let (redPixelCount, redCenterX) = findRedSquare(in: squareMiddle)
        let expectedCenterX = 200.0 + 20.0 + 30.0
        let squareLandedRight = abs(redCenterX - expectedCenterX) <= 3.0 && redPixelCount > 3000
        print(String(format: "square test   red center x %.1f (want %.1f)  red pixels %d (want ~3600)  %@",
                     redCenterX, expectedCenterX, redPixelCount, squareLandedRight ? "PASS" : "FAIL"))
        everythingPassed = everythingPassed && squareLandedRight

        interpolator.forgetPreviousFrame()
        let panStart = makePixels { x, y in texturedBackground(x: Double(x), y: Double(y)) }
        let panEnd = makePixels { x, y in texturedBackground(x: Double(x) - 24, y: Double(y)) }
        let panTruth = makePixels { x, y in texturedBackground(x: Double(x) - 12, y: Double(y)) }
        let panMiddle = interpolate(panStart, panEnd, interpolator, device, commandQueue)
        let dumbBlend = zip(panStart, panEnd).map { UInt8((Int($0) + Int($1)) / 2) }
        save(panMiddle, to: outputFolder.appendingPathComponent("pan_middle.png"))
        save(dumbBlend, to: outputFolder.appendingPathComponent("pan_dumb_blend.png"))

        let ourError = averageError(panMiddle, panTruth, ignoringBorder: 16)
        let blendError = averageError(dumbBlend, panTruth, ignoringBorder: 16)
        let panLooksRight = ourError < blendError * 0.5
        print(String(format: "pan test      avg error ours %.2f vs dumb blend %.2f  %@",
                     ourError, blendError, panLooksRight ? "PASS" : "FAIL"))
        everythingPassed = everythingPassed && panLooksRight

        print("pngs saved in \(outputFolder.path)")
        return everythingPassed ? 0 : 1
    }

    private static func squareScene(x: Int, y: Int, squareLeft: Int) -> (Double, Double, Double) {
        let insideSquare = x >= squareLeft && x < squareLeft + 60 && y >= 150 && y < 210
        if insideSquare { return (0.95, 0.1, 0.1) }
        let checker = ((x / 16) + (y / 16)) % 2 == 0 ? 0.35 : 0.5
        return (checker, checker, checker)
    }

    private static func texturedBackground(x: Double, y: Double) -> (Double, Double, Double) {
        let waves = 0.5 + 0.2 * sin(x * 0.13) * cos(y * 0.09) + 0.15 * sin((x + y) * 0.051)
        let stripes = (Int(floor(x / 23)) + Int(floor(y / 31))) % 2 == 0 ? 0.08 : -0.08
        let brightness = min(max(waves + stripes, 0), 1)
        return (brightness, brightness * 0.9, brightness * 0.75)
    }

    private static func makePixels(_ colorAt: (Int, Int) -> (Double, Double, Double)) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: frameWidth * frameHeight * 4)
        for y in 0..<frameHeight {
            for x in 0..<frameWidth {
                let (red, green, blue) = colorAt(x, y)
                let index = (y * frameWidth + x) * 4
                pixels[index] = UInt8(blue * 255)
                pixels[index + 1] = UInt8(green * 255)
                pixels[index + 2] = UInt8(red * 255)
            }
        }
        return pixels
    }

    private static func interpolate(_ startPixels: [UInt8], _ endPixels: [UInt8],
                                    _ interpolator: FrameInterpolator,
                                    _ device: MTLDevice, _ commandQueue: MTLCommandQueue) -> [UInt8] {
        let startTexture = makeSharedTexture(device, pixels: startPixels)
        let endTexture = makeSharedTexture(device, pixels: endPixels)
        let middleTexture = makeSharedTexture(device, pixels: nil)

        for (newFrame, previousFrame) in [(startTexture, nil), (endTexture, startTexture)] as [(MTLTexture, MTLTexture?)] {
            let commandBuffer = commandQueue.makeCommandBuffer()!
            interpolator.encodeMiddleFrame(newFrame: newFrame, previousFrame: previousFrame,
                                           middleFrame: middleTexture, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        var middlePixels = [UInt8](repeating: 0, count: frameWidth * frameHeight * 4)
        middleTexture.getBytes(&middlePixels, bytesPerRow: frameWidth * 4,
                               from: MTLRegionMake2D(0, 0, frameWidth, frameHeight), mipmapLevel: 0)
        return middlePixels
    }

    private static func makeSharedTexture(_ device: MTLDevice, pixels: [UInt8]?) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: frameWidth, height: frameHeight, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        let texture = device.makeTexture(descriptor: descriptor)!
        if let pixels {
            texture.replace(region: MTLRegionMake2D(0, 0, frameWidth, frameHeight), mipmapLevel: 0,
                            withBytes: pixels, bytesPerRow: frameWidth * 4)
        }
        return texture
    }

    private static func findRedSquare(in pixels: [UInt8]) -> (count: Int, centerX: Double) {
        var redCount = 0
        var xTotal = 0.0
        for y in 0..<frameHeight {
            for x in 0..<frameWidth {
                let index = (y * frameWidth + x) * 4
                let blue = pixels[index], green = pixels[index + 1], red = pixels[index + 2]
                if red > 180 && green < 90 && blue < 90 {
                    redCount += 1
                    xTotal += Double(x)
                }
            }
        }
        return (redCount, redCount > 0 ? xTotal / Double(redCount) + 0.5 : 0)
    }

    private static func averageError(_ first: [UInt8], _ second: [UInt8], ignoringBorder border: Int) -> Double {
        var totalDifference = 0.0
        var comparedValues = 0
        for y in border..<(frameHeight - border) {
            for x in border..<(frameWidth - border) {
                let index = (y * frameWidth + x) * 4
                for channel in 0..<3 {
                    totalDifference += abs(Double(first[index + channel]) - Double(second[index + channel]))
                    comparedValues += 1
                }
            }
        }
        return totalDifference / Double(comparedValues)
    }

    private static func save(_ pixels: [UInt8], to fileURL: URL) {
        var rgbaPixels = pixels
        for index in stride(from: 0, to: rgbaPixels.count, by: 4) {
            rgbaPixels.swapAt(index, index + 2)
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(rgbaPixels) as CFData),
              let image = CGImage(width: frameWidth, height: frameHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: frameWidth * 4, space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
