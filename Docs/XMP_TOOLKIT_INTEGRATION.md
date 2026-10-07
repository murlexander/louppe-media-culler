# XMPCore integration record

Parser pins and shipping bridge. Isolation proof: `Prototypes/XMPBridgeProof`.

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

## What the proof establishes

`Scripts/run_xmp_bridge_proof.sh` builds only the legacy XMPCore metadata API,
Expat, a narrow C bridge implemented in Objective-C++, and a Swift runner. It
does not build XMPFiles because Louppe will never embed metadata in media.
The build explicitly enables XMPCore's `BanAllEntityUsage` guard; Adobe's
source defaults that guard off, which is unsuitable for untrusted sidecars.
The bridge also installs an error callback that refuses XMPCore's default
"recover and return a partial packet" behavior for malformed XML.

The runner covers synthetic, non-copyrighted packets shaped for Universal
XMP, Lightroom Classic, Adobe Bridge, Capture One, and darktable. Together
they exercise:

- unknown namespaces and custom properties;
- custom `xmp:Label` text;
- flat and hierarchical keyword arrays;
- localized values and qualifiers;
- Adobe Camera Raw settings;
- darktable history, blend, and multi-color data;
- a writable packet wrapper with padding;
- malformed XML rejection.

Each valid fixture preserves foreign sentinels through parse/serialize,
updates rating/color/decision, reparses, verifies four owned properties, and
repeats the merge on its output. The malformed fixture must fail.

Run `./Scripts/run_xmp_bridge_proof.sh` to check the production vendored sources.
Alternatively, run it with exact local checkouts:

```sh
./Scripts/run_xmp_bridge_proof.sh \
  /path/to/XMP-Toolkit-SDK \
  /path/to/libexpat
```

Explicit checkouts must match the pins. The script prefers installed full Xcode’s
current SDK and retains its temporary objects/executable for inspection.

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
