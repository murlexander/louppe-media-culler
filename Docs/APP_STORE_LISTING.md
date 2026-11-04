# App Store listing and search (ASO) — 4 November 2026

Live Store version: 1.12.0 (Ready for Sale). No version is in Prepare for
Submission, so only promotional text changed now. Everything else waits for the
next Store version (1.13). Claims below match 1.12; do not add 1.13 features to
live text before 1.13 is approved.

## Baseline (13 Oct – 2 Nov 2026)

45 downloads, 181 impressions, 96 page views, 40.5% conversion. Search: 14
impressions, 3 page views, 7 downloads. Browse: 21 / 6 / 2. Zero ratings.

Mac App Store web search (US, 4 Nov, top 12 results): Louppe is absent for every
generic term tried, including `photo culling`, `culling`, `raw viewer`,
`photo viewer`, `image viewer`, `photo rating`, `cull raw`, `video culling`,
`photo browser`, and `exif viewer`. It ranks #1 for `louppe culling`. A search
for `louppe` is corrected to `loupe`, and Louppe does not appear. About 15 Mac
culling apps put `Cull`, `Culling`, or `RAW` in their name (OptiCull, Cull,
Shuttery, CullKit, Palomino, BridgeLite, ApolloOne, Speed Contact Sheet). The
name "Louppe" alone carries no search terms.

## Apple rules used (checked 4 Nov 2026)

