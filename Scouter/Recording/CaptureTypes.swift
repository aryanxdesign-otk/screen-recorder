import AppKit
import AVFoundation
import CoreMedia

enum CaptureMode: String, CaseIterable, Identifiable {
    case display
    case window
    case area

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "Display"
        case .window: "Window"
        case .area: "Area"
        }
    }

    var symbol: String {
        switch self {
        case .display: "menubar.dock.rectangle"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        }
    }
}

enum CaptureTarget {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// Rect in the display's own point coordinates, top-left origin.
    case area(CGDirectDisplayID, CGRect)
}

struct CaptureDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

enum DeviceCatalog {
    static func cameras() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func microphones() -> [CaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { CaptureDevice(id: $0.uniqueID, name: $0.localizedName) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == displayID }
    }

    static var withMouse: NSScreen {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? screens[0]
    }

    /// Height of the primary display, used to flip between Cocoa (bottom-left) and Quartz (top-left) global coordinates.
    static var primaryHeight: CGFloat {
        screens.first?.frame.height ?? 0
    }

    static func quartzRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    static func cocoaRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

extension CMSampleBuffer {
    /// Copy of the buffer shifted so its first sample starts at `newStart`.
    func retimed(to newStart: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return nil
        }
        let delta = newStart - presentationTimeStamp
        for i in timings.indices {
            timings[i].presentationTimeStamp = timings[i].presentationTimeStamp + delta
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = timings[i].decodeTimeStamp + delta
            }
        }
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: self,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &output
        ) == noErr else { return nil }
        return output
    }
}
