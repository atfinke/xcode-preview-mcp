import AppKit
import ApplicationServices
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct JSONError: Codable {
    let error: String
}

struct FramePayload: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }
}

struct WindowPayload: Codable {
    let windowID: UInt32
    let title: String
    let frame: FramePayload
    let owningApplication: AppPayload?
}

struct AppPayload: Codable {
    let applicationName: String
    let bundleIdentifier: String
    let processID: Int32
}

struct PermissionsPayload: Codable {
    let screenRecording: Bool
    let accessibility: Bool
}

struct CapturePayload: Codable {
    let simulatorImagePath: String
    let simulatorImageWidth: Int
    let simulatorImageHeight: Int
    let simulatorImageOriginalWidth: Int
    let simulatorImageOriginalHeight: Int
    let simulatorImageScaleApplied: Double
    let maxLongEdgeApplied: Int
    let activeEditorFileName: String?
    let activeEditorFileSource: String?
    let simulatorFrame: FramePayload
    let simulatorFrameConfidence: Double
    let simulatorDetectionReason: String
    let capturedAt: String
    let window: WindowPayload
    let permissions: PermissionsPayload
}

struct AXDetectionCandidate {
    let frame: CGRect
    let score: Int
    let confidence: Double
    let reason: String
}

struct AXDetectionResult {
    let simulator: AXDetectionCandidate?
}

struct AXDetectionState {
    var bestSimulator: AXDetectionCandidate?
}

struct AXSignalSummary {
    var simulatorWordCount: Int = 0
    var hasIOSContentGroup: Bool = false

    mutating func merge(_ other: AXSignalSummary) {
        simulatorWordCount += other.simulatorWordCount
        hasIOSContentGroup = hasIOSContentGroup || other.hasIOSContentGroup
    }
}

struct ImageCropPayload {
    let path: String
    let width: Int
    let height: Int
    let originalWidth: Int
    let originalHeight: Int
    let scaleApplied: Double
}

enum HelperError: Error {
    case message(String)
}

@main
@MainActor
struct XcodePreviewHelper {
    private static let axFrameAttribute: CFString = "AXFrame" as CFString

