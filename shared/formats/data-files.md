# Muna's data files

Every platform keeps the user's data in small JSON files with the same names and shapes, so they
can be copied from one computer to another.

| Platform | Folder |
|---|---|
| Linux | `~/.local/share/muna/` |
| macOS | `~/Library/Application Support/Muna/` |
| Windows (later) | `%APPDATA%\Muna\` |

Rules for every file:

- One JSON object with `"version": 1` and the data. A file that is missing or broken is treated as
  empty.
- Written whole and atomically (write a temporary file, then rename), readable only by the user.
- Times are milliseconds since 1970 (UTC). Ids are integers unless said otherwise.

## notes.json

```json
{"version": 1, "notes": [{"id": 3, "text": "Call the bank", "at": 1764060000000, "private": false}]}
```

Newest first. `text` at most 1000 characters. `private`: shown only after the fingerprint (Linux) /
Touch ID (macOS) check. A new note gets the highest id + 1.

## todo.json

```json
{"version": 1, "items": [{"id": 1, "text": "Send the report", "done": false}]}
```

In the order they were added; "clear done" removes the done ones.

## tray.json

```json
{"version": 1, "files": ["file:///home/me/Downloads/plan.pdf"]}
```

The files waiting in the Tray, as `file://` URIs (they are references, not copies). Only kept
between sessions when the user chose to keep the tray; otherwise `files` is empty. URIs of files
that no longer exist are dropped when loading.

## clipboard.json

```json
{"version": 1, "items": [
  {"text": "hello", "files": null, "saved": true, "note": "", "private": false, "at": 1764060000000},
  {"text": null, "files": ["file:///home/me/a.png"], "saved": false, "note": "", "private": false, "at": 1764060001000}
]}
```

Newest first. An item is text **or** files. `saved` (pinned) items are always kept (at most 100);
the others only when the user keeps the history, up to their chosen count. `note`: the user's label.
`private`: as for notes.

## localsend-groups.json

```json
{"version": 1, "groups": [
  {"id": "gmwvtguh3md", "name": "Office", "members": [
    {"fingerprint": "6f1c…", "alias": "anvar-pc", "deviceModel": "Muna", "deviceType": "desktop"}
  ]}
]}
```

`id`: a short random string. `name`: at most 60 characters, unique without regard to case (saving
a group with an existing name replaces it). At most 50 groups, 200 members each. A member is kept
by who it is, not where it is (no address). How members are matched: see
[`../protocols/localsend.md`](../protocols/localsend.md#groups).

## reminders.json

```json
{"version": 1, "reminders": [
  {"id": 1, "text": "Call mum", "at": 1764060000000, "done": false}
]}
```

`at`: when the reminder is shown (ms since 1970): the chosen time today, or tomorrow if it has
passed. A reminder is removed once shown; one whose time passed while Muna was closed is shown
at the next start. A broken entry is skipped.

## focus.json

```json
{"version": 1,
 "stopwatch": {"state": "running", "since": 1764060000000, "elapsed": 12000, "laps": [5000, 9000]},
 "pomo": {"state": "running", "phase": "work", "endAt": 1764061500000, "remaining": 1500000,
          "round": 1, "done": 0, "config": {"work": 25, "short": 5, "long": 15, "every": 4}}}
```

`state`: `idle`, `running` or `paused`. Stopwatch: `since` is when it last started (ms since
1970), `elapsed` the ms before that, `laps` the totals at each lap (at most 50). Focus timer:
`phase` is `work`, `break` or `long`; `endAt` (ms since 1970) counts while running, `remaining`
(ms) while paused or idle; `done`: work phases finished; a long break comes after every `every`
of them. Minutes are kept within work 1–180, short 1–60, long 1–120, every 2–10. A timer that
ran out while Muna was closed starts again idle.

## snippets.json

```json
{"version": 1, "snippets": [
  {"trigger": ";mail", "text": "me@example.com"},
  {"trigger": ";today", "text": "Written on {date} at {time}"}
]}
```

Newest first, at most 200. `trigger`: what is typed in the command bar, unique (saving one with an
existing trigger replaces it). `text`: at most 5000 characters; when pasted, `{date}` (2026-11-25),
`{time}` (14:05) and `{datetime}` (both) become the local date and time.
