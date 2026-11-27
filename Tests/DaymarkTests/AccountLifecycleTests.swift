import Foundation
import Testing
@testable import Daymark

@MainActor @Suite("Account lifecycle edge cases", .timeLimit(.minutes(1)))
struct AccountLifecycleTests {
    // Kills: sign-in failure not reported / spinner stuck.
    @Test("A failed sign-in is reported, stops the spinner and adds nothing")
    func signInFailure() async throws {
        let w = await World(accounts: [Fx.alice])
        let s = await w.start()
        await w.oauth.queueSignInFailure(OAuthError.noRefreshToken)
        s.addAccount()
        await w.settle()
        #expect(!s.isSigningIn)
        #expect(s.errorMessage == OAuthError.noRefreshToken.localizedDescription)
        #expect(s.accounts.map(\.email) == [Fx.alice])
        #expect(w.vault.writes.isEmpty)
    }

    // Kills: addAccount without client.
    @Test("Adding an account before any OAuth client exists opens setup and starts nothing")
    func addAccountWithoutClient() async throws {
        let w = await World(vault: MemoryVault())
        let s = await w.start()
        s.showSetup = false
        s.addAccount()
        #expect(s.showSetup)
        #expect(!s.isSigningIn)
        #expect(await w.oauth.signInClients.isEmpty)
    }

    @Test("'New event' with no accounts starts sign-in instead of doing nothing")
    func beginCreateNoAccounts() async throws {
        let w = await World(accounts: [])
        let s = await w.start()
        await w.oauth.queueSignIn(email: Fx.bob, refreshToken: "rt-B")
        s.beginCreate()
        #expect(s.isSigningIn)
        await w.settle()
        #expect(s.accounts.map(\.email) == [Fx.bob])
    }

    // Kills: failedCalendarKeys prefix match.
    @Test("Removing an account doesn't clear another account whose address starts the same")
    func prefixEmails() async throws {
        let a = "ann@x.co", b = "ann@x.com"
        let w = await World(accounts: [a, b])
        for e in [a, b] {
            await w.oauth.own(Fx.refreshToken(e), by: e)
            await w.google.addCalendar(e, Fx.calendar(e, role: "owner", primary: true))
        }
        await w.google.on({ $0.isEventsList && $0.account == b }, always: .status(500, googleError(500, "backendError")))
        let s = await w.start()
        #expect(s.failedCalendarKeys == [Fx.key(b, b)])
        s.removeAccount(a)
        #expect(s.failedCalendarKeys == [Fx.key(b, b)])
    }

    @Test("Signing in again with a differently capitalised address updates the same account")
    func reSignInIsCaseInsensitive() async throws {
        let w = await World()
        let s = await w.start()
        await w.oauth.queueSignIn(email: "Bob@Work.Example", refreshToken: "rt-B2")
        s.addAccount()
        await w.settle()
        #expect(s.accounts.count == 3)
        #expect(w.vault.current?.accounts.map(\.refreshToken) == ["rt-A", "rt-B2", "rt-C"])
    }

    @Test("Re-signing in with different capitalisation reuses the stored account's token slot")
    func reSignInCaseKeepsTokenSlot() async throws {
        let w = await World()
        let s = await w.start()
        await w.oauth.queueSignIn(email: "BOB@work.example", refreshToken: "rt-B2")
        s.addAccount()
        await w.settle()
        #expect(s.accounts.map(\.email) == [Fx.alice, Fx.bob, Fx.carol])
        await s.refresh()
        #expect(await w.oauth.refreshCount(for: "rt-B2") == 0, "the sign-in's access token is found under the stored email")
    }

    @Test("Signing in again revokes the refresh token it replaces")
    func reSignInRevokesOldToken() async throws {
        let w = await World()
        let s = await w.start()
        await w.oauth.queueSignIn(email: Fx.bob, refreshToken: "rt-B2")
        s.addAccount()
        await w.settle()
        #expect(await w.oauth.revoked == ["rt-B"])
        #expect(w.vault.current?.accounts.first { $0.email == Fx.bob }?.refreshToken == "rt-B2")
    }