    static func main() async {
        do {
            initializeAppKit()
            let data = try await run()
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                throw HelperError.message("Unable to encode JSON output")
            }
        } catch {
            let payload = JSONError(error: errorMessage(error))
            if let data = try? JSONEncoder().encode(payload),
               let text = String(data: data, encoding: .utf8)
            {
                FileHandle.standardError.write(Data(text.utf8))
                FileHandle.standardError.write(Data("\n".utf8))
            }
            exit(1)
        }
    }

    static func run() async throws -> Data {
        let commandLine = Array(CommandLine.arguments.dropFirst())
        guard let command = commandLine.first else {
            throw HelperError.message("Missing command. Use one of: permissions, list-windows, capture")
        }

        let options = try parseOptions(Array(commandLine.dropFirst()))

        switch command {
        case "permissions":
            let promptScreen = boolOption(options, key: "prompt-screen", defaultValue: false)
            let promptAccessibility = boolOption(options, key: "prompt-accessibility", defaultValue: false)
            return try encodeJSON(getPermissions(promptScreen: promptScreen, promptAccessibility: promptAccessibility))

        case "list-windows":
            let bundleID = stringOption(options, key: "bundle-id", defaultValue: "com.apple.dt.Xcode")
            let titleContains = options["title-contains"]
            let onScreenOnly = boolOption(options, key: "on-screen-only", defaultValue: true)
            let windows = try await listWindows(
                bundleID: bundleID,
                titleContains: titleContains,
                onScreenOnly: onScreenOnly
            )
            return try encodeJSON(windows.map(toWindowPayload))

        case "capture":
            let bundleID = stringOption(options, key: "bundle-id", defaultValue: "com.apple.dt.Xcode")
            let titleContains = options["title-contains"]
            let onScreenOnly = boolOption(options, key: "on-screen-only", defaultValue: true)
            let windowIndex = intOption(options, key: "window-index", defaultValue: 0)
            let outputPath = stringOption(options, key: "output-path", defaultValue: defaultCapturePath())
            let maxLongEdge = intOption(options, key: "max-long-edge", defaultValue: 1200)
            let promptScreen = boolOption(options, key: "prompt-screen", defaultValue: false)
            let promptAccessibility = boolOption(options, key: "prompt-accessibility", defaultValue: false)

            let payload = try await captureWindow(
                bundleID: bundleID,
                titleContains: titleContains,
                onScreenOnly: onScreenOnly,
                windowIndex: windowIndex,
                outputPath: outputPath,
                maxLongEdge: maxLongEdge,
                promptScreen: promptScreen,
                promptAccessibility: promptAccessibility
            )
            return try encodeJSON(payload)

        default:
            throw HelperError.message("Unknown command: \(command)")
        }
    }

    static func initializeAppKit() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func errorMessage(_ error: Error) -> String {
        if let helperError = error as? HelperError {
            switch helperError {
            case .message(let message):
                return message
            }
        }

        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }

        return String(describing: error)
    }

    static func parseOptions(_ args: [String]) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0

        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--") else {
                throw HelperError.message("Unexpected token: \(token)")
            }

            let key = String(token.dropFirst(2))
            let nextIndex = index + 1

            if nextIndex < args.count, !args[nextIndex].hasPrefix("--") {
                options[key] = args[nextIndex]
                index += 2
            } else {
                options[key] = "true"
                index += 1
            }
        }

        return options
    }

    static func stringOption(_ options: [String: String], key: String, defaultValue: String) -> String {
        options[key] ?? defaultValue
    }

    static func boolOption(_ options: [String: String], key: String, defaultValue: Bool) -> Bool {
        guard let value = options[key] else {
            return defaultValue
        }

        switch value.lowercased() {
        case "1", "true", "yes", "y":
            return true
        case "0", "false", "no", "n":
            return false
        default:
            return defaultValue
        }
    }

    static func intOption(_ options: [String: String], key: String, defaultValue: Int) -> Int {
        guard let raw = options[key], let value = Int(raw) else {
            return defaultValue
        }
        return value
    }

    static func defaultCapturePath() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "/tmp/xcode-simulator-captures/xcode-active-sim-\(timestamp).png"
    }

    static func getPermissions(promptScreen: Bool, promptAccessibility: Bool) -> PermissionsPayload {
        if promptScreen, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        let screenRecording = CGPreflightScreenCaptureAccess()
        let accessibility = isAccessibilityTrusted(prompt: promptAccessibility)

        return PermissionsPayload(
            screenRecording: screenRecording,
            accessibility: accessibility
        )
    }

    static func listWindows(bundleID: String, titleContains: String?, onScreenOnly: Bool) async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly)

        return content.windows.filter { window in
            guard let app = window.owningApplication else { return false }
            guard app.bundleIdentifier == bundleID else { return false }

            if let needle = titleContains, !needle.isEmpty {
                let title = window.title ?? ""
                return title.localizedCaseInsensitiveContains(needle)
            }

            return true
        }
    }

    static func toWindowPayload(window: SCWindow) -> WindowPayload {
        let appPayload: AppPayload?
        if let app = window.owningApplication {
            appPayload = AppPayload(
                applicationName: app.applicationName,
                bundleIdentifier: app.bundleIdentifier,
                processID: app.processID
            )
        } else {
            appPayload = nil
        }

        return WindowPayload(
            windowID: window.windowID,
            title: window.title ?? "",
            frame: FramePayload(window.frame),
            owningApplication: appPayload
        )
    }

    static func captureWindow(
        bundleID: String,
        titleContains: String?,
        onScreenOnly: Bool,
        windowIndex: Int,
        outputPath: String,
        maxLongEdge: Int,
        promptScreen: Bool,
        promptAccessibility: Bool
    ) async throws -> CapturePayload {
        let permissions = getPermissions(promptScreen: promptScreen, promptAccessibility: promptAccessibility)
        guard permissions.screenRecording else {
            throw HelperError.message("Screen recording permission not granted")
        }
        guard permissions.accessibility else {
            throw HelperError.message("Accessibility permission required for active simulator capture")
        }
        guard maxLongEdge >= 1 else {
            throw HelperError.message("max-long-edge must be >= 1")
        }
        guard isApplicationRunning(bundleID: bundleID) else {
            throw HelperError.message("Xcode is not running. Open Xcode with a project and active preview.")
        }

        let windows = try await listWindows(
            bundleID: bundleID,
            titleContains: titleContains,
            onScreenOnly: onScreenOnly
        )

        guard !windows.isEmpty else {
            throw HelperError.message("Xcode is running but no visible windows matched. Open a workspace window.")
        }
        guard windows.indices.contains(windowIndex) else {
            throw HelperError.message("No window found at index \(windowIndex). Found \(windows.count) matching windows.")
        }

        let window = windows[windowIndex]
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let pointPixelScale = max(1.0, Double(filter.pointPixelScale))
        let contentRect = filter.contentRect
        let configuration = SCStreamConfiguration()
        configuration.captureResolution = .best
        configuration.scalesToFit = false
        let requestedPixelWidth = clampPixelDimension(
            Int((contentRect.width * pointPixelScale).rounded(.toNearestOrAwayFromZero)),
            fallback: Int((window.frame.width * pointPixelScale).rounded(.toNearestOrAwayFromZero))
        )
        let requestedPixelHeight = clampPixelDimension(
            Int((contentRect.height * pointPixelScale).rounded(.toNearestOrAwayFromZero)),
            fallback: Int((window.frame.height * pointPixelScale).rounded(.toNearestOrAwayFromZero))
        )
        configuration.width = requestedPixelWidth
        configuration.height = requestedPixelHeight
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )

        guard let pid = window.owningApplication?.processID else {
            throw HelperError.message("Could not resolve owning application process for AX inspection")
        }

        let axResult = buildAXTree(
            processID: pid,
            expectedWindowTitle: window.title ?? "",
            windowIndex: windowIndex
        )

        if !axResult.warnings.isEmpty {
            throw HelperError.message("No active simulator preview detected in the selected Xcode window. Ensure SwiftUI Preview canvas is open with a live device.")
        }
        guard let simulatorCandidate = axResult.simulator else {
            throw HelperError.message("No active simulator preview detected in the selected Xcode window. Ensure SwiftUI Preview canvas is open with a live device.")
        }

        let simulatorCrop = try cropAndWrite(
            sourceImage: image,
            sourceContentRectPoints: contentRect,
            sourcePointPixelScale: pointPixelScale,
            targetScreenRectPoints: simulatorCandidate.frame,
            outputPath: outputPath,
            maxLongEdge: maxLongEdge
        )

        return CapturePayload(
            simulatorImagePath: simulatorCrop.path,
            simulatorImageWidth: simulatorCrop.width,
            simulatorImageHeight: simulatorCrop.height,
            simulatorImageOriginalWidth: simulatorCrop.originalWidth,
            simulatorImageOriginalHeight: simulatorCrop.originalHeight,
            simulatorImageScaleApplied: simulatorCrop.scaleApplied,
            maxLongEdgeApplied: maxLongEdge,
            activeEditorFileName: axResult.activeEditorFileName,
            activeEditorFileSource: axResult.activeEditorFileSource,
            simulatorFrame: FramePayload(simulatorCandidate.frame),
            simulatorFrameConfidence: simulatorCandidate.confidence,
            simulatorDetectionReason: simulatorCandidate.reason,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            window: toWindowPayload(window: window),
            permissions: permissions
        )
    }

    static func writePNG(image: CGImage, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw HelperError.message("Failed to create PNG destination")
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw HelperError.message("Failed to finalize PNG write")
        }
    }

    static func cropAndWrite(
        sourceImage: CGImage,
        sourceContentRectPoints: CGRect,
        sourcePointPixelScale: Double,
        targetScreenRectPoints: CGRect,
        outputPath: String,
        maxLongEdge: Int
    ) throws -> ImageCropPayload {
        guard maxLongEdge >= 1 else {
            throw HelperError.message("max-long-edge must be >= 1")
        }
        guard let cropRect = convertScreenRectToImagePixelRect(
            sourceContentRectPoints: sourceContentRectPoints,
            sourcePointPixelScale: sourcePointPixelScale,
            imageWidth: sourceImage.width,
            imageHeight: sourceImage.height,
            targetScreenRectPoints: targetScreenRectPoints
        ) else {
            throw HelperError.message("Calculated crop rect is outside captured image bounds")
        }

        guard let croppedImage = sourceImage.cropping(to: cropRect) else {
            throw HelperError.message("CGImage cropping failed")
        }
        let originalWidth = croppedImage.width
        let originalHeight = croppedImage.height
        let resized = try resizedImageIfNeeded(
            image: croppedImage,
            maxLongEdge: maxLongEdge
        )

        let outputURL = URL(fileURLWithPath: outputPath)
        try writePNG(image: resized.image, to: outputURL)
        return ImageCropPayload(
            path: outputURL.path,
            width: resized.image.width,
            height: resized.image.height,
            originalWidth: originalWidth,
            originalHeight: originalHeight,
            scaleApplied: resized.scaleApplied
        )
    }

    static func resizedImageIfNeeded(
        image: CGImage,
        maxLongEdge: Int
    ) throws -> (image: CGImage, scaleApplied: Double) {
        guard maxLongEdge >= 1 else {
            throw HelperError.message("max-long-edge must be >= 1")
        }

        let sourceWidth = image.width
        let sourceHeight = image.height
        let sourceLongEdge = max(sourceWidth, sourceHeight)
        guard sourceLongEdge > 0 else {
            throw HelperError.message("Cannot resize image with zero dimensions")
        }

        if sourceLongEdge <= maxLongEdge {
            return (image, 1.0)
        }

        let scale = Double(maxLongEdge) / Double(sourceLongEdge)
        let targetWidth = max(1, Int((Double(sourceWidth) * scale).rounded(.toNearestOrAwayFromZero)))
        let targetHeight = max(1, Int((Double(sourceHeight) * scale).rounded(.toNearestOrAwayFromZero)))

        guard let context = makeResizeContext(
            width: targetWidth,
            height: targetHeight,
            sourceImage: image
        ) else {
            throw HelperError.message("Failed to create resize context")
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: targetWidth,
                height: targetHeight
            )
        )
        guard let resized = context.makeImage() else {
            throw HelperError.message("Failed to render resized image")
        }
        return (resized, scale)
    }

    static func makeResizeContext(
        width: Int,
        height: Int,
        sourceImage: CGImage
    ) -> CGContext? {
        let sourceBits = max(8, sourceImage.bitsPerComponent)
        let sourceSpace = sourceImage.colorSpace
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        if let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: sourceBits,
            bytesPerRow: 0,
            space: sourceSpace,
            bitmapInfo: sourceImage.bitmapInfo.rawValue
        ) {
            return context
        }

        let fallbackSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let fallbackBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: fallbackSpace,
            bitmapInfo: fallbackBitmapInfo.rawValue
        )
    }

    static func convertScreenRectToImagePixelRect(
        sourceContentRectPoints: CGRect,
        sourcePointPixelScale: Double,
        imageWidth: Int,
        imageHeight: Int,
        targetScreenRectPoints: CGRect
    ) -> CGRect? {
        let scale = max(0.01, sourcePointPixelScale)
        let rawRect = CGRect(
            x: (targetScreenRectPoints.minX - sourceContentRectPoints.minX) * scale,
            y: (targetScreenRectPoints.minY - sourceContentRectPoints.minY) * scale,
            width: targetScreenRectPoints.width * scale,
            height: targetScreenRectPoints.height * scale
        ).standardized

        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(imageWidth),
            height: CGFloat(imageHeight)
        )
        let integralRect = rawRect.integral
        guard integralRect.width >= 2, integralRect.height >= 2 else {
            return nil
        }
        guard integralRect.minX >= imageBounds.minX,
              integralRect.minY >= imageBounds.minY,
              integralRect.maxX <= imageBounds.maxX,
              integralRect.maxY <= imageBounds.maxY
        else {
            return nil
        }
        return integralRect
    }

    static func clampPixelDimension(_ candidate: Int, fallback: Int) -> Int {
        let maxDimension = 16_384
        let resolved = candidate > 0 ? candidate : max(1, fallback)
        return max(1, min(maxDimension, resolved))
    }

    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func isApplicationRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
    }

    static func buildAXTree(
        processID: Int32,
        expectedWindowTitle: String,
        windowIndex: Int
    ) -> (
        simulator: AXDetectionCandidate?,
        activeEditorFileName: String?,
        activeEditorFileSource: String?,
        warnings: [String]
    ) {
        let appElement = AXUIElementCreateApplication(processID)
        let windows = axChildren(of: appElement, attribute: kAXWindowsAttribute as CFString)

        if windows.isEmpty {
            return (nil, nil, nil, ["AX did not return any windows"])
        }

        let selectedWindow = pickBestAXWindow(
            windows: windows,
            expectedTitle: expectedWindowTitle,
            fallbackIndex: windowIndex
        ) ?? windows[min(windowIndex, windows.count - 1)]

        let detectionDepth = 12
        let detection = detectSimulator(in: selectedWindow, maxDepth: detectionDepth)
        let activeEditor = detectActiveEditorFile(
            in: selectedWindow,
            fallbackWindowTitle: expectedWindowTitle
        )
        var warnings: [String] = []
        if detection.simulator == nil {
            warnings.append("Simulator subview not detected in AX tree")
        }

        return (
            detection.simulator,
            activeEditor.fileName,
            activeEditor.source,
            warnings
        )
    }

    static func detectActiveEditorFile(
        in window: AXUIElement,
        fallbackWindowTitle: String
    ) -> (fileName: String?, source: String?) {
        if let summary = findEditorContextSummary(in: window, depth: 0, maxDepth: 14),
           let normalized = normalizeLikelyFileName(summary)
        {
            return (normalized, "ax-editor-context-summary")
        }

        if let axWindowTitle = axString(of: window, attribute: kAXTitleAttribute as CFString),
           let normalized = normalizeLikelyFileNameFromWindowTitle(axWindowTitle)
        {
            return (normalized, "ax-window-title")
        }

        if let normalized = normalizeLikelyFileNameFromWindowTitle(fallbackWindowTitle) {
            return (normalized, "sc-window-title")
        }

        return (nil, nil)
    }

    static func findEditorContextSummary(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int
    ) -> String? {
        let identifier = axString(of: element, attribute: kAXIdentifierAttribute as CFString)?
            .lowercased() ?? ""
        if identifier.contains("editor context") {
            let summary = axString(of: element, attribute: kAXDescriptionAttribute as CFString)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let summary, !summary.isEmpty {
                return summary
            }
        }

        guard depth < maxDepth else {
            return nil
        }

        let children = axChildren(of: element, attribute: kAXChildrenAttribute as CFString)
        for child in children.prefix(120) {
            if let summary = findEditorContextSummary(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return summary
            }
        }
        return nil
    }

    static func normalizeLikelyFileNameFromWindowTitle(_ title: String) -> String? {
        let components = title
            .split(separator: "—", maxSplits: 4, omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let trailing = components.last {
            return normalizeLikelyFileName(trailing)
        }
        return normalizeLikelyFileName(title)
    }

    static func normalizeLikelyFileName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let candidate: String
        if trimmed.contains("/") {
            candidate = URL(fileURLWithPath: trimmed).lastPathComponent
        } else {
            candidate = trimmed
        }

        guard candidate.contains("."),
              !candidate.hasPrefix(".")
        else {
            return nil
        }

        let extensionCandidate = (candidate as NSString).pathExtension
        guard !extensionCandidate.isEmpty,
              extensionCandidate.count <= 12,
              extensionCandidate.allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            return nil
        }

        return candidate
    }

    static func pickBestAXWindow(
        windows: [AXUIElement],
        expectedTitle: String,
        fallbackIndex: Int
    ) -> AXUIElement? {
        let expected = expectedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expected.isEmpty {
            for window in windows {
                if let title = axString(of: window, attribute: kAXTitleAttribute as CFString),
                   title == expected
                {
                    return window
                }
            }

            for window in windows {
                if let title = axString(of: window, attribute: kAXTitleAttribute as CFString),
                   title.localizedCaseInsensitiveContains(expected)
                {
                    return window
                }
            }
        }

        if windows.indices.contains(fallbackIndex) {
            return windows[fallbackIndex]
        }

        return windows.first
    }

    static func detectSimulator(in root: AXUIElement, maxDepth: Int) -> AXDetectionResult {
        var state = AXDetectionState(
            bestSimulator: nil
        )
        _ = scanAXNode(
            element: root,
            depth: 0,
            maxDepth: maxDepth,
            state: &state
        )
        return AXDetectionResult(
            simulator: state.bestSimulator
        )
    }

    static func scanAXNode(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        state: inout AXDetectionState
    ) -> AXSignalSummary {
        let role = axString(of: element, attribute: kAXRoleAttribute as CFString) ?? ""
        let subrole = axString(of: element, attribute: kAXSubroleAttribute as CFString) ?? ""
        let title = axString(of: element, attribute: kAXTitleAttribute as CFString) ?? ""
        let identifier = axString(of: element, attribute: kAXIdentifierAttribute as CFString) ?? ""
        let summary = axString(of: element, attribute: kAXDescriptionAttribute as CFString) ?? ""
        let frame = axFrame(of: element)

        let roleLower = role.lowercased()
        let subroleLower = subrole.lowercased()
        let textBlob = "\(title) \(identifier) \(summary) \(role) \(subrole)".lowercased()

        var signals = AXSignalSummary()
        if textBlob.contains("iphone") || textBlob.contains("ipad") || textBlob.contains("watch") || textBlob.contains("vision") || textBlob.contains("simulator") {
            signals.simulatorWordCount += 1
        }
        if subroleLower.contains("ioscontentgroup") {
            signals.hasIOSContentGroup = true
            signals.simulatorWordCount += 3
        }

        if depth < maxDepth {
            let children = axChildren(of: element, attribute: kAXChildrenAttribute as CFString)
            for child in children.prefix(120) {
                let childSignals = scanAXNode(
                    element: child,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    state: &state
                )
                signals.merge(childSignals)
            }
        }

        if let frame {
            if let simulatorCandidate = scoreSimulatorCandidate(
                frame: frame,
                roleLower: roleLower,
                subroleLower: subroleLower,
                signals: signals
            ) {
                updateBestCandidate(current: &state.bestSimulator, candidate: simulatorCandidate)
            }
        }

        return signals
    }

    static func scoreSimulatorCandidate(
        frame: CGRect,
        roleLower: String,
        subroleLower: String,
        signals: AXSignalSummary
    ) -> AXDetectionCandidate? {
        var score = 0
        var reasons: [String] = []

        if subroleLower.contains("ioscontentgroup") {
            score += 220
            reasons.append("subrole=iOSContentGroup")
        }

        if signals.simulatorWordCount > 0 {
            score += min(60, signals.simulatorWordCount * 12)
            reasons.append("simulator-controls")
        }

        if roleLower == "axgroup" || roleLower == "axscrollarea" {
            score += 8
        }

        let aspectRatio = frame.height / max(frame.width, 1)
        if aspectRatio > 1.6 && aspectRatio < 2.6 {
            score += 20
            reasons.append("phone-aspect")
        }

        if frameArea(frame) > 40_000 {
            score += 8
        }

        guard score >= 70 else {
            return nil
        }

        return AXDetectionCandidate(
            frame: frame,
            score: score,
            confidence: min(0.99, max(0.1, Double(score) / 260.0)),
            reason: reasons.joined(separator: ", ")
        )
    }

    static func updateBestCandidate(
        current: inout AXDetectionCandidate?,
        candidate: AXDetectionCandidate
    ) {
        guard let existing = current else {
            current = candidate
            return
        }

        if candidate.score > existing.score {
            current = candidate
            return
        }

        if candidate.score == existing.score, frameArea(candidate.frame) < frameArea(existing.frame) {
            current = candidate
        }
    }

    static func frameArea(_ frame: CGRect) -> Double {
        max(0.0, Double(frame.width)) * max(0.0, Double(frame.height))
    }

    static func axValue(of element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }
        return value
    }

    static func axString(of element: AXUIElement, attribute: CFString) -> String? {
        axValue(of: element, attribute: attribute) as? String
    }

    static func axChildren(of element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        guard let raw = axValue(of: element, attribute: attribute) as? [AnyObject] else {
            return []
        }
        return raw.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeDowncast(item, to: AXUIElement.self)
        }
    }

    static func axFrame(of element: AXUIElement) -> CGRect? {
        guard let raw = axValue(of: element, attribute: axFrameAttribute) else {
            return nil
        }

        guard CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgRect else {
            return nil
        }

        var frame = CGRect.zero
        let ok = AXValueGetValue(axValue, .cgRect, &frame)
        return ok ? frame : nil
    }
}
