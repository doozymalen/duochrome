import Foundation

/// Background job gate: Apple's RAW decoder serializes decodes (RawCamera's internal serial queue).
/// So background RAW decodes (thumbnails, previews, haze, tone histograms) make the visible photo's decode wait behind them.
/// While the user is doing something (opening, drawing, changing values), background jobs wait briefly before decoding.
enum BackgroundGate {
    private static let lock = NSLock()
    private static var last: CFAbsoluteTime = 0
    /// Background work runs after this much quiet (seconds)
    static var quiet: Double = 0.8
    /// Number of long foreground jobs (export etc.) in progress
    private static var busy = 0

    /// Holds background work during long foreground jobs (so export etc. doesn't look idle while the main thread is busy)
    static func during<T>(_ f: () throws -> T) rethrows -> T {
        lock.lock(); busy += 1; lock.unlock()
        defer { lock.lock(); busy -= 1; last = CFAbsoluteTimeGetCurrent(); lock.unlock() }
        return try f()
    }

    /// Something happened in the foreground (call on the main thread)
    static func touch() {
        lock.lock(); last = CFAbsoluteTimeGetCurrent(); lock.unlock()
    }

    /// Background thread: waits until the foreground is quiet (at most `limit` seconds — never blocks forever)
    static func waitQuiet(limit: Double = 20) {
        guard !Thread.isMainThread else { return }
        let start = CFAbsoluteTimeGetCurrent()
        while CFAbsoluteTimeGetCurrent() - start < limit {
            lock.lock(); let idle = CFAbsoluteTimeGetCurrent() - last; let working = busy > 0; lock.unlock()
            if idle >= quiet && !working { return }
            Thread.sleep(forTimeInterval: max(0.05, min(0.2, quiet - idle + 0.01)))
        }
    }
}
