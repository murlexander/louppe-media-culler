# XMPCore integration record

Parser pins, shipping bridge, and production regression checks.

## Reviewed dependencies

| Component | Repository | Pinned revision | License |
|---|---|---|---|
| Adobe XMP Toolkit SDK / XMPCore | `https://github.com/adobe/XMP-Toolkit-SDK` | `7093513bd3caaad29da01db0f275d88a39d6bcc2` | BSD 3-Clause |
| Expat 2.8.5 | `https://github.com/libexpat/libexpat` | `4b3f0b06f39fb5529cead381694f8929901bc273` | MIT |

Adobe’s reviewed `main` pin (2026-08-05) was last committed 2025-11-03.
It declares Expat 2.5.0; Louppe uses patched `R_2_8_5`. Checksums and bounded-tree
adapter changes are in the vendor README.

Every source/binary distribution must include complete
`ThirdPartyLicenses/XMPCore-BSD-3-Clause.txt` and `ThirdPartyLicenses/Expat-MIT.txt`.

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
