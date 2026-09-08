# Per-account OAuth sign-in

Date: 2026-09-08
Status: approved, not yet implemented

## Problem

The app authenticates an account three ways: a pasted claude.ai `sessionKey`
cookie, a pasted `sk-ant-oat` setup token, or by reading the OAuth tokens
Claude Code stores in the login keychain.

The keychain route fails on both counts it was added for:

1. **It prompts.** Those items are ACL-restricted to the `claude` binary, so
   every read asks for the login password.
2. **It only ever covers one account.** Claude Code holds a single login, so
   accounts two and three have nothing to read.

The cookie route works for every account but has to be re-done by hand
whenever the cookie rotates, needs an organization ID lookup that can fail,
and sits behind the bot challenge fronting claude.ai.

## Solution

Give each account its own OAuth authorization, obtained by signing in through
the browser, with its own access and refresh token stored in the app's own
keychain items. Nothing is read from another application, so nothing prompts,
and accounts are independent of each other and of Claude Code.

Whatever login the account normally uses works, Google included, because the
sign-in happens on Anthropic's own login page.

## Endpoints

Extracted from the Claude Code binary, version 2.1.263.

| Purpose | URL |
|---|---|
| Authorize | `https://claude.com/cai/oauth/authorize` |
| Token exchange and refresh | `https://platform.claude.com/v1/oauth/token` |
| Paste-back callback | `https://platform.claude.com/oauth/code/callback` |
| Usage | `https://api.anthropic.com/api/oauth/usage` |
| Profile | `https://api.anthropic.com/api/oauth/profile` |

PKCE with S256. Scopes `user:profile user:inference`. Client id
`9d1c250a-e61b-44d9-88ed-5944d1962f5e`.

Anthropic publishes no client registration for third-party applications:
`.well-known/oauth-authorization-server` is absent on both hosts. The app
therefore uses Claude Code's public client id. This works and is what every
third-party Claude tool does, but it is unofficial and Anthropic can revoke
it. The cookie path is retained as the escape hatch for that day.

## Architecture

A new `app/Auth/` directory, four files, none importing AppKit or SwiftUI so
the test target compiles them unchanged.

| File | Owns |
|---|---|
| `OAuthClient.swift` | Endpoints, PKCE verifier and challenge, authorize URL, code exchange, refresh. Pure request and response. |
| `TokenStore.swift` | Keychain read, write, delete of one token set per account UUID. Service `com.hazime.claudeusagemulti.oauth`. |
| `LoopbackCallbackServer.swift` | One-shot `NWListener` on an ephemeral port. Captures `code` and `state`, serves a close-this-tab page, times out after 5 minutes. |
| `CredentialProvider.swift` | Returns a valid access token for an account, refreshing under a 5 minute expiry window, collapsing concurrent callers into one refresh, publishing `needsReauth`. |

`build.sh` gains `Auth/*.swift` in both `swiftc` invocations.

### Why single-flight

Usage, profile, and a 401 retry can all fire for one account at once. Two
concurrent refreshes would each rotate the refresh token, and the second write
would persist a token the server has already invalidated, costing the user a
re-sign-in. `CredentialProvider` serialises refreshes per account and hands
every waiting caller the same result.

## Sign-in flow

1. User clicks **Sign in with Claude** on an account row.
2. App generates a verifier and a random state, starts the loopback listener.
3. Default browser opens at the authorize URL.
4. User signs in with whatever method that account uses.
5. Redirect hits the loopback. State is compared; a mismatch aborts.
6. Code plus verifier exchange for tokens. Tokens go to the keychain.
7. `/api/oauth/profile` resolves the email and stamps it on the account.

A paste field sits below, permanently visible, for adding a second account
from a private window, since claude.ai has no account switcher and the browser
is already signed in as the first account. It accepts a bare code, a
`code#state` pair, or the full redirect URL.

## Token storage

One keychain item per account, JSON-encoded, holding access token, refresh
token, expiry, scope and email, with `kSecAttrAccessibleAfterFirstUnlock`.

No token-shaped value stays in UserDefaults. The session cookie moves into the
same keychain item, so `Account` keeps only the UUID, the name, the emoji, the
colour, the email for display, and a `usesOAuth` flag. This also removes
today's situation where the cookie and setup token sit in plaintext in the
preferences plist.

Refresh rotates the refresh token, so the keychain write is the commit point.
New tokens are written before the old ones are treated as spent, and a failed
write aborts the refresh rather than leaving an account holding a token it
cannot renew.

### Build change this forces

`build.sh` signs with the Developer ID, then re-signs ad-hoc after copying to
`/Applications`, which downgrades a properly signed app and leaves it with no
stable identity. Keychain ACLs key off the code signature, so macOS would
prompt on every rebuild. The install step drops the ad-hoc re-sign. This is a
correctness fix independent of OAuth.

## Failure handling

A refresh failure, or a 401 surviving one retry, marks the account
`needsReauth`:

- a **Sign in again** button on its row
- its emoji dimmed in the menu bar
- exactly one notification, tracked so it does not repeat until the account
  recovers

If the account still holds a session cookie, the app falls back to it silently
so the numbers keep updating, and the row says so in one line. Other accounts
are unaffected.

## Migration

On first launch after the update:

- Accounts bound to a Claude Code keychain item lose the binding and land in
  `needsReauth`. Their token cannot be carried over: refreshing it rotates
  Claude Code's own refresh token and signs the CLI out.
- Accounts with a pasted `sk-ant-oat` setup token keep working. Those are
  long-lived and need no refresh, so they move into the keychain as-is and
  count as a valid credential with no refresh token.
- Cookie-only accounts keep working. Their cookie moves from UserDefaults into
  the account's keychain item on first launch and is cleared from the plist.

## Removed

`ClaudeCodeKeychain` and everything built on it: discovery ranking, the
read-prompt budget, and Claude Code account-switch detection.

Retained but unadvertised in the UI: the cookie fetch path, organization ID
lookup, and bot-challenge handling.

## Testing

`Package.swift` declaring a library target at `app/Auth` and a swift-testing
target. `test.sh` runs `swift test`. The app build stays on `swiftc`.

Covered:

- PKCE challenge derived from a known verifier
- state mismatch rejected
- refresh window boundary, either side of 5 minutes
- callback parsing for a bare code, `code#state`, and a full URL
- token JSON decode, including a response with no refresh token
- keychain write, read, delete round trip

## Verified live before the bulk of the work

Both need a real signed-in browser, so they are implemented and tested first.

1. Whether the authorize page accepts an arbitrary loopback port. If it is
   restricted, the loopback becomes fixed-port and the paste flow covers the
   rest.
2. Whether `/api/oauth/usage` accepts `user:profile user:inference`. If not,
   scopes widen to match what the CLI requests.
