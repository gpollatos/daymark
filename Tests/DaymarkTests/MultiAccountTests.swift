import Foundation
import Testing
@testable import Daymark

/// How several Google accounts are merged, kept apart, and survive each other's failures.
@MainActor @Suite("Multi-account aggregation", .timeLimit(.minutes(1)))
struct MultiAccountTests {
    @Test("Events from every account and calendar are merged, sorted and attributed correctly")
    func mergedAndAttributed() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.team, Fx.timed("t1", "Team sync", at(2026, 11, 26, 9), at(2026, 11, 26, 10)))
        await w.put(Fx.alice, Fx.alice, Fx.timed("a1", "Dentist", at(2026, 11, 26, 8), at(2026, 11, 26, 9)))
        await w.put(Fx.carol, Fx.carol, Fx.allDay("c1", "Field trip", "2026-11-26", "2026-11-27"))
        await w.put(Fx.alice, Fx.family, Fx.timed("f1", "Dinner", at(2026, 11, 26, 19), at(2026, 11, 26, 21)))
        await w.put(Fx.alice, Fx.holiday, Fx.allDay("h1", "Thanksgiving", "2026-11-26", "2026-11-27"))
        let s = await w.start()

        // Sorted by (start, end, id) across accounts; ties broken by the account-scoped id.
        #expect(s.events.map(\.eventId) == ["h1", "c1", "a1", "t1", "f1"])
        let byId = Dictionary(uniqueKeysWithValues: s.events.map { ($0.eventId, $0) })
        #expect(byId["t1"]?.accountEmail == Fx.bob)
        #expect(byId["t1"]?.calendarKey == Fx.key(Fx.bob, Fx.team))
        #expect(byId["t1"]?.calendarName == "Team")
        #expect(byId["t1"]?.canEdit == false, "reader calendar")
        #expect(byId["a1"]?.colorHex == "#039BE5", "legacy #9fe1e7 maps to Peacock")
        #expect(byId["f1"]?.colorHex == "#7CB342", "legacy #7bd148 maps to Pistachio")
        #expect(byId["c1"]?.isAllDay == true)
        // The holiday calendar has no `selected` flag, so it is loaded but hidden.
        #expect(!s.visibleEvents.contains { $0.eventId == "h1" })
        #expect(s.visibleEvents.count == 4)
    }

    @Test("Every calendar is fetched with its own account's token, and nothing is fetched cross-account")
    func requestsAreRoutedPerAccount() async throws {
        let w = await World()
        let s = await w.start()
        let reqs = await w.requests()
        let lists = Set(reqs.filter(\.isEventsList).map { "\($0.account ?? "?")|\($0.calendarId!)" })
        #expect(lists == [Fx.key(Fx.alice, Fx.alice), Fx.key(Fx.alice, Fx.holiday), Fx.key(Fx.alice, Fx.family),
                          Fx.key(Fx.bob, Fx.bob), Fx.key(Fx.bob, Fx.team),
                          Fx.key(Fx.carol, Fx.carol), Fx.key(Fx.carol, Fx.family)])
        let calendarLists = reqs.filter { $0.segments.first == "users" }.compactMap(\.account)
        #expect(calendarLists.sorted() == [Fx.alice, Fx.bob, Fx.carol])
        #expect(s.accountIssues.isEmpty && s.failedCalendarKeys.isEmpty)
    }

    @Test("The same calendar id in two accounts stays two independent calendars")
    func sameCalendarIdInTwoAccounts() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.family, Fx.timed("ev1", "Alice's copy", at(2026, 11, 27, 18), at(2026, 11, 27, 19)))
        await w.put(Fx.carol, Fx.family, Fx.timed("ev1", "Carol's copy", at(2026, 11, 27, 18), at(2026, 11, 27, 19)))
        let s = await w.start()

        let a = Fx.id(Fx.alice, Fx.family, "ev1"), c = Fx.id(Fx.carol, Fx.family, "ev1")
        #expect(w.eventIds.isSuperset(of: [a, c]))
        #expect(s.events.first { $0.id == a }?.title == "Alice's copy")
        #expect(s.events.first { $0.id == c }?.title == "Carol's copy")

        s.setVisible(try #require(s.calendar(key: Fx.key(Fx.carol, Fx.family))), false)
        #expect(s.visibleEvents.contains { $0.id == a })
        #expect(!s.visibleEvents.contains { $0.id == c })

        // Deleting Alice's copy hits only Alice's calendar.
        await w.google.clearRequests()
        await s.delete(try #require(s.events.first { $0.id == a }), allOccurrences: false)
        let deletes = await w.requests { $0.method == "DELETE" }
        #expect(deletes.count == 1)
        #expect(deletes.first?.account == Fx.alice)
        #expect(await w.google.eventCount(Fx.carol, Fx.family) == 1)
        #expect(!w.eventIds.contains(a) && w.eventIds.contains(c))
    }

    @Test("Visibility defaults to Google's 'selected' flag; overrides persist and need no network")
    func visibilityDefaultsAndOverrides() async throws {
        let w = await World()
        let s = await w.start()
        let holiday = try #require(s.calendar(key: Fx.key(Fx.alice, Fx.holiday)))
        let team = try #require(s.calendar(key: Fx.key(Fx.bob, Fx.team)))
        #expect(!s.isVisible(holiday))
        #expect(s.isVisible(team))

        await w.google.clearRequests()
        s.setVisible(holiday, true)
        s.setVisible(team, false)
        await w.settle()
        #expect(await w.requests().isEmpty, "toggling uses events already loaded")

        // A new launch over the same preferences sees the same choices.
        w.makeStore()
        let s2 = await w.start()
        #expect(s2.isVisible(try #require(s2.calendar(key: Fx.key(Fx.alice, Fx.holiday)))))
        #expect(!s2.isVisible(try #require(s2.calendar(key: Fx.key(Fx.bob, Fx.team)))))
        // Keys are account-scoped: hiding Alice's family calendar doesn't hide Carol's.
        s2.setVisible(try #require(s2.calendar(key: Fx.key(Fx.alice, Fx.family))), false)
        #expect(s2.isVisible(try #require(s2.calendar(key: Fx.key(Fx.carol, Fx.family)))))
    }

    @Test("Calendars are grouped by account in sign-in order; primary, then owned, then by name")
    func calendarOrdering() async throws {
        let w = await World()
        await w.google.addCalendar(Fx.alice, Fx.calendar("zeta@group.calendar.google.com", role: "owner", summary: "Zeta"))
        await w.google.addCalendar(Fx.alice, Fx.calendar("acc@group.calendar.google.com", role: "reader", summary: "Écoles"))
        let s = await w.start()
        #expect(s.calendars.map(\.name) == [
            "Alice", "Zeta", "Écoles", "Family", "Holidays in United States",
            "Bob", "Team",
            "Carol", "Family (shared)",
        ])
    }

    @Test("A meeting invited to two of your accounts shows twice; RSVP only touches the copy you answer")
    func crossAccountDuplicateInvite() async throws {
        let w = await World()
        let attendees: [[String: Any]] = [["email": "host@x.com", "organizer": true, "responseStatus": "accepted"],
                                          ["email": Fx.alice, "responseStatus": "needsAction"],
                                          ["email": Fx.bob, "responseStatus": "needsAction"]]
        func copy(_ me: String) -> JSON {
            var a = attendees
            for i in a.indices where a[i]["email"] as? String == me { a[i]["self"] = true }
            return Fx.timed("inv-\(me.prefix(3))", "Board meeting", at(2026, 11, 30, 15), at(2026, 11, 30, 16),
                            ["iCalUID": "board@x.com", "organizer": ["email": "host@x.com"], "attendees": a])
        }
        await w.put(Fx.alice, Fx.alice, copy(Fx.alice))
        await w.put(Fx.bob, Fx.bob, copy(Fx.bob))
        let s = await w.start()
        let copies = s.events.filter { $0.iCalUID == "board@x.com" }
        #expect(copies.count == 2)
        #expect(Set(copies.map(\.accountEmail)) == [Fx.alice, Fx.bob])

        await w.google.clearRequests()
        await s.respond(try #require(copies.first { $0.accountEmail == Fx.alice }), "accepted")
        let patches = await w.requests { $0.method == "PATCH" }
        #expect(patches.count == 1)
        #expect(patches.first?.account == Fx.alice)
        #expect(s.events.first { $0.accountEmail == Fx.alice && $0.iCalUID == "board@x.com" }?.selfResponse == "accepted")
        #expect(s.events.first { $0.accountEmail == Fx.bob && $0.iCalUID == "board@x.com" }?.selfResponse == "needsAction")
    }

    @Test("New events go to the last used calendar, else the first account's primary")
    func defaultWriteCalendar() async throws {
        let w = await World()
        let s = await w.start()
        #expect(s.defaultCalendarKey == Fx.key(Fx.alice, Fx.alice))
        w.defaults.set(Fx.key(Fx.bob, Fx.bob), forKey: CalendarStore.Keys.lastCalendar)
        #expect(s.defaultCalendarKey == Fx.key(Fx.bob, Fx.bob))
        // A read-only calendar is never a default, even if remembered.
        w.defaults.set(Fx.key(Fx.bob, Fx.team), forKey: CalendarStore.Keys.lastCalendar)
        #expect(s.defaultCalendarKey == Fx.key(Fx.alice, Fx.alice))
        // A removed account's calendar falls back too.
        w.defaults.set(Fx.key(Fx.bob, Fx.bob), forKey: CalendarStore.Keys.lastCalendar)
        s.removeAccount(Fx.bob)
        #expect(s.defaultCalendarKey == Fx.key(Fx.alice, Fx.alice))
    }

    @Test("'New event' with only read-only calendars explains why instead of doing nothing")
    func noWritableCalendar() async throws {
        let dave = "dave@x.com"
        let w = await World(accounts: [dave])
        await w.oauth.own(Fx.refreshToken(dave), by: dave)
        await w.google.addCalendar(dave, Fx.calendar(Fx.holiday, role: "reader"))
        let s = await w.start()
        s.beginCreate()
        #expect(s.editorDraft == nil)
        #expect(s.errorMessage?.contains("can be edited") == true)
    }
}

