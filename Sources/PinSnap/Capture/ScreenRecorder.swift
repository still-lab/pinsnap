import AVFoundation
import Foundation
import ScreenCaptureKit

/// v1.3 录屏服务骨架。REQ: R-05+
@MainActor
public final class ScreenRecorder: NSObject {
    public private(set) var isRecording = false
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?

    public func start(display: SCDisplay, outputURL: URL) async throws {
        guard !isRecording else { return }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        self.stream = stream
        // Full sample buffer → AVAssetWriter wiring in v1.3 implementation pass
        try await stream.startCapture()
        isRecording = true
        PinSnapLog.capture.info("recording started (skeleton)")
    }

    public func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        isRecording = false
    }
}
