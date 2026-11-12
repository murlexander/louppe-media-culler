# Louppe Media Culler — guidance for AI assistants

Native macOS photo- and video-culling app. Swift/SwiftUI, plain SwiftPM
executable — **no Xcode project** — built with full Xcode and the current macOS
SDK. The owner, Alex Markin, is a photographer, not a programmer: do the
technical work for him, explain results in plain language, and show visible
changes as pictures. There is no support team; the UI says “Contact Alex”
(`a@alex-markin.com`), never “Contact support”.

## Entry points

Use these instead of hand-written command chains. They pin full Xcode and its
SDK, keep build products outside the iCloud/File Provider folder, keep the real
exit code, and never take the user's focus.

| Task | Command |
| --- | --- |
| Toolchain, git and desktop state (read-only) | `Scripts/doctor.sh` |
| Tests | `Scripts/test.sh --filter <regex>` · `--gates` · `--full` |
| Install the local build | `Scripts/install_local.sh` |
| Screenshots of UI states | `Scripts/capture_ui.sh --topic <name> [<scenario>…]` (`--list`, `--pair A B`) |
| Louppe copies on this Mac | `Scripts/list_louppe_copies.sh` (lists, never deletes) |
| Release packaging | `build_app.sh`, `Scripts/verify_release.sh`, then [Updates](Docs/UPDATES.md) and [App Store](Docs/APP_STORE.md) |

- Start with `Scripts/doctor.sh`: it reports uncommitted files, running Louppe
  copies, screen lock and permissions. Probe; don't assume from old notes.
- `--gates` runs the four suites required before **every** local install,
  including unrelated UI edits: `HotkeyTests` (real AppKit events and monitor
  detach/reattach; direct `handleKey` tests are not enough), `BrowserScrollTests`,
  `GridScrollTests` and `PersistentVerticalScrollerTests`. Before changing
  concurrency, caching, scanning, filtering, decoding, persistence or Clean Up,
  also run `Tests/run_performance_checks.sh`.
- Tests that activate the app or make windows key call `requireForegroundUI()`
  and run only with `Scripts/test.sh --foreground` (CI sets
  `LOUPPE_FOREGROUND_UI=1`). Use it only while the owner has handed over the
  desktop; otherwise report those suites as “not run”, never as passed.
  `SourceConventionsTests` fails a test file that makes those calls without the
  gate. New test windows go offscreen (−20000, −20000), as in `HotkeyTests`.
- `install_local.sh` is the only install path. It runs the gates, builds,
  verifies the signature outside iCloud, accepts only the bundle ID
  `com.alexandermarkin.louppe`, keeps the previous copy for rollback, and checks
  a background launch on disposable media. It stops if Louppe is running; quit
  a background copy with `--quit-running` only after the owner agrees, and never
  a frontmost one. That launch check is the required “the app
  launches” verification; don't open the app in the foreground for it. For
  manual launches use `-openFolder <disposable folder>`; Dock and Finder opens
  go through the `public.folder` document type, so check those separately.
- There is one installed app, `/Applications/Louppe.app`. “A separate build”
  means a branch or ZIP, never a second bundle identifier or installed copy. An
  isolated review identity exists only when the owner asks
  ([review builds](Docs/REVIEW_BUILD.md)).
- Clean up only build products this session created. Installed apps,
  `dist/release-preparation/`, media-library material and other checkouts'
  builds stay; list them with `list_louppe_copies.sh` and ask.
- If the main window is missing, check Settings and the Window menu first. Never
  reset preferences or window state without approval.

## Working alongside other agents

The owner and several agents often work on this checkout at the same time.

- Run `git status --short` before editing. Changes you didn't make belong to
  someone else: never reset, restore, stash, reformat or commit them.
- Parallel writers each use an isolated checkout outside iCloud (not in
  `/private/tmp`, which is wiped at restart), for example
  `git worktree add --detach ~/.louppe-worktrees/<name> HEAD`, and hand back
  a patch. One integrator applies it and runs the gates once on the integrated
  tree; remove the worktree after its patch lands. A branch started from `HEAD`
  lacks other sessions' uncommitted work: say so before relying on it.
