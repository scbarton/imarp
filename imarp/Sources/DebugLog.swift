import UIKit

/// An always-on log of what the app and both screens are doing, written to
/// a file on the iPad so odd behavior during a talk can be traced afterwards
/// without the iPad being tethered to a Mac.
///
/// One file per day in Documents/Logs (`imarp-YYYY-MM-DD.log`), visible in
/// the Files app under On My iPad › iMarp › Logs, or copied off over USB:
///
///     xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
///         --domain-identifier org.powrbox.imarp --source Documents/Logs --destination .
///
/// Files older than `keepDays` are deleted at launch, and a day's file stops
/// growing at `maximumFileSize`. Every line is written straight to the file
/// (no buffering), so nothing is lost if the app is killed. Debug builds also
/// print each line to the console.
enum DebugLog {
    static let keepDays = 7
    static let maximumFileSize: UInt64 = 20_000_000

    static let directory: URL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)

    private static let queue = DispatchQueue(label: "org.powrbox.imarp.log")
    private static var handle: FileHandle?
    private static var handleDay = ""
    private static var isFull = false

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Writes one line, tagged with `category` (e.g. "ipad", "external",
    /// "touch"). Safe to call from any thread.
    static func write(_ category: String, _ message: String) {
        let now = Date()
        #if DEBUG
        print("[imarp \(category)] \(message)")
        #endif
        queue.async {
            let day = dayFormatter.string(from: now)
            let line = "\(timeFormatter.string(from: now)) [\(category)] \(message)\n"
            append(line, day: day)
        }
    }

    /// Called once at launch: clears out old files and records which build
    /// and device the following lines come from.
    static func start() {
        queue.async { pruneOldFiles() }
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        write("app", "==== launch: imarp \(version) (\(build)), \(device.model) \(modelIdentifier()), \(device.systemName) \(device.systemVersion)")
    }

    private static func append(_ line: String, day: String) {
        if day != handleDay {
            try? handle?.close()
            handle = nil
            handleDay = day
            isFull = false
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("imarp-\(day).log")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        guard let handle, !isFull else { return }
        if let size = try? handle.offset(), size > maximumFileSize {
            isFull = true
            try? handle.write(contentsOf: Data("---- log full for today, nothing more is written ----\n".utf8))
            return
        }
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private static func pruneOldFiles() {
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 24 * 3600)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for file in files where file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// e.g. "iPad13,4", which says more than UIDevice's "iPad".
    private static func modelIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// Watches every touch over a view without taking part: it never recognizes,
/// never cancels or delays touches, so the page, PencilKit and the app's own
/// gestures behave exactly as without it. Logs where each touch starts and
/// ends (finger or Pencil, how far it moved, how long it lasted) so a log
/// shows what the presenter actually did before something went wrong.
final class TouchLogger: UIGestureRecognizer {
    /// Turns a touch into a position on the slide for the log (e.g.
    /// normalized 0...1 over the slide), or nil to log view points.
    var describeLocation: ((UITouch) -> String)?

    private var starts: [ObjectIdentifier: (point: CGPoint, time: TimeInterval)] = [:]

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            starts[ObjectIdentifier(touch)] = (touch.location(in: view), touch.timestamp)
            DebugLog.write("touch", "\(Self.kind(touch)) down at \(place(touch)), \(event.allTouches?.count ?? 1) on screen")
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, how: "up")
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches, how: "cancelled")
    }

    private func finish(_ touches: Set<UITouch>, how: String) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            var detail = ""
            if let start = starts.removeValue(forKey: id) {
                let end = touch.location(in: view)
                let dx = Int(end.x - start.point.x), dy = Int(end.y - start.point.y)
                let ms = Int((touch.timestamp - start.time) * 1000)
                detail = ", moved (\(dx), \(dy)) pt in \(ms) ms"
            }
            DebugLog.write("touch", "\(Self.kind(touch)) \(how) at \(place(touch))\(detail)")
        }
        // A recognizer that never recognizes has to fail once its touches are
        // gone, or it would sit in .possible and never see the next ones.
        if starts.isEmpty { state = .failed }
    }

    override func reset() {
        super.reset()
        starts.removeAll()
    }

    private func place(_ touch: UITouch) -> String {
        if let describeLocation { return describeLocation(touch) }
        let point = touch.location(in: view)
        return "(\(Int(point.x)), \(Int(point.y)))"
    }

    static func kind(_ touch: UITouch) -> String {
        switch touch.type {
        case .pencil: return "pencil"
        case .direct: return "finger"
        case .indirectPointer: return "pointer"
        default: return "touch(\(touch.type.rawValue))"
        }
    }
}

extension UIGestureRecognizer.State {
    var logName: String {
        switch self {
        case .possible: return "possible"
        case .began: return "began"
        case .changed: return "changed"
        case .ended: return "ended"
        case .cancelled: return "cancelled"
        case .failed: return "failed"
        @unknown default: return "unknown"
        }
    }
}

