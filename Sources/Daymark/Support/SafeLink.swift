import AppKit

/// Opens links that came from event data (invites can be written by anyone). Only web links are
/// opened; anything else (file:, custom app schemes) is ignored.
enum SafeLink {
    static func url(_ s: String?) -> URL? {
        guard let s, let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    @MainActor
    static func open(_ s: String?) {
        if let url = url(s) { NSWorkspace.shared.open(url) }
    }
}
