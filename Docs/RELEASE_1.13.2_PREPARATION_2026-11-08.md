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
- GitHub draft: v1.13.2, exact source `24f4766`, exact ZIP verified by GitHub digest. Publication, public feed, Homebrew and real update verification remain pending.

## App Store

The Store app and package pass their preflights, contain no Sparkle, and use SAMO DANNI EOOD's Apple Distribution and Mac Installer Distribution identities (P6F95J4ZPA).

- PKG: 7,740,157 bytes, SHA-256 `acf7e0c34634d63942667207db6ebba71185eb0d4570b2146e884baaa8510f0c`.
- App Store Connect is signed out in T3's Default profile. Upload, current Store state, metadata and review submission are unverified; no authentication configuration changed. Alex has been asked for that sign-in while direct publication proceeds independently.
- Store What's New: “Includes security fixes for XMP sidecar parsing.” No GitHub or payment reference is needed.

Artifacts and logs are retained in ignored `dist/release-preparation/1.13.2-17-2026-11-08/`. The canonical installed development app remains unchanged. Existing hardware, older-macOS and assistive-technology acceptance limits remain in the project backlog; no new claim is made for those checks.
