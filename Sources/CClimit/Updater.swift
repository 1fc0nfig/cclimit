import Combine
import Sparkle
import SwiftUI

/// Wraps Sparkle's updater so SwiftUI can bind to it.
///
/// Starting the controller kicks off Sparkle's background schedule: if the user has
/// automatic checks on, it polls the appcast (SUFeedURL in Info.plist) and, on a newer
/// signed build, shows the standard update prompt. Updates are verified against the
/// EdDSA public key baked into Info.plist (SUPublicEDKey) — the private half lives only
/// in the release machine's Keychain, so a tampered download can't install.
///
/// No delegates: the stock `SPUStandardUpdaterController` UI is exactly the Mac-native
/// "A new version is available" flow, which is what we want for v0.1.
final class UpdaterViewModel: ObservableObject {
    /// False while a check is already running or the updater couldn't start — drives the
    /// "Check for Updates…" button's disabled state.
    @Published private(set) var canCheckForUpdates = false

    /// Two-way bound to the Settings toggle; writes straight through to Sparkle.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    private let controller: SPUStandardUpdaterController

    private var updater: SPUUpdater { controller.updater }

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// User-initiated check — always shows UI, even when already up to date.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// The version Sparkle compares against the appcast, for display in Settings.
    var currentVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return short ?? "—"
    }
}