    @Test("Sign-in fails clearly when Google omits the refresh token or the email", .timeLimit(.minutes(1)),
          arguments: ["no-refresh", "no-email"])
    func signInMissingFields(kind: String) async throws {
        let idToken = "h." + Data(#"{"sub":"1"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
        let goodId = "h." + Data(#"{"email":"a@b.co"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "") + ".s"
        let body = kind == "no-refresh"
            ? #"{"access_token":"at","expires_in":3600,"id_token":"\#(goodId)"}"#
            : #"{"access_token":"at","expires_in":3600,"refresh_token":"rt","id_token":"\#(idToken)"}"#
        let t = ScriptedTransport([.ok(body)])
        do {
            _ = try await OAuthService.signIn(client: Fx.client, transport: t.transport) { url in
                let q = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
                var cb = URLComponents(string: q["redirect_uri"]!)!
                cb.queryItems = [URLQueryItem(name: "code", value: "c"), URLQueryItem(name: "state", value: q["state"])]
                _ = try? await URLSession.shared.data(from: cb.url!)
            }
            Issue.record("sign-in should fail")
        } catch let e as OAuthError {
            #expect(e == (kind == "no-refresh" ? .noRefreshToken : .server("no email in ID token")))
        }
    }

    // Kills: revoke request shape.
    @Test("Revoking sends the token to Google's revoke endpoint as a form POST")
    func revokeRequest() async throws {
        let t = ScriptedTransport([.ok()])
        await OAuthService.revoke(token: "1//rt+/=&x", transport: t.transport)
        let r = try #require(await t.requests.first)
        #expect(r.httpMethod == "POST" && r.url?.absoluteString == "https://oauth2.googleapis.com/revoke")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        var form = URLComponents()
        form.percentEncodedQuery = String(data: r.httpBody!, encoding: .utf8)
        #expect(form.queryItems?.map { "\($0.name)=\($0.value ?? "")" } == ["token=1//rt+/=&x"])
    }

    @Test("A disabled Calendar API is explained, not shown as a generic network error")
    func apiNotEnabledMessage() async throws {
        let w = await World()
        await w.google.on({ $0.segments.first == "users" && $0.account == Fx.alice }, always: .status(403, googleError(403, "accessNotConfigured",
            "Google Calendar API has not been used in project 123 before or it is disabled. Enable it by visiting https://console.developers.google.com/")))
        let s = await w.start()
        let issue = try #require(s.accountIssues[Fx.alice])
        #expect(issue.message.contains("Calendar API isn't enabled"))
        #expect(!issue.needsReconnect)
        #expect(CalendarStore.describe(URLError(.notConnectedToInternet)).hasPrefix("Couldn't reach Google"))
    }

    @Test("Removing the last account while its reminders are loading leaves no reminders behind")
    func removeDuringReminderFetch() async throws {
        let w = await World(accounts: [Fx.alice])
        await w.put(Fx.alice, Fx.alice, Fx.timed("in", "Soon", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        s.selectedDate = at(2027, 11, 15)   // the reminder horizon now needs its own fetch
        await w.settle()
        let gate = Gate()
        let horizon = RFC3339.string(T0)
        await w.google.on({ $0.isEventsList && $0.query["timeMin"] == horizon }, always: .gate(gate))
        await w.google.clearRequests()
        let refresh = Task { await s.refresh() }
        await w.google.waitFor(where: { $0.isEventsList && $0.query["timeMin"] == horizon })
        s.removeAccount(Fx.alice)
        await gate.open()
        await refresh.value
        await w.settle()
        #expect(w.notifier.last?.isEmpty == true, "the stale fetch must not re-arm the removed account's reminders")
        #expect(s.events.isEmpty && s.calendars.isEmpty)
    }

    // Demonstrates production bug: view clears results without invalidating an in-flight search.
    @Test("Clearing the search box while a search is running leaves no results behind")
    func clearWhileSearching() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("a", "alpha", at(2026, 12, 2, 9), at(2026, 12, 2, 10)))
        let s = await w.start()
        let gate = Gate()
        await w.google.on({ $0.query["q"] == "alpha" }, always: .gate(gate))
        s.searchText = "alpha"
        let search = Task { await s.performSearch() }
        await w.google.waitFor(6, where: { $0.query["q"] == "alpha" })
        s.searchText = ""   // the user empties the search field
        #expect(!s.isSearching)
        await gate.open()
        await search.value
        #expect(s.searchResults == nil, "stale results reappeared under an empty search box")
    }

    // Demonstrates: removed account's failed search key lingers.
    @Test("Removing an account clears its calendars from the 'couldn't search' warning")
    func searchFailureAfterRemoval() async throws {
        let w = await World()
        let s = await w.start()
        await w.google.on({ $0.query["q"] != nil && $0.account == Fx.bob }, always: .status(500, googleError(500, "backendError")))
        s.searchText = "x"
        await s.performSearch()
        #expect(!s.searchFailedCalendarKeys.isEmpty)
        s.removeAccount(Fx.bob)
        #expect(s.searchFailedCalendarKeys.isEmpty)
    }
}
