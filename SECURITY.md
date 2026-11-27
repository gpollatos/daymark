# Security policy

Daymark handles Google sign-in tokens and calendar data, so security reports are welcome.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately instead:

1. Go to the repository's **Security** tab.
2. Click **Report a vulnerability**. GitHub's private vulnerability reporting sends it only to
   the maintainer.

Include what you found, how to reproduce it, and the impact you expect. You'll get a reply as
soon as possible. Fixes are released on `main`; there are no separate supported versions.

## What Daymark stores and sends

So you can judge the impact of an issue:

- **Keychain:** your own Google OAuth client (ID and secret) and one refresh token per account.
- **Memory only:** calendar data. The network session keeps no cache or cookies on disk.
- **Network:** requests go only to Google (`accounts.google.com`, `oauth2.googleapis.com`,
  `www.googleapis.com`). Scopes: `openid`, `email`, `calendar.calendarlist.readonly` and
  `calendar.events`.
- **Sign-in:** a one-shot listener on `127.0.0.1` receives Google's redirect, and only accepts the
  request carrying the sign-in's random `state` (with PKCE).

If you think a token or credential of yours has been exposed, revoke Daymark's access at
https://myaccount.google.com/permissions, and reset the client secret in Google Cloud Console.
