import Foundation

/// Defaults the pane header uses when it exposes a pane.
///
/// The button is one click; it does not stop to ask for a TTL or a key policy.
/// These are where that choice lives, so the CLI keeps its per-invocation
/// flags and the button keeps its single click.
enum MobileRemoteControlSettings {
    static let ttlSecondsKey = "mobileRemoteControl.ttlSeconds"
    static let keysPolicyKey = "mobileRemoteControl.keysPolicy"

    /// The CLI's own default. The daemon clamps to 60s-7d regardless, so a
    /// stored value outside that range is the daemon's to correct, not ours to
    /// pre-empt — storing a clamped copy would disagree with what it recorded.
    static let defaultTTLSeconds = 24 * 60 * 60

    static func ttlSeconds(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: ttlSecondsKey)
        return stored > 0 ? stored : defaultTTLSeconds
    }

    static func setTTLSeconds(_ seconds: Int, defaults: UserDefaults = .standard) {
        defaults.set(seconds, forKey: ttlSecondsKey)
    }

    /// `safe` is the fixed allowlist in docs/mobile-remote-control.md §6.
    /// Anything unrecognised reads as `safe` rather than as `none`: a stored
    /// value nobody understands must not quietly widen what the phone may send.
    static func keysPolicy(defaults: UserDefaults = .standard) -> RemoteExposureStore.KeysPolicy {
        guard let raw = defaults.string(forKey: keysPolicyKey),
              let policy = RemoteExposureStore.KeysPolicy(rawValue: raw) else {
            return .safe
        }
        return policy
    }

    static func setKeysPolicy(
        _ policy: RemoteExposureStore.KeysPolicy,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(policy.rawValue, forKey: keysPolicyKey)
    }
}
