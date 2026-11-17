import AppKit

/// Media control by way of the system media keys, so it reaches whatever is actually playing —
/// Music, Spotify, or a YouTube Music tab in a browser.
///
/// Posting these needs the Accessibility (post event) permission. Without it the events are dropped
/// silently, with no error, so always check `hasPermission` before promising the user anything.
enum MediaKeys {
    /// Values from IOKit's `hidsystem/ev_keymap.h`.
    enum Key: Int32 {
        case volumeUp = 0, volumeDown = 1, mute = 7, playPause = 16, next = 17, previous = 18
    }

    static var hasPermission: Bool { CGPreflightPostEventAccess() }

    /// Asks the system for permission. The first call shows the prompt; later calls just open
    /// System Settings, since macOS only offers the prompt once per app.
    static func requestPermission() {
        if !CGRequestPostEventAccess() { openSettings() }
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    /// A media key is a `systemDefined` event, subtype 8, with the key code and state packed into data1.
    @discardableResult
    static func post(_ key: Key) -> Bool {
        guard hasPermission else { return false }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0xA00 : 0xB00))
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                                 timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                                 data1: Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8)),
                                                 data2: -1),
                  let cg = event.cgEvent else { return false }
            cg.post(tap: .cghidEventTap)
        }
        return true
    }
}

/// One slot on the gramophone wheel.
struct GramophoneAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let detail: String
    /// Volume keeps the wheel open so it can be nudged repeatedly; everything else closes on commit.
    var staysOpen = false
    var key: MediaKeys.Key?
    /// Used instead of a media key when set: volume, mute, opening a playlist.
    var open: (() -> Void)?
    /// True when this control works without the Accessibility permission.
    var needsNoPermission: Bool { key == nil }

    /// Volume and mute go through CoreAudio, which needs no permission; only transport needs the keys.
    static func all(playlist: String) -> [GramophoneAction] {
        let trimmed = playlist.trimmingCharacters(in: .whitespacesAndNewlines)
        let muted = SystemAudio.isMuted ?? false
        return [
            .init(id: "play", title: "Play / Pause", symbol: "playpause.fill", detail: "Whatever is playing", key: .playPause),
            .init(id: "next", title: "Next", symbol: "forward.end.fill", detail: "Skip ahead", key: .next),
            .init(id: "volup", title: "Louder", symbol: "speaker.wave.3.fill",
                  detail: SystemAudio.volume.map { "Now \(Int($0 * 100))%" } ?? "Raise the volume",
                  staysOpen: true, open: { SystemAudio.nudgeVolume(by: 1.0 / 16) }),
            .init(id: "mute", title: muted ? "Unmute" : "Mute", symbol: muted ? "speaker.fill" : "speaker.slash.fill",
                  detail: muted ? "Sound is off" : "Silence it", open: { SystemAudio.toggleMute() }),
            .init(id: "playlist", title: trimmed.isEmpty ? "Set a playlist" : "Playlist",
                  symbol: "music.note.list",
                  detail: trimmed.isEmpty ? "Add one in Settings" : Self.host(trimmed),
                  open: { Self.openPlaylist(trimmed) }),
            .init(id: "voldown", title: "Softer", symbol: "speaker.wave.1.fill",
                  detail: SystemAudio.volume.map { "Now \(Int($0 * 100))%" } ?? "Lower the volume",
                  staysOpen: true, open: { SystemAudio.nudgeVolume(by: -1.0 / 16) }),
            .init(id: "prev", title: "Previous", symbol: "backward.end.fill", detail: "Back a track", key: .previous),
            .init(id: "music", title: "Music", symbol: "music.note", detail: "Open the Music app",
                  open: { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app")) }),
        ]
    }

    private static func openPlaylist(_ raw: String) {
        guard !raw.isEmpty else { return }
        let text = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: text), url.host != nil else { return }
        NSWorkspace.shared.open(url)
    }

    static func host(_ raw: String) -> String {
        let text = raw.contains("://") ? raw : "https://" + raw
        return URL(string: text)?.host?.replacingOccurrences(of: "www.", with: "") ?? "Open"
    }
}
