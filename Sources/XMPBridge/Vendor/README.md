# Vendored XMPCore source subset

Static XMPCore subset. XMPFiles/media-embedding handlers are excluded.

Pinned inputs:

- Adobe XMP Toolkit SDK revision
  `7093513bd3caaad29da01db0f275d88a39d6bcc2` (BSD 3-Clause)
- libexpat revision
  `4b3f0b06f39fb5529cead381694f8929901bc273` (MIT, Expat 2.8.5)
  from upstream tag `R_2_8_5`; release archive SHA-256
  `1e727b8933ec51a77a9a9d9afcf8e688bce45d907c13e36ab7393fe36e703182`

The `XMPToolkit` tree contains the headers required by the exact `.cpp` source
manifest in `Package.swift`: the legacy XMPCore implementation, its common
interfaces, the macOS configuration header, Unicode/XML helpers, and MD5
helper. The `Expat` tree supplies the three parser `.c` files, the macOS `random_arc4random_buf.c` source, and their private
headers. `XMPToolkit/third-party/expat/lib` is the include-layout shim expected
by Adobe's source and is copied from the same pinned Expat revision.

`Package.swift` defines `BanAllEntityUsage=1` and the bridge installs a strict
XMPCore parse-error callback for every packet. Do not replace this target with
handwritten XML merging or broaden it to XMPFiles. When updating either input,
repeat the isolation proof, review the source manifest, update both revision
records and licenses, and rerun the packet and hostile-filesystem suites.

Every app includes `ThirdPartyLicenses/` texts; release verification checks them
in the loose bundle and extracted archive.

Louppe's only XMPCore source changes are the `ExpatAdapter` resource counters:
128 nested elements, 250,000 allocated nodes (including attributes and text
nodes), 1,024 attributes per element, 1,024 namespace declarations per packet,
and 64 MiB of decoded names/text. The callback stops Expat before allocating
beyond a budget, then reports an ordinary parse error. Limits cover all bridge
entry points and stream chunks. The macOS config keeps `XML_DTD` undefined,
sets `XML_GE=0`, and uses the platform's `arc4random_buf`. Do not discard these
local changes when updating Adobe's unchanged upstream revision.