/// Sign-in, token refresh and account lifecycle across several accounts.
@MainActor @Suite("Auth and token lifecycle", .timeLimit(.minutes(1)))
struct AuthTests {
    @Test("Cold start refreshes each account once, with its own refresh token and the app's client")
    func coldStart() async throws {
        let w = await World()
        await w.start()
        let calls = await w.oauth.refreshCalls
        #expect(calls.map(\.refreshToken).sorted() == ["rt-A", "rt-B", "rt-C"])
        #expect(calls.allSatisfy { $0.clientId == Fx.client.clientId && $0.clientSecret == Fx.client.clientSecret })
        #expect(w.store.calendars.count == 7)
    }

    @Test("Access tokens are reused until within 60 s of expiry", arguments: [(3600.0, false), (61.0, false), (59.0, true)])
    func tokenCache(expiresIn: Double, refreshesAgain: Bool) async throws {
        let w = await World()
        await w.oauth.setExpiresIn(expiresIn)
        await w.start()
        let before = await w.oauth.refreshCalls.count
        await w.store.refresh()
        let after = await w.oauth.refreshCalls.count
        #expect((after > before) == refreshesAgain)
    }

    @Test("Concurrent requests for one account share a single refresh; accounts never share tokens")
    func refreshDedupe() async throws {
        let w = await World()
        let s = await w.start()
        w.clock.advance(7200) // every cached token has expired
        let gate = Gate()
        await w.oauth.gate(Fx.alice, gate)
        await w.google.clearRequests()

        let load = Task { await s.loadEvents() }
        try await eventually("Alice's refresh to start") { await w.oauth.refreshCount(for: "rt-A") == 2 }
        await gate.open()
        await load.value

        #expect(await w.oauth.refreshCount(for: "rt-A") == 2)
        #expect(await w.oauth.refreshCount(for: "rt-B") == 2)
        let lists = await w.requests { $0.isEventsList }
        let aliceTokens = Set(lists.filter { $0.account == Fx.alice }.compactMap(\.token))
        #expect(aliceTokens.count == 1, "all of Alice's calendars used the same new token")
        #expect(lists.allSatisfy { $0.token?.contains($0.account ?? "?") == true })
        #expect(lists.count == 7)
    }

