import AppKit
import Combine
import LocalAuthentication

/// Private notes and clipboard items, as on Linux with the fingerprint reader: they show as
/// "Private" until Touch ID (or the Mac's password) opens them, then stay open for 5 minutes or
/// until the screen locks.
final class PrivacyModel: ObservableObject {
    @Published private(set) var unlocked = false

    static let openFor: TimeInterval = 5 * 60

    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in self?.lock() }
    }

    /// Asks for Touch ID (or the password) and opens the private items.
    func unlock() {
        guard !unlocked else { return }
        let context = LAContext()
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else { return }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your private notes and clipboard items") { [weak self] ok, _ in
            DispatchQueue.main.async {
                if ok { self?.open() }
            }
        }
    }

    func lock() {
        timer?.invalidate()
        timer = nil
        unlocked = false
    }

    private func open() {
        unlocked = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.openFor, repeats: false) { [weak self] _ in self?.lock() }
    }
}
