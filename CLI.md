# swiftpad-cli

A command-line CryptPad client built on `SwiftPadCore`. It is a macOS debugging and scripting tool: every command signs in, does one thing, prints a one-line result, and exits. Run it with no arguments for the full command list.

## Build

```sh
cd core
swift build -c release
```

The binary is `core/.build/release/swiftpad-cli`. It needs the resource bundle built next to it, `core/.build/release/SwiftPadCore_SwiftPadCore.bundle`, which holds the pinned CryptPad worker. Ship the two together.

The examples below assume:

```sh
SP=core/.build/release/swiftpad-cli
URL=https://cryptpad.example.org
```

## Arguments

Most commands take `<username> <password> <server-url>` first, then their own arguments.

- The password may be `-`. On a terminal you are prompted with hidden input. When piped, the first line of stdin is read. This keeps passwords out of shell history and process listings.
- The server URL is the instance's main origin, as you would type it in a browser. Instances that split origins (api, files, sandbox subdomains) are discovered from the server's own configuration.
- Quote titles and messages that contain spaces.

## Sign in

```sh
$SP signin --anonymous $URL          # is the server reachable and CryptPad-shaped
$SP signin alice - $URL              # authenticated probe, prompts for the password
$SP signup alice - $URL              # create an account, then sign in
```

Accounts with TOTP enabled are detected automatically and prompted for a
code on a terminal. For scripts, pass `--totp <code>` to `signin` or
`interactive`.

## Drive and storage

```sh
$SP drive alice - $URL               # one line per entry: id, channel, href, title
$SP drive tree alice - $URL          # folders, trash, templates
$SP usage alice - $URL               # pinned bytes and plan limit
```

The `channel=` field is the handle every pad command takes.

## Pads

```sh
$SP pad create alice - $URL "Meeting notes" code     # type: pad (default), code, slide, whiteboard
$SP pad share-links alice - $URL <channel>           # edit, view, present, embed URLs
$SP pad content alice - $URL <channel>               # document after chainpad replay
$SP pad content alice - $URL <channel> --raw         # source only, for code and slide pads
$SP pad content alice - $URL <channel> --json > pad.json
$SP pad set alice - $URL <channel> pad.json          # whole-document write, last writer wins
$SP pad edit alice - $URL <channel>                  # open in $EDITOR, save on exit
$SP pad rename alice - $URL <channel> "New title"
$SP pad set-tags alice - $URL <channel> work draft   # whole list; no tags clears
$SP pad get-tags alice - $URL <channel>
$SP pad delete alice - $URL <channel>                # to trash, restorable
$SP pad restore alice - $URL <channel>
$SP pad purge-trash alice - $URL
$SP pad destroy alice - $URL <channel>               # server-side, not recoverable
```

Live views stay open until Ctrl-C:

```sh
$SP pad watch alice - $URL <channel>                 # PATCH line per remote change
$SP pad chat-watch alice - $URL <channel>            # the pad's chat
$SP pad chat-history alice - $URL <channel> 50
$SP pad chat-send alice - $URL <channel> "hello"
```

## Files

```sh
$SP file up alice - $URL ./report.pdf --title "Q3 report"
$SP file get alice - $URL <48-hex-channel> ./out.pdf
```

File channels are 48 hex characters, pad channels 32. Take them from the `channel=` field of `drive`.

## Teams, contacts, messages

```sh
$SP team list alice - $URL
$SP team roster alice - $URL <teamId>
$SP team drive alice - $URL <teamId>
$SP team link-create alice - $URL <teamId> "Invite" member
$SP team link-accept bob - $URL <invite-url>

$SP account info alice - $URL         # your curvePublic and notifications channel
$SP contacts list alice - $URL
$SP contacts request alice - $URL <curvePublic> <notificationsChannel>
$SP contacts accept alice - $URL <curvePublic>

$SP dm history alice - $URL <curvePublic>
$SP dm watch alice - $URL <curvePublic>
$SP dm send alice - $URL <curvePublic> "hello"

$SP notif list alice - $URL
$SP notif watch alice - $URL
```

Things to know:

- Team ids are local to each account. The same team has a different id in each member's `team list`.
- Invite links are bearer capabilities. The URL alone grants access.
- Direct messages have no delete. Whatever you send stays in the history.
- Contact and notification listings are eventually consistent. An empty result right after sign-in is not proof of an empty inbox.

## Calendars

```sh
$SP calendar list alice - $URL
$SP calendar create alice - $URL "Deadlines" "#22aa55"
$SP calendar events alice - $URL <calendarId>
$SP event create alice - $URL <calendarId> "Sprint review" 2026-10-02T14:00 2026-10-02T15:00
$SP event create alice - $URL <calendarId> "Offsite" 2026-10-10        # all-day
$SP event set alice - $URL <calendarId> <eventId> reminders 10,60
$SP event delete alice - $URL <calendarId> <eventId>
```

Times are local, `YYYY-MM-DDTHH:MM`. Recurring events are listed but can only be edited in the web client.

## Settings

```sh
$SP attr get alice - $URL general.autostore
$SP attr set-bool alice - $URL drive.hideDuplicate true
$SP attr clear alice - $URL drive.hideDuplicate
```

Paths are dotted and relative to the account's settings tree.

## Interactive mode

Signing in is the expensive step. For batch work, sign in once and run many commands:

```sh
$SP interactive alice - $URL
swiftpad> drive
swiftpad> pad share-links <channel>
swiftpad> pad delete <channel>
swiftpad> help
swiftpad> exit
```

Inside the session, commands omit the username, password and server URL.

## Output and exit codes

Results go to stdout as one `VERB OK key=value ...` line, or a listing with one entry per line. Progress and diagnostics go to stderr. Fields that a peer could have chosen, such as display names, are quoted so they cannot forge the fields after them.

Exit code 0 is success. Exit code 64 is a usage error. Any other non-zero exit means the operation failed and the reason is on stderr.

## Logging

```sh
SWIFTPAD_LOG=debug $SP drive alice - $URL 2> trace.log
SWIFTPAD_LOG=warn  $SP interactive alice - $URL
```

Levels: `debug`, `info`, `warn`, `error`. Logs never contain passwords or key material; identifiers are shortened hashes.
