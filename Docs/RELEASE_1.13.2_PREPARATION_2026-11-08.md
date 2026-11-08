# Louppe 1.13.2 (17) security release — 8 November 2026

This patch ships Expat 2.10.0 from `33b7776`, retaining the existing XMP budgets and disabled DTD/general entities. Release source is `24f476631effa49300b6d52bb97e737081fa9c02`; only VERSION and CHANGELOG differ from that tested app source.

Alex authorized publication in the weekly maintenance chat. The active 1.14 session reserved build 17 for this patch and moved its uncommitted changes to 1.14.0 (18). Builds, signing and Store packaging use separate temporary checkouts. Its working files, shared `.build`, and installed 1.14.0 (17) app are preserved; no local install is part of this release. The session owns later VERSION/CHANGELOG reconciliation before committing its work.

## Verification

- Security source: [Quality 42473513401](https://github.com/murlexander/louppe-media-culler/actions/runs/42473513401) passed strict build, full XCTest, recovery/performance, scrolling, video and packaging.
- Exact release: [Quality 42497493529](https://github.com/murlexander/louppe-media-culler/actions/runs/42497493529) passed all checks.
- Local strict build and 103 focused XMP/hostile-filesystem tests passed. Store compilation and 104 affected tests passed with the documented `APP_STORE` compiler flag; an initial invocation omitted that flag and failed before correction.
- Release-history, staged and working-tree credential scans passed. An all-refs scan reported three public client-side identifiers from unrelated retained website history (Ahrefs tracking and Stripe publishable identifiers), absent from release ancestry; those values are not reproduced here.

## Direct download

Developer ID signing and Apple notarization passed. Accepted request: `b29f573e-9631-45e0-b364-9cab5213fb08`. The ticket is stapled; loose and archived apps pass strict signatures, Gatekeeper and publishing preflight. Both archive and feed signatures verify.

- ZIP: 8,841,087 bytes, SHA-256 `8e9d55ce9cd4ded6733357ea6db15e1e51933451fd1eda7c311355d19bccff40`.
- [GitHub v1.13.2](https://github.com/murlexander/louppe-media-culler/releases/tag/v1.13.2) is public and Latest. Tag resolves to exact source `24f4766`; the downloaded public ZIP matches the signed artifact byte for byte.
- Signed feed commit `ad15ef8` is public; the actual updater URL serves byte-identical XML and its signature verifies.
- [Homebrew workflow 42499055423](https://github.com/murlexander/louppe-media-culler/actions/runs/42499055423) passed and committed `bf3599e`, setting cask version 1.13.2 and the exact ZIP hash.
- A real headless Sparkle update installed 1.13.2 (17) over an isolated copy of the public 1.13.1 (16) app. All 8,841,087 bytes downloaded; updated Contents match the release exactly, strict signatures/Gatekeeper/stapling pass, preferences are preserved, and no app was relaunched. The installed 1.14 development app was not touched.

## App Store

The Store app and package pass their preflights, contain no Sparkle, and use SAMO DANNI EOOD's Apple Distribution and Mac Installer Distribution identities (P6F95J4ZPA).

- PKG: 7,740,157 bytes, SHA-256 `acf7e0c34634d63942667207db6ebba71185eb0d4570b2146e884baaa8510f0c`.
- Alex completed sign-in to T3's Default profile on 8 November. The current Store release is 1.13.1 (16), Ready for Distribution. Created the 1.13.2 draft and verified all 11 security-note translations, exact prior promotional text, unchanged descriptions/keywords, and 88 inherited screenshots. Added the security-update review note and a 33,273,155-byte subset of existing sample media; media bytes are unchanged. Automatic release after approval and existing ratings are preserved.
- Alex clicked Deliver in Transporter. Apple received build 17 on 8 November at 17:57 CET; build ID `0b6b15e0-3a00-4f6b-bd3d-3045d9a824d4` reports VALID / VALID_BINARY and APP_STORE_ELIGIBLE. The exact retained package was used, without foreground agent input or authentication-configuration changes.
- Attached build 17 and confirmed the unchanged Apple-system-only export-compliance answer (`usesNonExemptEncryption=false`). Submitted version `f9d3e6c3-4345-4477-88b5-58477e92007e` for review at approximately 18:04 CET. Both the UI and read-only Store data confirm **WAITING_FOR_REVIEW**, with one submitted item and no draft submissions. Release policy is AFTER_APPROVAL, so it will release automatically after Apple approves it; no further Alex action is pending.
- Store What's New: “Includes security fixes for XMP sidecar parsing.” No GitHub or payment reference is needed.

Artifacts and logs are retained in ignored `dist/release-preparation/1.13.2-17-2026-11-08/`. The canonical installed development app remains unchanged. Existing hardware, older-macOS and assistive-technology acceptance limits remain in the project backlog; no new claim is made for those checks.