    @Test("A rotated refresh token is saved for that account only and used from then on")
    func refreshTokenRotation() async throws {
        let w = await World()
        // Bob is in the middle of the account list, so saving to the wrong slot can't go unnoticed.
        await w.oauth.rotate(Fx.bob, to: "rt-B2")
        await w.start()
        let v = try #require(w.vault.current)
        #expect(v.client == Fx.client)
        #expect(v.accounts.map(\.refreshToken) == ["rt-A", "rt-B2", "rt-C"])
        #expect(v.accounts.map(\.email) == [Fx.alice, Fx.bob, Fx.carol])

        w.clock.advance(7200)
        await w.store.refresh()
        #expect(await w.oauth.refreshCalls.last { $0.refreshToken.hasPrefix("rt-B") }?.refreshToken == "rt-B2")
        #expect(await w.oauth.refreshCount(for: "rt-A") == 2)

        // Next launch reads the rotated token from the vault.
        w.makeStore()
        await w.start()
        #expect(await w.oauth.refreshCount(for: "rt-B2") == 2)
    }

    @Test("No vault write when Google returns the same refresh token")
    func noWriteWithoutRotation() async throws {
        let w = await World()
        await w.start()
        #expect(w.vault.writes.isEmpty)
    }

    @Test("A revoked account is flagged for reconnect while the other accounts keep working")
    func invalidGrantIsolated() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("b1", "Bob old", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()

        await w.oauth.fail(Fx.bob, .invalidGrant)
        w.clock.advance(7200)
        await w.put(Fx.alice, Fx.alice, Fx.timed("a2", "Alice new", at(2026, 11, 27, 11), at(2026, 11, 27, 12)))
        await w.put(Fx.carol, Fx.carol, Fx.timed("c2", "Carol new", at(2026, 11, 27, 13), at(2026, 11, 27, 14)))
        await s.refresh()

        #expect(s.accountIssues[Fx.bob]?.needsReconnect == true)
        #expect(s.accountIssues[Fx.bob]?.message.contains("Reconnect") == true)
        #expect(s.accountIssues[Fx.alice] == nil && s.accountIssues[Fx.carol] == nil)
        #expect(w.eventIds.isSuperset(of: [Fx.id(Fx.alice, Fx.alice, "a2"), Fx.id(Fx.carol, Fx.carol, "c2")]))
        #expect(w.eventIds.contains(Fx.id(Fx.bob, Fx.bob, "b1")), "Bob's last known events stay on screen")
        #expect(s.calendars(for: Fx.bob).count == 2, "Bob's calendars stay listed")
        #expect(s.failedCalendarKeys == [Fx.key(Fx.bob, Fx.bob), Fx.key(Fx.bob, Fx.team)])
        #expect(w.vault.current?.accounts.first { $0.email == Fx.bob }?.refreshToken == "rt-B",
                "the token isn't deleted; the user decides to reconnect or remove")
    }

    @Test("Temporary token-endpoint failures aren't shown as 'reconnect'; a rejected client is",
          arguments: [(FakeOAuth.Failure.server("HTTP 503"), false), (.network, false),
                      (.clientRejected, true), (.invalidGrant, true)])
    func tokenFailureClassification(failure: FakeOAuth.Failure, reconnect: Bool) async throws {
        let w = await World()
        let s = await w.start()
        await w.oauth.fail(Fx.alice, failure)
        w.clock.advance(7200)
        await s.refresh()
        let issue = try #require(s.accountIssues[Fx.alice])
        #expect(issue.needsReconnect == reconnect)
        if !reconnect { #expect(issue.message.hasPrefix("Couldn't reach Google")) }

        // A dead sign-in stays "reconnect" on later refreshes (the calendar-list failure that follows
        // must not downgrade it to "couldn't reach Google").
        await s.refresh()
        #expect(s.accountIssues[Fx.alice]?.needsReconnect == reconnect)

        // Once Google accepts the token again, the warning clears.
        await w.oauth.fail(Fx.alice, nil)
        await s.refresh()
        #expect(s.accountIssues[Fx.alice] == nil)
    }

    @Test("Reconnecting replaces the token, clears the warning and doesn't duplicate the account")
    func reconnect() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("b1", "Bob", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        await w.oauth.fail(Fx.bob, .invalidGrant)
        w.clock.advance(7200)
        await s.refresh()
        #expect(s.accountIssues[Fx.bob]?.needsReconnect == true)

        await w.oauth.fail(Fx.bob, nil)
        await w.oauth.queueSignIn(email: Fx.bob, refreshToken: "rt-B2")
        s.addAccount()
        await w.settle()

        #expect(s.accounts.map(\.email) == [Fx.alice, Fx.bob, Fx.carol])
        #expect(s.accountIssues[Fx.bob] == nil)
        #expect(s.failedCalendarKeys.isEmpty)
        #expect(w.vault.current?.accounts.first { $0.email == Fx.bob }?.refreshToken == "rt-B2")
        #expect(await w.oauth.refreshCount(for: "rt-B2") == 0, "the sign-in's own access token is used")
        #expect(w.eventIds.contains(Fx.id(Fx.bob, Fx.bob, "b1")))
    }

    @Test("Adding an account appends it, saves it, activates the app and loads its calendars")
    func addNewAccount() async throws {
        let w = await World(accounts: [Fx.alice])
        let s = await w.start()
        #expect(s.calendars.count == 3)
        await w.oauth.queueSignIn(email: Fx.bob, refreshToken: "rt-B")
        let gate = Gate()
        await w.oauth.setSignInGate(gate)

        s.addAccount()
        #expect(s.isSigningIn)
        await gate.open()
        await w.settle()

        #expect(!s.isSigningIn)
        #expect(w.activations == 1)
        #expect(s.accounts.map(\.email) == [Fx.alice, Fx.bob])
        #expect(w.vault.current?.accounts.map(\.email) == [Fx.alice, Fx.bob])
        #expect(w.vault.current?.client == Fx.client)
        #expect(s.calendars(for: Fx.bob).count == 2)
        #expect(await w.oauth.refreshCount(for: "rt-B") == 0)
        #expect(await w.oauth.signInClients == [Fx.client.clientId])
    }

    @Test("Starting a second sign-in cancels the first; only the latest one adds an account")
    func concurrentSignInLatestWins() async throws {
        let w = await World(accounts: [Fx.alice])
        let s = await w.start()
        let gate = Gate()
        await w.oauth.setSignInGate(gate)
        await w.oauth.queueSignIn(email: Fx.bob, refreshToken: "rt-B")

        s.addAccount()
        s.addAccount()
        #expect(s.isSigningIn)
        await gate.open()
        await w.settle()
        #expect(s.accounts.map(\.email) == [Fx.alice, Fx.bob])
        #expect(!s.isSigningIn)
        #expect(s.errorMessage == nil, "the cancelled attempt is silent")
    }

    @Test("Cancelling a sign-in discards a late result")
    func cancelSignIn() async throws {
        let w = await World(accounts: [Fx.alice])
        let s = await w.start()
        let gate = Gate()
        await w.oauth.setSignInGate(gate)
        await w.oauth.queueSignIn(email: Fx.bob, refreshToken: "rt-B")
        s.addAccount()
        s.cancelSignIn()
        #expect(!s.isSigningIn)
        await gate.open()
        await w.settle()
        #expect(s.accounts.map(\.email) == [Fx.alice])
        #expect(s.errorMessage == nil)
        #expect(w.vault.writes.isEmpty)
    }

    @Test("A sign-in started under the old OAuth client is discarded after the client changes")
    func staleClientSignInDiscarded() async throws {
        let w = await World(accounts: [])
        let s = await w.start()
        let gate = Gate()
        await w.oauth.setSignInGate(gate)
        await w.oauth.queueSignIn(email: Fx.bob, refreshToken: "rt-B")
        s.addAccount()
        s.saveClient(Fx.otherClient)
        await gate.open()
        await w.settle()
        #expect(s.accounts.isEmpty)
        #expect(w.vault.current?.client == Fx.otherClient)
        #expect(w.vault.current?.accounts.isEmpty == true)
    }

    @Test("Changing the OAuth client signs every account out and revokes each account's own token")
    func clientChange() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("b1", "Planning", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        s.searchText = "planning"
        await s.performSearch()
        #expect(s.searchResults?.count == 1)

        s.saveClient(Fx.otherClient)
        await w.settle()
        #expect(await w.oauth.revoked.sorted() == ["rt-A", "rt-B", "rt-C"])
        #expect(s.accounts.isEmpty && s.calendars.isEmpty && s.events.isEmpty)
        #expect(s.accountIssues.isEmpty && s.failedCalendarKeys.isEmpty)
        #expect(s.searchResults == nil, "no results from signed-out accounts")
        #expect(w.vault.current?.client == Fx.otherClient)
        #expect(w.vault.current?.accounts.isEmpty == true)
        #expect(w.notifier.last?.isEmpty == true)
    }

    @Test("Saving the same client again changes nothing")
    func sameClientNoop() async throws {
        let w = await World()
        let s = await w.start()
        s.saveClient(Fx.client)
        await w.settle()
        #expect(await w.oauth.revoked.isEmpty)
        #expect(s.accounts.count == 3)
    }

    @Test("Removing an account revokes only its token and removes all of its data")
    func removeAccount() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.bob, Fx.timed("b1", "Bob", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        await w.put(Fx.alice, Fx.alice, Fx.timed("a1", "Alice", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        s.searchText = "b"
        await s.performSearch()

        s.removeAccount(Fx.bob)
        await w.settle()
        #expect(await w.oauth.revoked == ["rt-B"])
        #expect(s.calendars(for: Fx.bob).isEmpty)
        #expect(!s.events.contains { $0.accountEmail == Fx.bob })
        #expect(!(s.searchResults ?? []).contains { $0.accountEmail == Fx.bob })
        #expect(w.vault.current?.accounts.map(\.email) == [Fx.alice, Fx.carol])
        #expect(w.notifier.lastIds == [Fx.id(Fx.alice, Fx.alice, "a1")])

        s.removeAccount(Fx.alice)
        s.removeAccount(Fx.carol)
        await w.settle()
        #expect(s.calendars.isEmpty)
        #expect(w.notifier.last?.isEmpty == true)
    }

    @Test("An account removed while its events are loading doesn't come back")
    func removeDuringEventLoad() async throws {
        for failing in [false, true] {
            let w = await World()
            await w.put(Fx.bob, Fx.bob, Fx.timed("b1", "Bob", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
            let gate = Gate()
            await w.google.on({ $0.isEventsList && $0.account == Fx.bob }, always: .gate(gate))
            if failing {
                await w.google.on({ $0.isEventsList && $0.account == Fx.bob }, always: .status(500, googleError(500, "backendError")))
            }
            let s = w.store!
            let boot = Task { await w.start() }
            await w.google.waitFor(where: { $0.isEventsList && $0.account == Fx.bob })
            s.removeAccount(Fx.bob)
            await gate.open()
            _ = await boot.value
            await w.settle()

            #expect(!s.events.contains { $0.accountEmail == Fx.bob }, "failing: \(failing)")
            #expect(s.calendars(for: Fx.bob).isEmpty)
            #expect(s.failedCalendarKeys.allSatisfy { !$0.hasPrefix(Fx.bob) })
        }
    }

    @Test("An account removed while its token is refreshing leaves no ghost warning")
    func removeDuringTokenRefresh() async throws {
        let w = await World()
        let s = await w.start()
        w.clock.advance(7200)
        let gate = Gate()
        await w.oauth.gate(Fx.bob, gate)
        await w.oauth.fail(Fx.bob, .invalidGrant)
        let r = Task { await s.refresh() }
        try await eventually("Bob's refresh") { await w.oauth.refreshCount(for: "rt-B") == 2 }
        s.removeAccount(Fx.bob)
        await gate.open()
        await r.value
        await w.settle()
        #expect(s.accountIssues[Fx.bob] == nil)
        #expect(s.calendars(for: Fx.bob).isEmpty)
    }

    @Test("An account added while an older refresh is in flight keeps its calendars")
    func addDuringRefresh() async throws {
        let dave = "dave@x.com"
        let w = await World(accounts: [Fx.alice])
        await w.google.addCalendar(dave, Fx.calendar(dave, role: "owner", primary: true, summary: "Dave"))
        let s = await w.start()
        let gate = Gate()
        await w.google.on({ $0.segments.first == "users" && $0.account == Fx.alice }, [.gate(gate)])
        await w.google.clearRequests()   // wait for the new refresh's request, not the one from start()
        let old = Task { await s.refresh() }
        await w.google.waitFor(where: { $0.segments.first == "users" && $0.account == Fx.alice })

        await w.oauth.queueSignIn(email: dave, refreshToken: "rt-D")
        s.addAccount()
        try await eventually("Dave's calendars") { s.calendars(for: dave).count == 1 }
        await gate.open()
        await old.value
        await w.settle()
        #expect(s.calendars(for: dave).count == 1)
        #expect(s.calendars(for: Fx.alice).count == 3)
    }

    @Test("A 401 mid-session triggers exactly one refresh for that account and nobody else")
    func unauthorizedMidSession() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("a1", "A", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        await w.google.revokeAccessTokens(of: Fx.alice)
        await s.refresh()
        #expect(await w.oauth.refreshCount(for: "rt-A") == 2)
        #expect(await w.oauth.refreshCount(for: "rt-B") == 1)
        #expect(await w.oauth.refreshCount(for: "rt-C") == 1)
        #expect(w.eventIds.contains(Fx.id(Fx.alice, Fx.alice, "a1")))
        #expect(s.failedCalendarKeys.isEmpty && s.accountIssues.isEmpty)
    }
}

/// What the user sees when part of Google is failing.
@MainActor @Suite("Partial failure and stale data", .timeLimit(.minutes(1)))
struct PartialFailureTests {
    @Test("A failing calendar keeps its last events, is flagged, and is retried with backoff")
    func failingCalendarKeepsStaleCopy() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.team, Fx.timed("t1", "Standup", at(2026, 11, 27, 9), at(2026, 11, 27, 9, 15)))
        let s = await w.start()

        await w.google.on({ $0.isEventsList && $0.calendarId == Fx.team }, always: .status(500, googleError(500, "backendError")))
        await w.put(Fx.alice, Fx.alice, Fx.timed("a1", "New", at(2026, 11, 27, 11), at(2026, 11, 27, 12)))
        await s.refresh()

        #expect(w.eventIds.contains(Fx.id(Fx.bob, Fx.team, "t1")))
        #expect(w.eventIds.contains(Fx.id(Fx.alice, Fx.alice, "a1")))
        #expect(s.failedCalendarKeys == [Fx.key(Fx.bob, Fx.team)])
        #expect(w.sleeps.milliseconds == [500, 1000, 2000])
        #expect(await w.requests { $0.isEventsList && $0.calendarId == Fx.team }.count == 1 + 4)

        // Recovery: the flag clears and server-side deletions show up.
        await w.google.clearRules()
        await w.google.removeEvent(Fx.bob, Fx.team, "t1")
        await s.refresh()
        #expect(s.failedCalendarKeys.isEmpty)
        #expect(!w.eventIds.contains(Fx.id(Fx.bob, Fx.team, "t1")))
    }

    @Test("A calendar failing on the very first load shows nothing for it, but everything else loads")
    func failureOnFirstLoad() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("a1", "A", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        await w.google.on({ $0.isEventsList && $0.calendarId == Fx.team }, always: .transportError(.notConnectedToInternet))
        let s = await w.start()
        #expect(s.failedCalendarKeys == [Fx.key(Fx.bob, Fx.team)])
        #expect(!s.events.contains { $0.calendarKey == Fx.key(Fx.bob, Fx.team) })
        #expect(w.eventIds.contains(Fx.id(Fx.alice, Fx.alice, "a1")))
        #expect(s.loadedWindow != nil)
    }

    @Test("Stale events are only kept inside the new window")
    func staleRetentionHonoursWindow() async throws {
        let w = await World()
        await w.put(Fx.bob, Fx.team, Fx.timed("jul", "July", at(2026, 7, 6, 9), at(2026, 7, 6, 10)))
        await w.put(Fx.bob, Fx.team, Fx.timed("oct", "October", at(2026, 10, 5, 9), at(2026, 10, 5, 10)))
        let s = w.store!
        s.selectedDate = at(2026, 8, 15)
        await w.start()
        #expect(w.eventIds.isSuperset(of: [Fx.id(Fx.bob, Fx.team, "jul"), Fx.id(Fx.bob, Fx.team, "oct")]))

        await w.google.on({ $0.isEventsList && $0.calendarId == Fx.team }, always: .status(503, googleError(503, "backendError")))
        s.selectedDate = T0
        await w.settle()
        #expect(s.loadedWindow?.covers(s.visibleRange) == true)
        #expect(w.eventIds.contains(Fx.id(Fx.bob, Fx.team, "oct")))
        #expect(!w.eventIds.contains(Fx.id(Fx.bob, Fx.team, "jul")))
    }

    @Test("An account whose calendar list fails keeps its calendars and shows a retry warning")
    func calendarListFailure() async throws {
        let w = await World()
        let s = await w.start()
        await w.google.on({ $0.segments.first == "users" && $0.account == Fx.alice }, always: .status(500, googleError(500, "backendError")))
        await w.google.addCalendar(Fx.bob, Fx.calendar("new@group.calendar.google.com", role: "reader", summary: "New"))
        await s.refresh()
        #expect(s.calendars(for: Fx.alice).count == 3)
        #expect(s.calendars(for: Fx.bob).count == 3, "Bob's list still updates")
        let issue = try #require(s.accountIssues[Fx.alice])
        #expect(!issue.needsReconnect)
        #expect(issue.message.hasPrefix("Couldn't reach Google"))

        await w.google.clearRules()
        await s.refresh()
        #expect(s.accountIssues[Fx.alice] == nil)
    }

    @Test("With no previous data, a failed calendar list means no calendars and a warning")
    func calendarListFailureOnFirstLoad() async throws {
        let w = await World()
        await w.google.on({ $0.segments.first == "users" && $0.account == Fx.alice }, always: .transportError(.timedOut))
        let s = await w.start()
        #expect(s.calendars(for: Fx.alice).isEmpty)
        #expect(s.calendars(for: Fx.bob).count == 2)
        #expect(s.accountIssues[Fx.alice]?.needsReconnect == false)
    }

    @Test("A total outage keeps everything on screen and recovers fully")
    func totalOutage() async throws {
        let w = await World()
        await w.put(Fx.alice, Fx.alice, Fx.timed("a1", "A", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        await w.put(Fx.carol, Fx.carol, Fx.timed("c1", "C", at(2026, 11, 27, 9), at(2026, 11, 27, 10)))
        let s = await w.start()
        let before = w.eventIds
        await w.google.on({ _ in true }, always: .transportError(.notConnectedToInternet))
        await s.refresh()
        #expect(w.eventIds == before)
        #expect(Set(s.accountIssues.keys) == [Fx.alice, Fx.bob, Fx.carol])
        #expect(s.failedCalendarKeys.count == 7)
        await w.google.clearRules()
        await s.refresh()
        #expect(s.accountIssues.isEmpty && s.failedCalendarKeys.isEmpty)
        #expect(w.eventIds == before)
    }
}
