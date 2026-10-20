import SwiftUI
import AppKit

/// Schreib-Timer (wie MacJournal „Writing Timer“): läuft im Hintergrund, am Ende ein Ton und ein Hinweis.
final class WritingTimer: ObservableObject {
    static let shared = WritingTimer()
    /// Restzeit als „12:34“; nil, wenn kein Timer läuft.
    @Published private(set) var remaining: String?
    /// Zeit ist um (für den Hinweis im Fenster).
    @Published var finished = false
    private var end: Date?
    private var timer: Timer?

    static let choices = [5, 10, 15, 25, 45, 60]

    func start(minutes: Int) {
        end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        finished = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        end = nil
        remaining = nil
    }

    private func tick() {
        guard let end else { return }
        let left = Int(end.timeIntervalSinceNow.rounded())
        if left <= 0 {
            stop()
            finished = true
            NSSound(named: "Glass")?.play()
            NSApp.requestUserAttention(.informationalRequest)
            return
        }
        remaining = String(format: "%d:%02d", left / 60, left % 60)
    }
}

/// Unten in der Statusleiste: Wörter, Schreibziel und Timer.
struct WritingStatus: View {
    let words: Int
    @AppStorage("wordGoal") private var goal = 0
    @ObservedObject private var timer = WritingTimer.shared

    var body: some View {
        HStack(spacing: 10) {
            if let remaining = timer.remaining {
                Label(remaining, systemImage: "timer")
                    .monospacedDigit()
                    .help("Schreib-Timer läuft (Eintrag › Schreib-Timer)")
            }
            if goal > 0 {
                let reached = words >= goal
                Label("\(words) / \(goal) Wörter", systemImage: reached ? "checkmark.circle.fill" : "target")
                    .foregroundStyle(reached ? Color.green : Color.secondary)
                    .help(reached ? "Schreibziel erreicht" : "Schreibziel (Einstellungen)")
            } else {
                Text(words == 1 ? "1 Wort" : "\(words) Wörter")
            }
        }
    }
}
