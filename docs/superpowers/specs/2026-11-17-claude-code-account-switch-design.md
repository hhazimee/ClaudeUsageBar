# Switch Claude Code accounts from the app

Date: 2026-11-17

## Why

Haz runs several Claude accounts and many Claude Code sessions at once. Today, moving Claude Code to another account means `/logout` and `/login`. He wants one click in the app, from the popup or the menu bar, and every running session follows.

## Goals

- Switch the account Claude Code uses with one click from a popup card or the menu bar right-click menu.
- Running sessions follow without a restart (Claude Code re-reads the Keychain within about 30 seconds).
- Show at a glance which account Claude Code is on.
- No `/logout` needed, ever.

## Non-goals

- Automatic switching at a usage threshold. Switching is by hand only.
- Running two accounts at once in different terminals.
- Supporting `CLAUDE_CONFIG_DIR` profiles. Only the default `~/.claude` setup.

## Anti-goals

- Breaking MCP logins. The Claude Code Keychain item also holds `mcpOAuth` tokens for every MCP server. A switch that overwrites them logs Haz out of all of them.
- Losing a login to token rotation. Claude Code renews its refresh token while it runs, so a saved copy goes stale. A switch must never write a stale copy back over a newer one.
- Sharing a grant between the app and Claude Code. The app's own per-account OAuth grants stay separate. Two clients refreshing one grant sign each other out (this is why the earlier Claude Code binding was removed).

## How Claude Code stores its login (checked on this Mac)

- Keychain generic password, service `Claude Code-credentials`, account = macOS username. JSON with:
  - `claudeAiOauth`: `accessToken`, `refreshToken`, `expiresAt`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType`, `subscriptionTypeSource`, `rateLimitTier`
  - `mcpOAuth`: tokens for MCP servers. Not account-specific. Never touched.
- `~/.claude.json`, key `oauthAccount`: `emailAddress`, `accountUuid`, `organizationUuid`, plan and org fields. Claude Code shows and uses this as the signed-in account.
- Other items exist (`Claude Code-credentials-<hash>`, and one with account `unknown`). They belong to other config dirs and are ignored.

## Approaches

1. **Built into the app (chosen).** The app keeps a copy of each account's Claude Code login in its existing encrypted `CredentialStore` and swaps it into the Keychain and `~/.claude.json` on click. No extra install.
2. **Call claude-swap.** Less code, but needs a Python tool installed and kept working, and couples the app to its CLI output.
3. **Reuse the app's own sign-in.** Rejected: one grant refreshed by two clients signs both out.

Haz picked 1.

## Design

### Data

- Each account's `StoredCredential` gains an optional `claudeCode` field: the `claudeAiOauth` JSON object (kept as raw JSON so unknown fields survive) and the `oauthAccount` JSON object.
- `Account` gains `hasClaudeCodeLogin: Bool` (default false) so rows draw without decrypting.

### Capture (automatic)

- On launch, on every 5-minute refresh, and when the popup opens: read the live `claudeAiOauth` and `oauthAccount.emailAddress` (plus `accountUuid`).
- Match to an app account by `accountUUID` first, then by `accountEmail` (case-insensitive).
- On a match, save the live login into that account's `claudeCode` field. This keeps the active account's copy current as Claude Code rotates tokens.
- No match: nothing saved, no badge.

### Switch

On click of account B while Claude Code is on account A:

1. Read the live Keychain item and `~/.claude.json`.
2. Capture: save the live login to A (the matched account), so A's newest refresh token is kept.
3. Write B's `claudeAiOauth` into the Keychain item, keeping the item's `mcpOAuth` and any other top-level keys exactly as read.
4. Write B's `oauthAccount` into `~/.claude.json`: read, replace only that key, write atomically. Every other key is preserved.
5. Update the badge and pill marker.

If any step fails, stop, leave Claude Code as it was where possible, and show the error on B's card.

### UI

- **Popup card header:** a "Claude Code" badge on the active account. A **Switch** button on every other account. Disabled when the account has no saved login; hover text: "Log in to Claude Code as this account once".
- **Menu bar pill:** a small marker on the active account's pill.
- **Right-click menu:** a "Claude Code" section listing accounts, a check on the active one, disabled rows for accounts without a saved login. Clicking switches. Then "Toggle Usage ⌘U" and "Quit".
- No confirmation dialog or toast after a switch.

### Permissions

The first read of `Claude Code-credentials` makes macOS ask for the login password. Haz picks "Always Allow". Builds are signed with a stable certificate, so this sticks across rebuilds.

## Constraints

- Swift/SwiftUI app, macOS 12+, not sandboxed. Built with `app/build.sh`.
- Keychain and file code goes in `app/Auth/` so the `ClaudeUsageAuth` package target can test it. Keychain and file access sit behind protocols so tests use fakes.
- UI follows the existing card and pill components.

## Safety rules (my calls after review)

- **Confirm whose tokens they are before saving.** `claudeAiOauth` carries no email, and `~/.claude.json` can disagree with the Keychain. Capture calls the OAuth profile endpoint with the live access token and saves only when the returned account id matches the target account. If the call fails, skip this capture; never guess.
- **Check after a switch.** A running session may renew the old account and write it back, to the Keychain or to `~/.claude.json`. About 60 seconds after a switch, re-read both. If either moved back to A, capture A (confirmed as above) and write B again, once. If it moves back a second time, show "A running session switched back" on B's card and stop.
- **Unknown login, no switch (Haz's call).** If Claude Code is logged in as an email that matches no app account, Switch is disabled everywhere and the popup shows one line: "Claude Code is on <email>, which isn't in your accounts". Nothing is saved or overwritten.
- **No Keychain item, no switch.** If `Claude Code-credentials` is missing, Switch is disabled. The app never creates the item, because an item created by the app would carry the wrong access rights for Claude Code.

## Left to the builder

- Exact file split inside `app/Auth/`.
- Badge and marker styling, within the existing look.
- How often capture runs beyond the triggers above.
