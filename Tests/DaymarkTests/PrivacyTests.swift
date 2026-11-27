import Foundation
import Testing
@testable import Daymark

@MainActor @Suite("Privacy and untrusted links", .timeLimit(.minutes(1)))
struct PrivacyTests {
    @Test("The network session keeps nothing on disk: no cache, cookies or stored credentials")
    func ephemeralSession() {
        let c = HTTP.session.configuration
        #expect(c.urlCache == nil)
        #expect(c.httpCookieStorage == nil && !c.httpShouldSetCookies)
        #expect(c.urlCredentialStorage == nil)
        #expect(c.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("Only web links from event data are opened", arguments: [
        ("https://meet.google.com/abc-defg-hij", true),
        ("http://example.com/x", true),
        ("  https://zoom.us/j/1  ", true),
        ("HTTPS://MEET.GOOGLE.COM/x", true),
        ("file:///Applications/Calculator.app", false),
        ("javascript:alert(1)", false),
        ("x-apple.systempreferences:com.apple.preference.security", false),
        ("ssh://evil.example", false),
        ("https://", false),
        ("not a url", false),
        ("", false),
    ])
    func safeLinks(link: String, allowed: Bool) {
        #expect((SafeLink.url(link) != nil) == allowed)
    }

    @Test("Descriptions only make web links clickable")
    func linkifyWebOnly() {
        let a = Fmt.linkified("Notes: https://docs.example/a and file:///etc/passwd and mailto:x@y.z")
        #expect(a.runs.compactMap(\.link) == [URL(string: "https://docs.example/a")!])
    }
}
