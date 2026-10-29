/*
 frame gen session
 glues the 3 parts together for one game window
 capture -> copy into our own textures -> interpolator makes the middle frame -> overlay shows middle then real
 the captured frame gets copied rite away so screencapturekit gets its buffer back and we still have the old frame for next time
 theres 4 slots of textures that get reused in a circle so the overlay is never reading one we are writing
 if the gpu is still bussy with 2 frames the new one just gets skiped so lag doesnt pile up
 create start and stop it on the main thread. onStoppedByItself gets called if the game window closes or capture dies
*/

import AppKit
import CoreVideo
import Metal
import ScreenCaptureKit

final class FrameGenSession: @unchecked Sendable {
    enum SetupError: Error {
        case noCommandQueue
        case noTextureCache
    }

    var onStoppedByItself: ((String) -> Void)?

    private struct FrameSlot {
        let realFrame: MTLTexture
        let middleFrame: MTLTexture
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let interpolator: FrameInterpolator
    private let capture = GameWindowCapture()
    private let overlay: OverlayPresenter
    private let gameWindow: SCWindow
    private let captureWidth: Int
    private let captureHeight: Int

    private var isRunning = false
    private var captureStartup: Task<Void, Never>?

    private let framesOnGPU = DispatchSemaphore(value: 2)
    private let slotCount = 4
    private var frameSlots: [FrameSlot] = []
    private var nextSlotIndex = 0
    private var previousRealFrame: MTLTexture?

    private let frameCountLock = NSLock()
    private var realFramesSinceLastLook = 0

    init(gameWindow: SCWindow, device: MTLDevice) throws {
        guard let commandQueue = device.makeCommandQueue() else { throw SetupError.noCommandQueue }
        var createdTextureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &createdTextureCache)
        guard let createdTextureCache else { throw SetupError.noTextureCache }

        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = createdTextureCache
        self.interpolator = try FrameInterpolator(device: device)
        self.overlay = OverlayPresenter(device: device, gameWindowID: gameWindow.windowID)
        self.gameWindow = gameWindow

        let screenScale = Self.backingScale(forWindowFrame: gameWindow.frame)
        captureWidth = max(Int(gameWindow.frame.width * screenScale), 1)
        captureHeight = max(Int(gameWindow.frame.height * screenScale), 1)

        capture.onNewFrame = { [weak self] pixelBuffer in
            self?.handleNewFrame(pixelBuffer)
        }
        capture.onCaptureStopped = { [weak self] error in
            DispatchQueue.main.async {
                self?.stopByItself(because: error?.localizedDescription ?? "capture stopped")
            }
        }
        overlay.onGameWindowGone = { [weak self] in
            self?.stopByItself(because: "game window closed")
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        captureStartup = Task { [weak self, capture, gameWindow, captureWidth, captureHeight] in
            do {
                try await capture.start(window: gameWindow, pixelWidth: captureWidth, pixelHeight: captureHeight)
            } catch {
                DispatchQueue.main.async {
                    self?.stopByItself(because: "couldn't start capture (\(error.localizedDescription))")
                }
            }
        }
        overlay.show()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        overlay.hide()

        // this bum ahh race took way too long to notice
        Task { [capture, captureStartup] in
            await captureStartup?.value
            await capture.stop()
        }
    }

    func takeFrameCounts() -> (realFrames: Int, shownFrames: Int) {
        frameCountLock.lock()
        let realFrames = realFramesSinceLastLook
        realFramesSinceLastLook = 0
        frameCountLock.unlock()
        return (realFrames, overlay.takeShownFrameCount())
    }

    private func stopByItself(because reason: String) {
        guard isRunning else { return }
        stop()
        onStoppedByItself?(reason)
    }

    private func handleNewFrame(_ pixelBuffer: CVPixelBuffer) {
        guard framesOnGPU.wait(timeout: .now()) == .success else { return }

        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        var wrappedFrame: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                                                  .bgra8Unorm, frameWidth, frameHeight, 0, &wrappedFrame)
        guard let wrappedFrame,
              let capturedTexture = CVMetalTextureGetTexture(wrappedFrame),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            framesOnGPU.signal()
            return
        }

        if frameSlots.first?.realFrame.width != frameWidth || frameSlots.first?.realFrame.height != frameHeight {
            frameSlots = (0..<slotCount).map { _ in
                FrameSlot(realFrame: makeFrameTexture(width: frameWidth, height: frameHeight),
                          middleFrame: makeFrameTexture(width: frameWidth, height: frameHeight))
            }
            previousRealFrame = nil
        }
        let slot = frameSlots[nextSlotIndex]
        nextSlotIndex = (nextSlotIndex + 1) % slotCount

        blitEncoder.copy(from: capturedTexture, to: slot.realFrame)
        blitEncoder.endEncoding()

        let madeMiddleFrame = interpolator.encodeMiddleFrame(newFrame: slot.realFrame,
                                                             previousFrame: previousRealFrame,
                                                             middleFrame: slot.middleFrame,
                                                             commandBuffer: commandBuffer)
        previousRealFrame = slot.realFrame

        let framesToShow = madeMiddleFrame ? [slot.middleFrame, slot.realFrame] : [slot.realFrame]
        commandBuffer.addCompletedHandler { [overlay, framesOnGPU] _ in
            withExtendedLifetime(wrappedFrame) {}
            overlay.showNext(frames: framesToShow)
            framesOnGPU.signal()
        }
        commandBuffer.commit()

        frameCountLock.lock()
        realFramesSinceLastLook += 1
        frameCountLock.unlock()
    }

    private func makeFrameTexture(width: Int, height: Int) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)!
    }

    private static func backingScale(forWindowFrame windowFrame: CGRect) -> CGFloat {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let windowCenter = CGPoint(x: windowFrame.midX, y: primaryScreenHeight - windowFrame.midY)
        let screenWithWindow = NSScreen.screens.first { $0.frame.contains(windowCenter) } ?? NSScreen.main
        return screenWithWindow?.backingScaleFactor ?? 2
    }
}
