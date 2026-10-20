# Modern image fixtures

`square.jxl` is the unchanged 8 × 8 fixture from the libjxl testdata authors:
https://github.com/libjxl/testdata/blob/73695d303670c90e4d506ea89d9901b081385089/jxl/boxes/square-extended-size-container.jxl

Licensed under Creative Commons Attribution 4.0 International (see LICENSE).
`square.avif` and `square.webp` are conversions of that image, made with
macOS ImageIO and `cwebp -lossless`, respectively. These are real encoded
images, not renamed JPEGs. Tests check their ImageIO type identifiers.
