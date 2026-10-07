import Cocoa
import ApplicationServices

enum PermissionRenewalResult: Equatable { case unchanged, requested, resetFailed }

struct AccessibilityPermissionRenewal {
    var reset: () -> Bool
    var request: () -> Void

    func renew() -> PermissionRenewalResult {
        guard reset() else { return .resetFailed }
        request()
        return .requested
    }

    func configure(version: String, preferences: UserDefaults) -> PermissionRenewalResult {
        guard PermissionVersionConfiguration.shouldConfigure(version: version, preferences: preferences) else { return .unchanged }
        return renew()
    }

    static var live: Self {
        Self(reset: {
            // Never reset a service globally or touch another application's grant.
            guard Bundle.main.bundleIdentifier == AppInstallation.identifier else { return false }
            return AppInstallation.run("/usr/bin/tccutil", ["reset", "Accessibility", AppInstallation.identifier])
        }, request: {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        })
    }
}
