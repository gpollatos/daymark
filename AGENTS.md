# AGENTS.md

Guidance for coding agents working on Daymark, a native macOS (SwiftUI) multi-account Google
Calendar client. Read `README.md` for what the app does and how users set it up.

## Commands

```sh
swift build                         # debug build
swift test                          # full suite (< 1 s); must stay green
swift test --filter WriteTests      # one suite (filter by type name, not display name)
TZ=Pacific/Auckland swift test      # also run under another zone when touching dates
./scripts/build-app.sh              # release .app in build/ (signs with Apple Development cert if present)
./scripts/build-app.sh --install    # …and copy to /Applications
```

- Swift tools 5.10, Swift 5 language mode, macOS 14+.
- Keep the build free of warnings, including in tests. CI (`.github/workflows/test.yml`) builds
  with `-warnings-as-errors`.
- Releases: pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`. It tests, builds a
  universal ad-hoc app (`DAYMARK_UNIVERSAL=1 DAYMARK_SIGN=adhoc DAYMARK_VERSION=…`), checks that
  no builder paths are left in it, and creates a **draft** release with
  `.github/RELEASE_NOTES.md`. Publish the draft after checking it. Never attach a locally built
  app: it's signed with a personal certificate and built from your own folders.
- There is no Xcode project; SwiftPM only. The `.app` bundle is assembled by `scripts/build-app.sh`
  from `Resources/Info.plist`.

## Architecture in one minute

- **`CalendarStore`** (`Sources/Daymark/Store`) is the single `@MainActor @Observable` state
  object. It holds:
  - accounts, calendars and events, all in memory only;
  - navigation and loading windows;
  - writes: save, move, delete, RSVP;
  - search;
  - reminder scheduling.
- **Views** read the store from the environment and stay thin. Logic that needs testing lives in
  pure helpers:
  - `Model/EventDraft.swift`: editor mutators and the guest-email rule (`savingNotifiesGuests`);
  - `Layout/`: `SlotPicker` and `EventMover` (grid click, drag and move), `DayLayout`, `DayAgenda`;
  - `Support/`: `Fmt` (dates and text), `RFC3339`, `SafeLink`;
  - `Notifier.plan` and `Notifier.due` (reminders);
  - `CalendarStore` statics such as `visibleRange`, `fetchWindow`, `title` and `defaultStart`.
- **Files are named after what they hold.** Put new types in the folder for their layer
  (`API/`, `Auth/`, `Model/`, `Layout/`, `Support/`, `Store/`, `Views/`), not in a catch-all file.
- **Dependencies are injected** through `AppEnvironment` (`Sources/Daymark/App/Environment.swift`):
  clock, calendar, preferences, vault storage, OAuth backend, HTTP transport, sleep and jitter,
  reminder sink, app activation, and the background-work switch. `.live` is the real app.
- **`GoogleCalendarAPI`:** one value per account. It does retries with backoff (429, 403 rate
  limits, 5xx; never a POST on 5xx), refreshes once on 401, follows pagination, and
  percent-encodes path segments (calendar IDs can contain `#`).
- **Auth:** `OAuthService` handles PKCE and the loopback redirect via `LoopbackServer`. Refresh
  tokens and the OAuth client live in one Keychain item (`Vault`).
- **Reminders:** `Notifier` uses Notification Center when macOS allows it (the app must be signed
  with an Apple Development certificate). Otherwise it shows `ReminderWindows` cards.

## Rules that keep the app correct

1. **Every request for an account's data uses that account's token**, via `api(for: event.accountEmail)`
   or `api(for: calendar.accountEmail)`. Calendar IDs are not unique across accounts: the key is
   `email|calendarId`, and event IDs are `email|calendarId|eventId`.
2. **PATCH only what changed.** Edits diff against `EventDraft.existing`. RSVP sends only the
   user's own attendee with `attendeesOmitted: true`. Never send back the full attendee list
   unless the user is the organiser and changed the guests.
3. **`sendUpdates`** (one rule each, used by both the request and the UI: `EventDraft.savingNotifiesGuests`
   and `CalendarEvent.deletionNotifiesGuests`):
   - `all` for invites, organiser changes or cancellations with guests, and RSVPs;
   - `none` otherwise.
   Rooms (`resource: true`) don't count as guests.
4. **One account failing must not affect the others.** A failed calendar keeps its last events
   (`failedCalendarKeys`) and its last reminders. `accountIssues[...].needsReconnect` is true only
   for `invalid_grant` or a rejected client, never for network or 5xx errors.
