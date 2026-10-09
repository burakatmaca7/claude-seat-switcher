# Claude Seat Switcher

> **Unofficial.** This project is not affiliated with, endorsed by, or supported by Anthropic.
> "Claude" is a trademark of Anthropic, PBC.

A macOS menu bar app for people who work in **Claude Desktop** with more than one account or
**Claude Team seat**. See every account's usage at a glance, get warned before you hit a limit,
and jump to another account's window without logging out.

**Status: early development — nothing to install yet.**

## Planned features

- **All accounts in the menu bar** — 5-hour session and weekly usage per account, with reset times.
- **Limit alerts** — a notification when an account nears its limit, suggesting the account with the most room left.
- **One window per account** — each account runs in its own Claude Desktop window and stays signed in. Click to switch.
- **Shared chat history** — conversations started in one account show up in the others, so you can continue where you left off.
- **Automation accounts** — mark an account used by scripts or `claude -p` jobs; it is never suggested for interactive work, and you are told when it hits its limit.
- **Custom status lines** — drop a small script into a folder to add your own line to the menu.

## Privacy and security principles

These are design rules, not aspirations. A change that breaks one of them will not be merged.

1. **Everything runs on your Mac.** There is no server, no account, no analytics, no telemetry.
2. **Credentials never leave your Keychain** except to Anthropic's own endpoints, to read usage and keep sign-ins fresh.
3. **The app talks to Anthropic only.** All network calls live in one file so they are easy to audit.
4. **Your Claude sign-ins are never overwritten.** Each account keeps its own separate profile.
5. **History sync never deletes or overwrites.** It takes a backup first, and every change can be undone.

## Install

Not available yet. Releases will be published on GitHub, with a Homebrew tap and build-from-source instructions.
Builds will be unsigned at first: macOS will ask you to allow the app once under
**System Settings → Privacy & Security → Open Anyway**. Building from source avoids that prompt.

## Credits

The approach builds on ideas from these open-source projects:
[guise](https://github.com/siddhjagani/guise) (one Claude Desktop profile per account),
[meld](https://github.com/siddhjagani/meld) (shared session history),
[claude-swap](https://github.com/realiti4/claude-swap) and
[CodexBar](https://github.com/steipete/CodexBar) (usage tracking).
No code is copied from them.

## License

[MIT](LICENSE)
