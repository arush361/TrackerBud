import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import ScreenCaptureKit
import IOKit.ps
import TrackerBudCore
import OSLog

public final class ScreenTracker: Tracker, @unchecked Sendable {
    public static let id = "screen"

    private let lock = NSLock()
    private var captureTimer: DispatchSourceTimer?
    private var lastHash: UInt64 = 0
    private let log = Logger(subsystem: "com.arushsharma.trackerbud", category: "ScreenTracker")
    private let baseInterval: TimeInterval = 30.0
    private let batteryInterval: TimeInterval = 90.0
    private let storageDir: URL

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return captureTimer != nil
    }

    public init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("TrackerBud/screenshots", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageDir = dir
    }

    public func start() throws {
        lock.lock()
        guard captureTimer == nil else { lock.unlock(); return }
        lock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let interval = currentInterval()
        timer.schedule(deadline: .now() + 3.0, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task.detached(priority: .background) {
                await self.captureOnce()
            }
        }
        timer.resume()
        lock.lock(); captureTimer = timer; lock.unlock()
        log.info("ScreenTracker started (interval \(interval, privacy: .public)s)")
    }

    public func stop() {
        lock.lock()
        captureTimer?.cancel()
        captureTimer = nil
        lock.unlock()
        log.info("ScreenTracker stopped")
    }

    public func currentPermissionStatus() -> PermissionStatus {
        return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
    }

    private func currentInterval() -> TimeInterval {
        onBattery() ? batteryInterval : baseInterval
    }

    private func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for s in sources {
            if let desc = IOPSGetPowerSourceDescription(info, s)?.takeUnretainedValue() as? [String: Any],
               let state = desc[kIOPSPowerSourceStateKey] as? String {
                if state == kIOPSBatteryPowerValue { return true }
            }
        }
        return false
    }

    private func captureOnce() async {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundle = frontApp?.bundleIdentifier
        let token = "screen:\(bundle ?? "unknown")"

        // Check privacy exclusion
        if let bid = bundle, isExcluded(bundleID: bid) {
            do {
                _ = try EventStore.shared.writeScreenshot(
                    ts: Date(),
                    frontmostBundle: bundle,
                    thumbPath: "",
                    fullresPath: nil,
                    perceptualHash: nil,
                    width: 0, height: 0,
                    skippedReason: "excluded-app",
                    ocrText: nil,
                    token: token
                )
                EventBus.shared.emit(EmittedEvent(
                    source: .screen, type: "screen.skip",
                    token: token,
                    appName: frontApp?.localizedName,
                    bundleID: bundle,
                    windowTitle: "skipped: excluded app"
                ))
            } catch {
                log.error("Skipped-screenshot write failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        guard let cgImage = await captureScreen() else {
            log.warning("Screen capture returned nil")
            return
        }

        // Perceptual hash for dedup
        let phash = perceptualHash(cgImage: cgImage)
        let same = abs(Int64(bitPattern: phash) - Int64(bitPattern: lastHash)) == 0
        if same {
            return
        }
        lastHash = phash

        // Save thumbnail JPEG
        let now = Date()
        let isoTs = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let thumbURL = storageDir.appendingPathComponent("thumb_\(isoTs).jpg")
        guard saveJPEG(cgImage: cgImage, to: thumbURL, maxDimension: 640, quality: 0.6) else {
            log.error("Failed to save thumbnail")
            return
        }

        // OCR
        let ocrText = await runOCR(cgImage: cgImage)

        do {
            _ = try EventStore.shared.writeScreenshot(
                ts: now,
                frontmostBundle: bundle,
                thumbPath: thumbURL.path,
                fullresPath: nil,
                perceptualHash: Int64(bitPattern: phash),
                width: cgImage.width,
                height: cgImage.height,
                skippedReason: nil,
                ocrText: ocrText,
                token: token
            )
            EventBus.shared.emit(EmittedEvent(
                source: .screen, type: "screen.capture",
                token: token,
                appName: frontApp?.localizedName,
                bundleID: bundle,
                windowTitle: ocrText.flatMap { String($0.prefix(60)) }
            ))
        } catch {
            log.error("Screenshot write failed: \(error.localizedDescription, privacy: .public)")
        }

        // Retention pass every so often (sample 1 in 10 captures).
        if Int.random(in: 0..<10) == 0 {
            runRetention()
        }
    }

    private func captureScreen() async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(Double(display.width) * 0.5)
            config.height = Int(Double(display.height) * 0.5)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 3
            config.scalesToFit = true
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            log.error("captureImage failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func runOCR(cgImage: CGImage) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { req, _ in
                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    cont.resume(returning: nil); return
                }
                let lines = observations.compactMap { obs in
                    obs.topCandidates(1).first?.string
                }
                cont.resume(returning: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            }
            request.recognitionLevel = onBattery() ? .fast : .accurate
            request.usesLanguageCorrection = !onBattery()

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                log.error("OCR failed: \(error.localizedDescription, privacy: .public)")
                cont.resume(returning: nil)
            }
        }
    }

    private func saveJPEG(cgImage: CGImage, to url: URL, maxDimension: Int, quality: Double) -> Bool {
        // Downscale if needed
        let width = cgImage.width
        let height = cgImage.height
        let scale = min(1.0, Double(maxDimension) / Double(max(width, height)))
        let newW = Int(Double(width) * scale)
        let newH = Int(Double(height) * scale)

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let scaled = ctx.makeImage() else { return false }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return false }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, scaled, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    private func perceptualHash(cgImage: CGImage) -> UInt64 {
        // dHash 8x8: 64 bits comparing each pixel to its right neighbor.
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bytesPerRow = 9
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * 8)
        guard let ctx = CGContext(
            data: &pixels, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 9, height: 8))

        var bits: UInt64 = 0
        var bit = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let left = pixels[row * bytesPerRow + col]
                let right = pixels[row * bytesPerRow + col + 1]
                if left < right { bits |= (UInt64(1) << bit) }
                bit += 1
            }
        }
        return bits
    }

    private func runRetention() {
        // 5 GB hard cap. Walk the storage dir and evict oldest if needed.
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        var totalBytes: Int64 = 0
        var sizedEntries: [(URL, Date, Int64)] = []
        for url in urls {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            totalBytes += size
            sizedEntries.append((url, mtime, size))
        }
        let capBytes: Int64 = 5 * 1024 * 1024 * 1024
        if totalBytes <= capBytes { return }

        sizedEntries.sort { $0.1 < $1.1 } // oldest first
        var bytesOver = totalBytes - capBytes
        for entry in sizedEntries {
            if bytesOver <= 0 { break }
            try? fm.removeItem(at: entry.0)
            bytesOver -= entry.2
        }
        log.info("Retention pass evicted \(totalBytes - bytesOver, privacy: .public) bytes")
    }

    private func isExcluded(bundleID: String) -> Bool {
        guard let rules = try? EventStore.shared.privacyRules() else { return false }
        return rules.contains { rule in
            (rule.action == "skip-screenshot" || rule.action == "skip-all")
                && rule.bundleID == bundleID
        }
    }
}
