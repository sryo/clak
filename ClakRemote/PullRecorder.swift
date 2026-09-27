#if DEBUG
import Foundation

/// Saves each pull's raw drag path, so a gesture that misbehaves on a real
/// finger can be copied off the phone and replayed through `PullStepper` in a
/// unit test. Debug builds only.
///
/// Files land in the app's Documents/pulls as JSON; fetch them with
/// `xcrun devicectl device copy from --domain-type appDataContainer
/// --domain-identifier com.clak.remote --source Documents/pulls --destination <dir>`.
enum PullRecorder {
    struct Sample: Codable {
        let t: TimeInterval
        let x: CGFloat
        let y: CGFloat
        /// What the stepper made of it, to compare against a replay.
        let steps: Int
    }

    struct Pull: Codable {
        let started: Date
        let samples: [Sample]
    }

    private static var samples: [Sample] = []
    private static var started = Date()
    /// Oldest recordings are dropped past this, so the folder can't grow.
    private static let kept = 50

    static func record(_ translation: CGSize, steps: Int) {
        if samples.isEmpty { started = Date() }
        samples.append(Sample(t: Date().timeIntervalSince(started),
                              x: translation.width, y: translation.height, steps: steps))
    }

    static func finish() {
        defer { samples = [] }
        // A tap is not worth keeping.
        guard samples.count > 10 else { return }
        let pull = Pull(started: started, samples: samples)
        DispatchQueue.global(qos: .utility).async { write(pull) }
    }

    private static func write(_ pull: Pull) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = docs.appendingPathComponent("pulls", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("\(formatter.string(from: pull.started)).json")
        guard let data = try? JSONEncoder().encode(pull) else { return }
        try? data.write(to: url)

        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for old in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).dropLast(kept) {
            try? fm.removeItem(at: old)
        }
    }
}
#endif
