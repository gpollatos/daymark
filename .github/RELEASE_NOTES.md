A native macOS app that shows all your Google accounts' calendars in one window. Requires macOS 14
or later; runs on Apple Silicon and Intel Macs.

## Install

1. Download **Daymark-{{VERSION}}.zip** below and double-click it to unzip.
2. Drag **Daymark** into your **Applications** folder.
3. Double-click Daymark. macOS refuses to open it and says it can't verify that the app is free
   of malware, because this build isn't signed with an Apple Developer ID. Click **Done** (or
   **OK**). Then, if you trust it:
   - open **System Settings → Privacy & Security** within about an hour;
   - scroll down to the message about Daymark and click **Open Anyway**;
   - confirm with your password, then click **Open**.

   You only need to do this once per version. If macOS instead says Daymark "is damaged", or
   **Open Anyway** never appears, and you trust this download, run
   `xattr -dr com.apple.quarantine /Applications/Daymark.app` in Terminal and open it again.
4. Follow **"1. Create your Google OAuth client"** and **"3. First launch"** in the
   [README](https://github.com/gpollatos/daymark#1-create-your-google-oauth-client-once). Every user
   needs their own free Google OAuth client.

To look around first without a Google account, run
`open -n /Applications/Daymark.app --args --demo`.

## Good to know

- This build is signed ad hoc, so reminders appear as Daymark's own cards in the top-right corner
  rather than in Notification Center, and macOS may ask for Keychain access again after each
  update. Building Daymark yourself with a free Apple Development certificate avoids both (see
  the README).
- Built by GitHub Actions from the tagged source. The `.sha256` file has the zip's checksum; check
  it with `shasum -a 256 -c Daymark-{{VERSION}}.zip.sha256`.
