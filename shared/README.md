# shared/

What every platform of Muna has in common. Code is not shared between the platforms (each is
written in its own language), so this folder holds what they must agree on.

| Folder | What |
|---|---|
| [`protocols/localsend.md`](protocols/localsend.md) | How Muna sends and receives files (LocalSend v2), who it says it is, groups |
| [`formats/data-files.md`](formats/data-files.md) | The JSON files of notes, to-dos, tray, clipboard and LocalSend groups |
| [`design/colors.json`](design/colors.json) | The colours of the capsule and of the windows (dark and light) |
| [`features.md`](features.md) | Every feature of Muna for GNOME and where macOS and Windows stand |
| [`brand/`](brand) | The Muna mark and the butterfly (SVG); the Linux extension installs them as its `icons/` |
| [`testing/fakels.py`](testing/fakels.py) | A fake LocalSend device for tests: `python3 fakels.py IP ALIAS MODEL FINGERPRINT [accept\|decline] [DELAY]` |

When a platform changes one of these (a new field, a new file), change the description here first
and the other platforms after it.