- Indexed: name, subtitle, keywords, and categories, plus downloads and ratings.
  The description and promotional text are not indexed. ([Apple: search](https://developer.apple.com/app-store/search/))
- Name and subtitle: 30 characters each. Keywords: 100 **bytes** (CJK characters
  take 3 bytes each). Use commas with no spaces, and don't repeat words already
  in the name, subtitle, or category ("photo" and "video" come from Photo &
  Video). Treat plurals as repeats. No competitor or trademark names.
  ([field reference](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information))
- Promotional text: 170 characters, editable without review.
- Storefront languages ([table](https://developer.apple.com/help/app-store-connect/reference/app-store-localizations/)):
  US indexes en-US + Arabic, Simplified/Traditional Chinese, French, Korean,
  pt-BR, Russian, es-MX, and Vietnamese. Germany indexes German + **en-GB**,
  Japan Japanese + en-US, China zh-Hans + en-GB, France French + en-GB. Germany
  and France therefore don't index en-US keywords, so an en-GB localization is
  needed.

Term evidence comes from App Store search suggestions and result pages. It
shows which phrases people search, not how often. Phrases found: *photo culling,
photo viewer, image viewer, photo picker, photo sorter, photo organizer, exif
viewer*; DE *fotos aussortieren, bilder aussortieren, fotos sortieren,
bildbetrachter, culling*; FR *tri photo, trier photo, tri de photos, culling*;
JA *写真選別, 画像ビューア, 写真ビューワー, 写真整理*; ZH *选片, 照片筛选, 看图软件,
照片查看器, 图片浏览器*.

## Applied live (4 Nov 2026, version 1.12.0, all 6 locales)

The promotional text was empty everywhere. It now reads:

| Locale | Promotional text |
| --- | --- |
| en-US | Free and open source. Open a folder or memory card, mark keepers with one key, and copy them out. RAW+JPEG pairs, video and audio. No account, import, or upload. |
| es-ES | Gratis y de código abierto. Abre una carpeta o tarjeta, marca las mejores fotos con una tecla y cópialas. RAW+JPEG, vídeo y audio. Sin cuenta, importación ni subidas. |
| pt-BR | Grátis e de código aberto. Abra uma pasta ou cartão, marque as melhores fotos com uma tecla e copie-as. RAW+JPEG, vídeo e áudio. Sem conta, importação ou upload. |
| zh-Hans | 免费开源。打开文件夹或存储卡，一键标记要保留的照片，再复制出来。支持 RAW+JPEG 配对、视频和音频。无需账户、导入或上传。 |
| hi | मुफ़्त और ओपन सोर्स। फ़ोल्डर या मेमोरी कार्ड खोलें, एक कुंजी से अच्छी फ़ोटो चुनें और कॉपी करें। RAW+JPEG, वीडियो और ऑडियो। कोई खाता, इम्पोर्ट या अपलोड नहीं। |
| ar-SA | مجاني ومفتوح المصدر. افتح مجلدًا أو بطاقة ذاكرة، وحدد الصور التي تريد الاحتفاظ بها بمفتاح واحد، ثم انسخها. أزواج RAW+JPEG والفيديو والصوت. بلا حساب أو استيراد أو رفع. |

Why: it is the first text on the product page. It now states what sets Louppe
apart from paid and AI culling apps. It affects conversion, not search.

## Staged for the next Store version

Enter these when the 1.13 version record exists, before submitting it. Name
and subtitle are App Information fields; keywords, description, and
screenshots are version fields. New locales are added on the version page.

### Name, subtitle, keywords

| Locale | Name (current → proposed) | Subtitle (current → proposed) | Keywords (proposed, bytes) |
| --- | --- | --- | --- |
| en-US | Louppe → **Louppe: Photo Culling & Viewer** | Photo and media review → **Rate & sort RAW, JPEG, video** | `loupe,cull,culler,image,browser,picker,selector,exif,metadata,xmp,burst,duplicate,fuji,stars,rating` (99) |
| en-GB *(new)* | **Louppe: Photo Culling & Viewer** | **Rate & sort RAW, JPEG, video** | `loupe,cull,culler,image,browser,picker,selector,exif,metadata,xmp,burst,duplicate,fuji,organiser` (96) |
| de-DE *(new)* | **Louppe: Fotos aussortieren** | **RAW, JPEG & Video bewerten** | `culling,bilder,bildbetrachter,sortieren,auswahl,sterne,metadaten,exif,xmp,duplikate,fuji,lupe,viewer` (100) |
| fr-FR *(new)* | **Louppe : tri photo et RAW** | **Noter JPEG, vidéo et audio** | `culling,trier,sélection,visionneuse,image,étoiles,métadonnées,exif,xmp,doublons,rafale,loupe` (96) |
| ja *(new)* | **Louppe: 写真選別・RAWビューア** | **RAW+JPEGと動画をセレクト** | `画像ビューア,写真整理,評価,レーティング,メタデータ,exif,xmp,連写,重複` (96) |
| zh-Hans | Louppe → **Louppe：照片筛选与 RAW 看图** | 照片与媒体审阅 → **RAW+JPEG 与视频选片评分** | `看图软件,照片查看器,图片浏览器,星级,元数据,exif,xmp,连拍,重复照片,culling` (98) |
| es-MX *(new)* | **Louppe: Selección de fotos** | **Califica RAW, JPEG y video** | `culling,visor,imágenes,clasificar,ordenar,estrellas,metadatos,exif,xmp,duplicados,ráfaga,lupa` (95) |
| es-ES | Louppe → **Louppe: Selección de fotos** | Revisión de fotos y medios → **Valora RAW, JPEG y vídeo** | same as es-MX (95) |
| pt-BR | Louppe → **Louppe: Seleção de fotos** | Revisão de fotos e mídia → **Avalie RAW, JPEG e vídeo** | `culling,visualizador,imagens,classificar,organizar,estrelas,metadados,exif,xmp,duplicatas,lupa` (94) |
| hi | Louppe (keep) | फ़ोटो और मीडिया की समीक्षा → **फ़ोटो चयन: RAW, JPEG, वीडियो** | `फ़ोटो,चयन,रेटिंग,मेटाडेटा,culling,viewer,exif` (89) |
| ar-SA | Louppe (keep) | مراجعة الصور والوسائط → **فرز صور RAW وJPEG والفيديو** | `صور,تقييم,اختيار,بيانات,تكرار,culling,viewer,exif,xmp,shortlist` (88) |

Current keywords: en-US `culling,RAW,JPEG,ratings,workflow,metadata,shortlist,selection,duplicate,keyboard`.
The other locales use short translations of the same list.

Reasoning:
- **Name** carries the most weight. Louppe currently ranks for no generic term.
  "Photo culling" and "photo viewer" are the two clearest searched phrases.
  Combining name words also covers *photo viewer*, *culling viewer*, and
  *RAW viewer* (with RAW in the subtitle). The brand stays first.
- **Subtitle** adds RAW, JPEG, video, rate, and sort. It also reads as a plain
  description of the app on result cards.
- **Keywords** hold only words not already in the name, subtitle, or category.
  `loupe` catches brand searches that Apple corrects from "louppe". English
  `culling` and `viewer` go into non-English fields because local searches use
  them, and the US indexes zh-Hans, pt-BR, ar-SA, es-MX, and fr-FR. Generic
  terms with poor relevance were dropped: `workflow`, `keyboard`, `selection`.
- **New locales** (en-GB, de-DE, fr-FR, ja, es-MX) cover four of the top five
  storefronts and add three more US-indexed fields (fr-FR, es-MX, plus the
  existing zh-Hans/pt-BR/ar-SA). The app UI isn't in German, French, or
  Japanese. Write those descriptions in the local language, or reuse English,
  and end them with "Interface: English, Spanish, Simplified Chinese, Hindi,
  Portuguese, Arabic" in that language.
- **Categories:** keep Photo & Video. Secondary category is empty; adding one
  (Productivity or Graphics & Design) is optional and low impact. Choose it only
  if it describes the app; Apple rejects irrelevant categories.

### Description opening (all locales; translate the existing text)

Only the first lines show before "more". Proposed en-US first paragraph,
replacing the current first sentence:

> Cull a shoot on your Mac without importing it. Open a folder or memory card,
> mark each photo Yes or No with one key, add stars and color labels, and copy
> the keepers. Free and open source.

Keep the remaining paragraphs. Add a line for 1.13 features only after they ship:
folder tree for archives, pinned folders, and Apple Photos review.

### Screenshots (order and captions)

Current captions, in order: Review your photos · See the whole shoot · Mark your
keepers · Inspect at 100% · Read the metadata · Copy your shortlist. Proposed
order and captions, with the supporting line second:

1. Ratings view — **Mark keepers with one key** / Yes/No, stars, and color labels
2. Grid — **See the whole shoot** / Open a folder or card. No import.
3. *New capture:* RAW+JPEG pair — **RAW+JPEG, one review item** / Each file keeps its own rating
4. 100% zoom — **Check focus at 100%** / Inspect fine detail
5. Info — **Read camera settings** / Exposure, lens, histogram, Fuji film simulation (recapture with a Fuji file)
6. Copy — **Copy keepers out** / Originals stay in place
7. *Optional new capture:* video playback — **Review video and audio too**

Why: open with the core action (choosing keepers) rather than a single photo,
since early screenshots may appear in search and Browse. Then show the
differentiators: RAW+JPEG pairs, Fuji film simulations, video, and no import.
Mac screenshots and new locales can change only with a version.

## Other next-version items (not done here)

- **Ratings:** there are 0, and the app never asks. Add Apple's `requestReview`
  after a completed Copy or session, rate-limited. Ratings affect ranking and
  conversion.
- Keep the website's App Store links tagged (`ct=`). Web Referrer is already the
  second-largest source.

## Measuring

In App Store Connect, open Analytics → Acquisition → Sources. Filter **App Store
Search** (impressions, product page views, downloads, conversion) and **App
Store Browse**. Compare the 14 and 28 days after each change with the 14 and 28
days before it. Note the change date here:

| Date | Change | Expected effect |
| --- | --- | --- |
| 2026-11-04 | Promotional text, 6 locales | Page view → download conversion; no search effect |
| (1.13 release) | Name, subtitle, keywords, new locales, screenshots | Search impressions and downloads; per-storefront impressions in DE, JP, FR, CN |

Also rerun the search checks for the terms above in the US, DE, JP, FR, and CN
storefronts via `apps.apple.com/<cc>/mac/search?term=…`, and record Louppe's
position. Volumes are low (14 search impressions in 3 weeks), so don't judge a
change before 28 days. Change one thing at a time where possible.
