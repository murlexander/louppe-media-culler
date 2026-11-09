# Local review builds

Local installs replace the single `/Applications/Louppe.app` through
`Scripts/install_local.sh`. Build a separate review copy only when the owner
explicitly asks for one. It has its own identity, so its folder grants, pins and
Recents don't carry over: tell him beforehand that anything he pins there must be
reconnected in the official app.

Build it with full Xcode and the current SDK:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build_review.sh
open -g "dist/louppe - to review.app" --args -openFolder /path/to/disposable/photos
```

The script creates `dist/louppe - to review.app` and its ZIP, using the version
in `VERSION`. Its identifier is `com.alexandermarkin.louppe.review2`; preferences,
recents, and window state are separate from the stable app. Automatic updates
are disabled, and the review copy does not advertise a duplicate Finder service.
Verification checks a clean local-volume copy of the exact loose output and an
independently unpacked archive, comparing their complete Contents trees. This
avoids File Provider reattaching Finder metadata during signature verification.

Both apps use `.louppe_session.json`. Opening the same folder shares decisions;
use disposable copies of media. 1.11 saves format 7, which 1.10 cannot read.
Keep saved-session copies before evaluating a downgrade.

Run the affected tests and the checks in [AGENTS.md](../AGENTS.md), and launch
with `-openFolder`. Report the source revision, results, explicit skips and
native acceptance limits in your reply or commit message, not in this file.