- Never copy a checkout together with `.git`, and never run git inside such a
  copy.
- One build owner per build directory (`test.sh` holds a lock). Don't edit
  files while another agent's build reads them; wait or use a worktree.
- Implementers run focused suites plus `--gates` on their own tree. The
  integrator runs `--full` once per integrated state and reuses that result when
  later changes touch only docs.
- Release, Store and marketing artifacts come from a committed SHA, never from
  a dirty tree.

## Engineering approach

- Compact native controls, direct editing, minimal UI. Add abstractions only
  for concrete needs; reuse existing state owners and documented bridges.
- Prefer the most modern native macOS controls and presentation on the running
  system: system containers and adaptive styles, not recreated older looks.
  Preserve supported older macOS versions with availability-gated fallbacks
  (check availability before building on a new API) and respect accessibility
  settings.
- Direct touch follows [macOS input guidance](Docs/MACOS_INPUT.md): native
  sizing, 36 × 36-point action targets without bigger glyphs, AppKit gesture
  recognizers rather than mouse overrides, one-finger Browser/Grid scrolling,
  keyboard and VoiceOver alternatives. Report missing hardware checks before
  claiming touch-native readiness or changing `NSIsTouchNative`.
- Short, direct UI, website and documentation text. Remove filler; keep safety
  conditions, limits and remedies.
- Enums for exclusive states; existing typed identities and plans at
  boundaries. Domain logic pure, UI state in its owner, I/O in workers or
  actors. Share logic across commands; prefer labeled arguments.
- Show progress immediately; report success only after worker confirmation.
  Partial results must match the files on disk.
- Reproduce failures and inspect errors, sidecars, journals or measurements.
  Use existing `Logger`/`OSSignposter` patterns; keep personal metadata private.
  Preserve intentional fallbacks and show actionable errors.
- Test contracts with disposable files, real I/O and focused fault injection.
  For interactions, test the composed control: deliver real events to the
  rendered hierarchy. Helper geometry that mirrors the intended layout has
  passed while real clicks failed.
- Check uncertain APIs against the selected SDK, pinned sources and official
  documentation. Update affected docs; report results and verification gaps.

## UI conventions

