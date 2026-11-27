# CLAUDE.md

All project guidance lives in AGENTS.md, so other coding agents see the same rules:

@AGENTS.md

## Claude Code specifics

- **Before saying a change is done:** run `swift test` and check the build has zero warnings.
  After UI changes, also rebuild with `./scripts/build-app.sh --install` and look at the running
  app.
- **Seeing the app:** you can capture Daymark's window with `screencapture -x -o -l <windowID>`.
  Get the window ID from `CGWindowListCopyWindowInfo` (owner name "Daymark"). This needs Screen
  Recording permission for the terminal.
  - Clicks via System Events `click at` are accessibility presses, not mouse events. SwiftUI
    gestures (grid click, drag) need real `CGEvent` mouse events.
  - Don't release a drag or press Save on the user's real events; that writes to their Google
    Calendar.
- **Prompts that wait for the user:**
  - If the app doesn't respond after a rebuild, check for a `SecurityAgent` window. That's a
    Keychain prompt waiting for the user. Tell them; never answer it yourself.
  - The same applies to `codesign` key-access prompts. Let the user run
    `./scripts/build-app.sh --install` themselves when signing needs their approval.
- **Steps for the user:** for anything they must do themselves (signing, Keychain or notification
  prompts, Google Cloud setup), give numbered, click-by-click steps and say what they should see
  when it worked.
