/*
 overlay presenter
 puts a borderless window rite on top of the game window and draws our frames in it
 - it ignores the mouse so clicks go thru to the game and it never takes keyboard focus
 - its marked not opaque on purpose. if it was opaque macos could think the game is hidden and slow it down
 - its excluded from screen capture so we never capture our own output
 - evry 0.5s it checks where the game window is and follows it
 a display link fires on evry screen refresh and shows the next waiting frame
 new frames replace old ones that werent shown yet so lag doesnt pile up
*/

import AppKit
import Metal
import QuartzCore

final class OverlayPresenter: NSObject {
    var onGameWindowGone: (() -> Void)?

    private let commandQueue: MTLCommandQueue
    private let gameWindowID: CGWindowID
    private let overlayWindow: NSWindow
    private let metalLayer = CAMetalLayer()
    private var displayLink: CADisplayLink?
    private var followTimer: Timer?

    private let waitingFramesLock = NSLock()
    private var waitingFrames: [MTLTexture] = []
    private var shownFrames = 0

    init(device: MTLDevice, gameWindowID: CGWindowID) {
        self.commandQueue = device.makeCommandQueue()!
        self.gameWindowID = gameWindowID
        overlayWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        super.init()

        overlayWindow.isOpaque = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.hasShadow = false
        overlayWindow.ignoresMouseEvents = true
        overlayWindow.level = .statusBar
        overlayWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        overlayWindow.sharingType = .none
        overlayWindow.isReleasedWhenClosed = false

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = false
        metalLayer.displaySyncEnabled = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        let hostView = NSView()
        hostView.layer = metalLayer
        hostView.wantsLayer = true
        overlayWindow.contentView = hostView
    }

    func show() {
        followGameWindow()
        overlayWindow.orderFrontRegardless()

        let screen = overlayWindow.screen ?? NSScreen.main
        displayLink = screen?.displayLink(target: self, selector: #selector(screenRefreshed(_:)))
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 240, preferred: 240)
        displayLink?.add(to: .main, forMode: .common)

        followTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.followGameWindow()
        }
    }

    func hide() {
        displayLink?.invalidate()
        displayLink = nil
        followTimer?.invalidate()
        followTimer = nil
        overlayWindow.orderOut(nil)
    }

    func showNext(frames: [MTLTexture]) {
        waitingFramesLock.lock()
        waitingFrames = frames
        waitingFramesLock.unlock()
    }

    func takeShownFrameCount() -> Int {
        waitingFramesLock.lock()
        defer {
            shownFrames = 0
            waitingFramesLock.unlock()
        }
        return shownFrames
    }

    @objc private func screenRefreshed(_ link: CADisplayLink) {
        waitingFramesLock.lock()
        let nextFrame = waitingFrames.isEmpty ? nil : waitingFrames.removeFirst()
        waitingFramesLock.unlock()
        guard let nextFrame else { return }
        draw(nextFrame)
    }

    private func draw(_ frame: MTLTexture) {
        let frameSize = CGSize(width: frame.width, height: frame.height)
        if metalLayer.drawableSize != frameSize {
            metalLayer.drawableSize = frameSize
        }
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

        let copyWidth = min(frame.width, drawable.texture.width)
        let copyHeight = min(frame.height, drawable.texture.height)
        blitEncoder.copy(from: frame, sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSize(width: copyWidth, height: copyHeight, depth: 1),
                         to: drawable.texture, destinationSlice: 0, destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blitEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        waitingFramesLock.lock()
        shownFrames += 1
        waitingFramesLock.unlock()
    }

    private func followGameWindow() {
        guard let windowInfoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], gameWindowID) as? [[String: Any]],
              let windowInfo = windowInfoList.first,
              let boundsDictionary = windowInfo[kCGWindowBounds as String] as? NSDictionary,
              let gameBounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
            onGameWindowGone?()
            return
        }

        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let overlayFrame = NSRect(x: gameBounds.minX,
                                  y: primaryScreenHeight - gameBounds.maxY,
                                  width: gameBounds.width,
                                  height: gameBounds.height)
        if overlayWindow.frame != overlayFrame {
            overlayWindow.setFrame(overlayFrame, display: false)
        }
        metalLayer.contentsScale = overlayWindow.backingScaleFactor
    }
}