- Colors never change: one background, `Color.appBackground`, with `Divider()`
  lines between regions (grouped Form sections keep their system surfaces). One
  accent, `Color.louppeAccent` (#9853A6, global `.tint`), defined in
  `Sources/Louppe/Views/Design/Palette.swift`. Green and red mean yes/no in
  ratings; elsewhere they appear only as content colors (color labels), red
  validation errors and audio-meter zones. Never blue chrome or `Color.accentColor`.
- Settings and configuration sheets use the native grouped Form: leading labels,
  trailing values, automatic picker and toggle styling. Toolbar popovers (Sort,
  Filter) share Filter's compact layout: bold title, compact rows and
  checkboxes, Divider-separated sections, 14-point margins, 340-point width,
  footer with Done trailing; keep semantic differences such as multi-selection
  checkboxes and action menus.
- Dropdowns outside grouped Forms are a `Menu` with `.menuStyle(.button)` and
  `.buttonStyle(.borderless)`, as in `ArchiveBreadcrumbView`; put a choice
  inside it as an inline `Picker` or buttons. Never `.pickerStyle(.menu)`,
  `.menuStyle(.borderedButton)` or `.menuStyle(.borderlessButton)`;
  `SourceConventionsTests` rejects these styles.
- Before building a repeated layout, check the [Design components table](Docs/DEVELOPMENT_DETAILS.md#design-components).
- Where controls go: source shortcuts and pins on Welcome; persistent
  preferences in Settings; narrowing the Photos selection in Filter; library
  mutations in the File menu behind a confirmation. The review surface gets a
  permanent control only for an action used on most photos.
- Every new bar, row or button on the review surface is on trial: name the
  information or action lost if it were removed (keeping keyboard and VoiceOver
  paths). If nothing, remove it. Don't repeat what a visible sidebar shows, and
  hide navigation chrome when there is nothing to navigate.
- Prefer the normal UI in a disabled state over a special-purpose minimal
  screen.
- Panes side by side share one header height so their dividers line up.
- Info keeps the approved readout: aperture, shutter and ISO in the hero row,
  then focal length, exposure compensation and white balance.
- Layout changes cover still photos, video and audio tiles, panoramas, Photos
  badges and captions, in LTR and RTL.
- Consistency work compares each control type across all surfaces, not each
  surface on its own.

## Reporting UI work

- A visible change ends with screenshots from `capture_ui.sh`, light and dark,
  next to the closest existing pane (`--pair`), shown before any test counts.
  Offscreen captures show the inactive window appearance; say so, and never use
  them for Store, website or README images ([App Store](Docs/APP_STORE.md)).
- A UI feature gets one review that sees the captures and the neighboring pane
  before the diff, preferably from a different model than the implementer. Skip
  a second same-model review. Panel scores are not evidence.
- Unverified acceptance (hardware, live iCloud, VoiceOver) goes in
  [BACKLOG.md](BACKLOG.md) as one line each, not into feature docs.

## Read when relevant

Read all matching sections **before changing behavior**. These are required
project rules. Documentation edits need only the relevant references.

| Work area | Reference |
| --- | --- |
| Finding ownership or changing module boundaries | [Architecture map](Docs/DEVELOPMENT_DETAILS.md#architecture-map) |
| Copy, Move, Rename, Organize, Trash, undo, recovery, operation gates or sleep | [File operations](Docs/DEVELOPMENT_DETAILS.md#file-operations-and-recovery) |
| Save/load, sidecars, backups, migration, folder transitions or Quit | [Persistence](Docs/DEVELOPMENT_DETAILS.md#session-persistence) |
| Scanning, pairing, ratings, filtering, item replacement or selection | [Session state](Docs/DEVELOPMENT_DETAILS.md#session-state-and-selection) |
| Previews, thumbnails, media caches, zoom or asynchronous media loading | [Media](Docs/DEVELOPMENT_DETAILS.md#media-rendering-and-caches) |
| Browser/Grid interactions, scrolling, shortcuts, toolbar or window layout | [Native UI](Docs/DEVELOPMENT_DETAILS.md#native-ui) |
| Concurrency, caching, scanning, filtering, decoding, persistence or Clean Up | [Performance](Docs/PERFORMANCE.md) (read the matching sections) |
| Toolchain, iCloud, signing, captures, launching, live UI driving | [Agent environment](Docs/DEVELOPMENT_DETAILS.md#agent-environment) |
| Store packaging, upload, screenshots | [App Store](Docs/APP_STORE.md) |

## Architecture essentials

One `SessionStore` (`@MainActor ObservableObject`), created in `LouppeApp`, owns
session state and is passed to every view. Slow I/O stays off the main actor.

- Keep `visibleIndices` valid whenever `items` changes; rebuild derived data
  before filtering after structural changes.
- `SelectionState.itemIDs` owns selection; `selectedIndices` is its projection.
  Empty selection means the current photo, not no photo.
- Ratings belong to physical files; pairing is a projection. Preserve Mixed
  decisions and legacy session compatibility.
- Asynchronous media and caches follow `PhotoItem.contentRevision`, not just
  presentation ID. Keep 100% rendering tiled within its 128 MiB limit.

## Invariants — do not change

- **Bundle identifier** `com.alexandermarkin.louppe` and **sidecar filename**
  `.louppe_session.json` (renamed from “loupe” on 2026-07-12 with the owner's
  consent). Renaming again resets saved ratings and macOS folder permissions;
  don't without asking.
- **Originals are never modified or deleted, and never move without an
  explicit, confirmed command.** Export copies by default. The only sanctioned
  moves are Clean Up to the Trash, Export **Move to…**, **Organize Source
  Folder…** and **Rename Files…**/the Info pencil, each confirmed (⌘⌫ trashes
  the selection without a dialog; ⌘Z restores) and journaled
  ([details](Docs/DEVELOPMENT_DETAILS.md#file-operations-and-recovery)). No
  other code path may move originals; nothing ever hard-deletes.
- Activate `FileOperationJournal` before the first filesystem change in
  Copy/Move/Rename/Organize/Trash and supported undo. Verify exact paths and
  stable identity; never overwrite or infer ownership from a filename.
- Persistence preserves folder identity, sidecar lineage, durable writes and
  visible failure/retry behavior. Folder transitions and Quit await a safe save
  asynchronously; never hide failures or block the main thread.
- The shared `activeFileOperation` authority blocks conflicting operations and
  Quit. Unresolved recovery blocks new file mutations, not reviewing, saving,
  folder access, updates or Quit.
- Shortcuts: actions, aliases and contexts live in `ReviewShortcuts`;
  `CommandShortcuts` owns editable Command aliases; `SessionView.handleKey` owns
  routing and gates, and `SessionView`'s local monitor is the sole owner of
  session Command shortcuts (no duplicate menu `.keyboardShortcut`). Keep
  defaults in sync with [the user guide's table](Docs/USER_GUIDE.md#keyboard-shortcuts)
  and localized Help ([details](Docs/DEVELOPMENT_DETAILS.md#native-ui)).
- **Browser and Grid scroll vertically only.** `PersistentVerticalScroller`
  keeps the clip's X origin at zero through gestures, momentum, layout and
  follow-scroll, in LTR and RTL, with Browser's 122-point padded column. Never
  fix it by clipping thumbnails or disabling scrolling
  ([details](Docs/DEVELOPMENT_DETAILS.md#native-ui)).

## Versions and releases

- `VERSION` supplies the About-panel version and build. Bump both exactly once
  per GitHub release cycle (check `gh release list`): the first *commit* after a
  published release bumps `VERSION` and opens the `CHANGELOG.md` entry
  `## <MARKETING_VERSION> (<BUILD_NUMBER>) — <DATE>`; later changes fold into it.
  Never bump in uncommitted work; local installs never justify a bump. Tags are
  `v<MARKETING_VERSION>`. Steps: [BACKLOG § Release procedure](BACKLOG.md#release-procedure).
- Release verification validates the loose and archived app independently and
  compares their complete `Contents/` trees.

## Docs

- Docs describe current behavior and procedures. Test results, SHAs, install
  steps and backups belong in the chat report or commit message, never in
  `Docs/`. Dated reports live under `Docs/Archive/`.
- Avoid “currently installed/published” sentences; tags, `CHANGELOG.md` and the
  BACKLOG header carry release status.

## Repo conventions

- GitHub: `murlexander/louppe-media-culler` (public). External contributors
  work on branches in their forks and open pull requests against `main`.
- **Use `main` only in the owner's managed checkout.** No feature branches
  unless the owner asks; delete an exceptional branch locally and on GitHub
  after it merges.
- Commit each finished task locally on `main` once its affected tests pass
  (plus `--gates` when code changed): only your own files, one commit per task. Push only when the
  owner asks; he reviews and merges through GitHub or asks here.
- `dist/` and `.build*/` are gitignored build products. `Packaging/` holds the
  tracked bundle inputs: entitlements, privacy manifest, `AppIcon/`, localized
  `InfoPlist/` strings and third-party licenses.

## Standalone checkouts and local project layout

This repository contains the app's source, tests, fixtures, build tools and
engineering instructions. Run commands from the root of this checkout, wherever
it is cloned; normal development needs no parent files, website, marketing
media, personal notes or signing credentials. Alex's managed checkout sits in a
shared local Louppe workspace whose optional parent `AGENTS.md` describes it;
consult it when present. Personal notes and CAS logs stay in Obsidian.