5. **Nothing private on disk outside the Keychain.**
   - Network calls go through `HTTP.session`, which is ephemeral: no URL cache, cookies or
     credential storage. `URLSession.shared` would cache event JSON and `Authorization` headers
     in `~/Library/Caches`.
   - No logging of tokens, event data or emails.
   - Preferences are limited to the three keys in `CalendarStore.Keys`.
6. **Links from event data are untrusted.** Open them only via `SafeLink` (http/https). The same
   goes for links made clickable in descriptions (`Fmt.linkified`).
7. **OAuth:**
   - Keep the scopes minimal (`calendar.calendarlist.readonly` + `calendar.events`).
   - The loopback server only accepts the callback whose `state` matches.
   - Replacing or removing a refresh token revokes the old one.
8. **Never overwrite an unreadable vault.** If the Keychain read fails, `vaultUnreadable` blocks
   every write.
9. **Dates:**
   - All-day events use exclusive end dates on the wire; the editor shows the last day inclusive.
   - Use calendar arithmetic (`date(byAdding: .day…)`), never `+ 86400`.
   - Grid positions are wall-clock minutes, so they stay right on DST days.
   - Pure helpers take a `Calendar` (and `Locale` for text) parameter, and tests always pass one.
     Views may rely on the `.current` defaults.
10. **Concurrency:**
   - Background work goes through `CalendarStore.spawn`, so tests can `await store.settle()`.
   - Stale results are discarded with generation counters (loads, searches, reminders), and
     results are re-filtered against the live accounts and calendars after every `await`.
   - Any path that forgets data (no accounts, client change, last account removed) goes
     through `resetData()`, which also invalidates work still in flight.
   - Navigation reuses an in-flight load whose window already covers the new view
     (`pendingWindow`).

- `CalendarEvent.attendees` is the wire type `[AttendeeDTO]` on purpose: an organiser's guest
  edit sends the existing records back unchanged.

## Tests: how to write them

- **Store-level tests** build a `World` (`Tests/DaymarkTests/Support/World.swift`): three accounts
  (Alice, Bob, Carol) at 2026-11-26 12:00 America/New_York, Sunday-first weeks. Make requests with
  `await w.start()`, then assert on `w.google.requests`, `w.oauth.refreshCalls`, `w.vault`,
  `w.notifier`.
- **`FakeGoogle` behaves like the real API:**
  - It returns 401 for unknown tokens and 404 for another account's calendar.
  - It paginates, filters by `timeMin`/`timeMax`/`q`, and applies POST, PATCH and DELETE.
  - It rejects unknown query parameters.
  - Use `on(match, [actions], always:)` for failures and `Gate` to hold a request mid-flight.
  - Call `clearRequests()` before waiting with `waitFor`, so earlier requests don't satisfy it.
- **No real sleeps for correctness.** Use gates, `waitFor`, `settle()`, or the injected `sleep`
  (`SleepRecorder`). Gates and waits expire after 10 s and record a failure, so a bug fails fast
  instead of hanging.
- **Never use the real Keychain, network, `UserDefaults` or `NSApp` in tests.** Everything goes
  through `AppEnvironment`. `World` uses `MemoryPreferences`, `MemoryVault`, `FakeGoogle` and
  `FakeOAuth`, so a test run writes nothing to disk.
- **Assert real behaviour, never what the test built itself.** Prefer exact request shapes:
  method, encoded path, query, body keys. Parameterize across accounts when routing matters.
- **New behaviour needs a test that fails if the behaviour is removed.** Check it by breaking the
  line deliberately and running the suite.

## Demo mode

`open -n /Applications/Daymark.app --args --demo` (or `DAYMARK_DEMO=1`) runs the real app with
`AppEnvironment.demo`: three fictional accounts on reserved `example` domains, and an in-memory
fake Google seeded with a week of events around today (`App/DemoMode.swift`). Use it to check UI
changes and to take screenshots. **Never put real people, emails or meetings in screenshots,
fixtures or docs; use demo mode.**

## UI changes

- SwiftUI views aren't unit-tested. After UI work, build and run the app
  (`./scripts/build-app.sh --install`), preferably in demo mode, and check the change visually.
- A rebuild signed ad hoc makes macOS show a Keychain access prompt that blocks the app until the
  user answers. Never click security prompts on the user's behalf.
- When checking interactions manually, don't drag, edit or delete the user's real events: writes
  go to their live Google Calendar.

## Don'ts

- Don't add a database or any persistence beyond the Keychain vault and small `UserDefaults`
  preferences. This is a deliberate product decision.
- Don't commit OAuth client IDs, secrets, downloaded client JSON, tokens, or `build/`.
- Don't add third-party dependencies without a strong reason. The app uses only Apple frameworks.
