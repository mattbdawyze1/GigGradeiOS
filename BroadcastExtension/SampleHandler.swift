import ReplayKit
import Vision
import CoreMedia
import UserNotifications

/// The screen reader. iOS hands this extension the live screen while a broadcast is running
/// (started from the button in the app or Control Center → Screen Recording → GigGrade).
/// About once a second it runs Apple's on-device text recognition and grades any offer it sees.
/// Frames are never saved or uploaded.
///
/// Note: iOS caps broadcast extensions at ~50 MB of memory, so we OCR one frame at a time.
class SampleHandler: RPBroadcastSampleHandler {

    private var lastScan = Date.distantPast
    private let scanInterval: TimeInterval = 1.0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        OfferAlert.registerCategories()
        OfferPipeline.shared.reset()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        guard now.timeIntervalSince(lastScan) >= scanInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = now

        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }

        autoreleasepool {
            let request = VNRecognizeTextRequest()
            // .accurate reads small offer text best. If the broadcast keeps stopping by itself
            // on an older iPhone (memory limit), change this to .fast.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.012
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
                let text = (request.results ?? [])
                    .sorted { $0.boundingBox.minY > $1.boundingBox.minY } // top of screen first
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                OfferPipeline.shared.handle(text: text)
            } catch {
                // Skip this frame.
            }
        }
    }

    override func broadcastFinished() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [OfferAlert.requestId])
    }
}
