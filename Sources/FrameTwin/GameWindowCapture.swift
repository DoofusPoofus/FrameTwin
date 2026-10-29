/*
 game window capture
 uses screencapturekit to grab just the game window (not the whole screen)
 screencapturekit only sends a frame when the window actualy changed. frames that are still drawing or idle get skipped
 the pixel buffer goes straight to onNewFrame on the capture queue and whoever gets it has to be quick
*/

import CoreMedia
import CoreVideo
import ScreenCaptureKit

final class GameWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onNewFrame: ((CVPixelBuffer) -> Void)?
    var onCaptureStopped: ((Error?) -> Void)?

    private var captureStream: SCStream?
    private let captureQueue = DispatchQueue(label: "frametwin.capture", qos: .userInteractive)

    func start(window: SCWindow, pixelWidth: Int, pixelHeight: Int) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                              configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream.startCapture()
        captureStream = stream
    }

    func stop() async {
        guard let stream = captureStream else { return }
        captureStream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isFinishedFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onNewFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onCaptureStopped?(error)
    }

    private func isFinishedFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsList = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsList.first,
              let statusNumber = attachments[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusNumber) else { return false }
        return status == .complete
    }
}
