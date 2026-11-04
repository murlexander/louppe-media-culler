# XMPCore integration record

Parser pins, shipping bridge, and production regression checks.

## Reviewed dependencies

| Component | Repository | Pinned revision | License |
|---|---|---|---|
| Adobe XMP Toolkit SDK / XMPCore | `https://github.com/adobe/XMP-Toolkit-SDK` | `7093513bd3caaad29da01db0f275d88a39d6bcc2` | BSD 3-Clause |
| Expat 2.9.0 | `https://github.com/libexpat/libexpat` | `a76b1174c1ea52abb639a4c69d52b630a8a106a2` | MIT |

Adobe’s reviewed `main` pin (2026-08-05) was last committed 2025-11-03.
It declares Expat 2.5.0; Louppe uses patched `R_2_9_0`. Checksums and bounded-tree
adapter changes are in the vendor README.

Every source/binary distribution must include complete
`ThirdPartyLicenses/XMPCore-BSD-3-Clause.txt` and `ThirdPartyLicenses/Expat-MIT.txt`.

## 4 November 2026 dependency review (1.13)

- Sparkle 2.10.1 archive SHA-256 matches `Package.swift`; it is the latest
  release. All GitHub advisories affect 2.9.5 or earlier.
- All 39 vendored Expat files, and Adobe's include-layout copy, are
  byte-identical to the official `expat-2.9.0.tar.xz` (recorded SHA-256). `COPYING` and Adobe's
  `LICENSE` match `ThirdPartyLicenses/`.
- 275 of 278 vendored XMP Toolkit files match the pinned revision. The other
  three are the recorded Louppe patches: `expat_config.h`, `ExpatAdapter.hpp`
  and `ExpatAdapter.cpp`. Adobe has published no commit since the pin and no
  GitHub advisory. Its latest indexed bulletin, APSB25-34, was fixed in
  2025.03, before the pin. Adobe's bulletin index (October 2026 onward is in its
  Trust Center) refused automated access; that check remains manual.
- Expat 2.10.0 (2 November) fixes four CVEs. None is reachable here:
  XMPCore never calls `XML_ParserReset` or creates external-entity subparsers;
  `XML_GE=0` plus the DOCTYPE ban prevent entity expansion; and the
  `storeAtts` overflow needs over a billion attributes, beyond the 64 MiB input
  limit. Update during the next scheduled dependency refresh.
- Fixed one exposure: XMPCore's process-wide namespace table grew without bound
  (see the [vendor README](../Sources/XMPBridge/Vendor/README.md)).
  `XMPSecurityTests` now covers entity expansion, external DTDs, undeclared
  entities, malformed UTF-8 repair, amplified repair, oversized input, large
  attributes, namespace URI/prefix limits and both per-launch budgets
  (count and retained bytes) at every bridge entry. After exhaustion, the
  Adobe Bridge, Lightroom Classic and previously read darktable fixtures still
  parse; an unread Capture One namespace gets the quit-and-reopen message.

## Production distribution decision

`Sources/XMPBridge/Vendor/` contains the reviewed XMPCore/Expat subset.
Only `Package.swift`’s listed files compile. XMPFiles/media-embedding handlers
are excluded. The bridge uses Louppe’s architecture/current SDK and needs no
separate runtime download.

`Sources/XMPBridge/Vendor/README.md` records the subset layout and update
procedure. `build_app.sh` copies both complete license texts into the app, and
`Scripts/verify_release.sh` compares them independently in the loose and
archived bundles.

## Production regression checks

The shipping bridge and Swift field mappings are exercised by `XMPPhase5Tests`,
`XMPPhase6Tests`, `XMPPhase7Tests`, and `XMPSecurityTests`. Synthetic packets in
`Tests/Fixtures/XMP/` cover foreign namespaces, keywords, qualifiers, Camera Raw
edits, darktable history, writable packet padding, and malformed XML. Security
tests also cover DOCTYPE/entity rejection and bounded hostile packets.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-keychain --build-system native \
  --filter 'XMPPhase[567]Tests|XMPSecurityTests'
```

The standalone August prototype and its separate build runner were retired;
their synthetic packets are retained unchanged. Tests now exercise the production
bridge rather than a second implementation. Actual editor acceptance remains
in the [backlog](../BACKLOG.md).

## Findings carried into production

- XMPCore is a suitable semantic parser/serializer and exposes the operations
  Louppe needs without XMPFiles.
- Production builds must keep `BanAllEntityUsage=1` and retain the malicious
  DOCTYPE fixture. The reviewed Adobe source otherwise defaults the guard off.
  Every parse must also install the strict callback: without it, recoverable
  XML failures can return a partial packet instead of throwing.
- Adobe does not publish a SwiftPM package. Its current checkout plus Expat is
  roughly 78 MiB before build products, so silently vendoring the whole SDK is
  not an acceptable integration step.
- XMPCore serialization is semantically stable, not byte-identical. Foreign
  fields survive, while formatting, prefix placement, and padding layout can
  change. File-level CAS must therefore continue to compare original raw
  bytes, while post-write verification must compare intended XMP semantics.
- The production bridge exposes only typed profile mappings, semantic
  verification, and property inspection. Swift owns planning, exact paths,
  conflict reporting, bounded reads, CAS, and durable publication.
- An existing custom `xmp:Label` without Louppe provenance cannot be removed
  unless a future confirmation explicitly authorizes it.
- Extension-qualified application packets are resolver outputs for unchanged
  transfer only. The merge bridge is used solely for the canonical stem XMP.
