# Development and release

[Documentation](README.md) · [User guide](USER_GUIDE.md)

## Contributing

[Open backlog](../BACKLOG.md) · [Build/test rules](../AGENTS.md) · [Version history](../CHANGELOG.md)

Fork this repository, work on a branch in your fork, and open a pull request
against `main`. This app repository is self-contained: source, tests, fixtures,
build tools, and engineering instructions are included. The parent workspace,
website, marketing assets, and private signing credentials are not needed for
normal development. Read [AGENTS.md](../AGENTS.md) before changing code.

Use full Xcode with the current macOS SDK. From the root of your clone:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --disable-keychain
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-keychain --build-system native
```

Sparkle is a public, checksum-pinned dependency; the XMP parser sources are vendored.
The guides below cover affected checks and local app packaging. Optional hardware,
RAW-corpus, and release acceptance checks document their separate requirements.

| Guide | Use |
| --- | --- |
| [Development details](DEVELOPMENT_DETAILS.md) | Ownership, file safety, persistence, media, and native UI |
| [Performance](PERFORMANCE.md) | Resource policies and subsystem limits |
| [Speed tests](SPEED_TESTS.md) | Repeatable measurements and comparisons |
| [Review builds](REVIEW_BUILD.md) | Isolated local builds and launch checks |
| [Automatic updates](UPDATES.md) | Direct-download feed and signing |
| [App Store](APP_STORE.md) | Sandboxed packaging and submission |
| [Homebrew](HOMEBREW.md) | Cask maintenance |
| [XMPCore integration](XMP_TOOLKIT_INTEGRATION.md) | Parser pins, boundaries, and tests |

[1.12 release preparation](RELEASE_1.12_PREPARATION_2026-10-21.md) records
the review, verification, acceptance limits, and handoff for that release.
The [1.11 record](RELEASE_1.11_PREPARATION_2026-10-15.md) retains its Store submission history.

## Local review build

Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build_review.sh`
to create `dist/louppe - to review.app` and its ZIP. Its identity, preferences,
and window state are separate from `Louppe.app`; automatic updates are off.
`VERSION` still supplies its version. Ratings use the compatible
`.louppe_session.json`, so experiment with copies of media. See
[the review record](REVIEW_BUILD.md).

## Utilities

`build_app.sh` builds/packages the app. `Scripts/` contains release verification,
review packaging, signing/notarization, Store packaging, update-feed preparation,
Homebrew maintenance, and credential/localization checks. Shared resource/service
helpers are used by packaging.

`Tests/run_performance_checks.sh`, `run_scrollbar_checks.sh`, `run_video_checks.sh`,
and `run_resource_bundle_checks.sh` cover native/filesystem contracts.
`Tests/run_file_volume_remount_check.py` uses disposable volume images.
Speed runners and comparisons are described in the speed-test guide above.

## Historical records

[Archive](Archive/) holds dated implementation/release records, audit
reports, and benchmark evidence together by date. Completed outcomes remain in
those records and version history; the backlog contains open work and later ideas.
Scratch paths, logs, and source digests describe the original runs.
