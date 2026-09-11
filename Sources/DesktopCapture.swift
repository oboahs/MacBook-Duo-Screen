import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import Foundation

final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames = FrameStore()

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.oboahs.MacBookDuoScreen.capture", qos: .userInteractive)
    private var ownApplication: SCRunningApplication?
    private var starting = false
    private var generation = 0
    private var hasFrame = false

    var onFailure: ((String) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onUnavailable: (() -> Void)?

    var isRunning: Bool { stream != nil || starting }

    @MainActor
    private func availableContent() async throws -> SCShareableContent {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        ownApplication = content.applications.first(where: { $0.processID == getpid() })
        return content
    }

    @MainActor
    func verifyAccess() async throws {
        let content = try await availableContent()
        guard !content.displays.isEmpty else {
            throw CaptureError.message("没有找到可捕获的显示器。")
        }
        guard ownApplication != nil else {
            throw CaptureError.message("无法从屏幕捕获中排除本程序，请重新启动后再试。")
        }
    }

    @MainActor
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        guard !isRunning else { return }

        generation += 1
        let token = generation
        starting = true
        defer { if token == generation { starting = false } }

        let content = try await availableContent()
        guard token == generation else { return }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.message("找不到内置显示器的 ScreenCaptureKit 对象。")
        }
        guard let ownApplication else {
            throw CaptureError.message("无法安全排除本程序自身画面。")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [ownApplication], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = max(640, width)
        config.height = max(400, height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(max(15, min(fps, 60))))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = true

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = newStream
        hasFrame = false

        do {
            try await newStream.startCapture()
            if token != generation {
                try? await newStream.stopCapture()
            }
        } catch {
            if token == generation {
                stream = nil
                frames.clear()
            }
            throw error
        }
    }

    @MainActor
    func stop() {
        generation += 1
        starting = false
        let oldStream = stream
        stream = nil
        frames.clear()
        hasFrame = false
        if let oldStream {
            Task { try? await oldStream.stopCapture() }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }

        if status == .complete, let imageBuffer = sampleBuffer.imageBuffer {
            frames.put(imageBuffer)
            if !hasFrame {
                hasFrame = true
                DispatchQueue.main.async { [weak self] in self?.onFirstFrame?() }
            }
        } else if status == .blank || status == .suspended || status == .stopped {
            frames.clear()
            hasFrame = false
            DispatchQueue.main.async { [weak self] in self?.onUnavailable?() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.frames.clear()
            self.hasFrame = false
            self.onFailure?(error.localizedDescription)
        }
    }
}

enum CaptureError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
