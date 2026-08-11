# Distribution guide

How to get Markdowner **code-ready**, list it on the **Mac App Store**, and optionally **charge $2.99**.

Use this as a checklist. Section **1** is engineering work in this repo. Sections **2** and **3** are mostly your Apple Developer / App Store Connect work (with a few small code hooks).

**Current baseline (as of 1.1.1):** local app works; sandboxed entitlements exist; builds are **ad-hoc signed** (not notarized); not listed on the store.

---

## 1. Get the code ready

Work that belongs in the Xcode project / app binary **before** you spend money on store setup or pricing.

### 1.1 Must-do (P0) — quality + App Store / Gatekeeper technical baseline

| # | Task | Why | Notes |
|---|------|-----|--------|
| 1 | **Document UTIs: stop owning all text** | Avoid fighting TextEdit; cleaner metadata | In `Info.plist`, keep **Editor/Owner** for Markdown only (`net.daringfireball.markdown` / `.md` family). Use **Viewer** or drop `public.plain-text` / `public.text` as Owner. Remove empty `NSDocumentClass` or wire a real document class. |
| 2 | **Harden zip package extract** | Safety + sandbox credibility | Today: `/usr/bin/unzip` with no path checks. Prefer in-process unzip (Compression / Archive API or vetted library). **Always** reject entries that escape the extract root (zip-slip). Cap entry count / expanded size. Run off the main thread; show progress. |
| 3 | **Balance security-scoped access** | Sandbox stability | Pair every `startAccessingSecurityScopedResource()` with `stop…`. Don’t accumulate forever in `scopedRoots` without cleanup on folder change / window close / package close. |
| 4 | **Window restoration: multi-window friendly** | macOS HIG; user expectation | Don’t collapse all restored windows to one on launch. Keep ClingBar/URL coalesce in `WorkspaceWindowBridge`; restore legitimate multi-window state. Revisit blanket `isRestorable = false` / `NSQuitAlwaysKeepsWindows`. |
| 5 | **`PrivacyInfo.xcprivacy`** | Modern submission hygiene | Add a privacy manifest. This app is local-only: declare no tracking / no collected data as appropriate. |
| 6 | **`LSApplicationCategoryType`** | Store + Launchpad categorization | e.g. `public.app-category.productivity` (or developer-tools if you prefer that framing). |
| 7 | **Copyright / license consistency** | Legal clarity | Info.plist says “All rights reserved”; repo is MIT. Align copyright string with the actual license (or document dual licensing deliberately). |
| 8 | **In-app Support / About path** | Guideline 1.5 when listed | Help menu: Support link (your site or GitHub Issues), Privacy Policy link, clear About. Don’t rely only on markdownguide.org. |
| 9 | **Real signed-sandbox QA** | Catch entitlement bugs | Build with your **Team ID** + App Sandbox (not ad-hoc). Test: open folder, bookmark restore, open package, save, export HTML/PDF, open `https` links, URL schemes. |

### 1.2 Should-do (P1) — polish reviewers and users notice

| # | Task | Why |
|---|------|-----|
| 10 | **Accessibility pass** | VoiceOver on sidebar, package banner, Write/Source/Split, find bar, primary toolbar |
| 11 | **Settings that match reality** | Surface prefs that already exist (`@AppStorage` scroll sync, etc.); avoid empty “About-only” Settings if marketing mentions preferences |
| 12 | **Unit tests (minimum)** | Link resolution + anchors; zip path containment; read-only package won’t save |
| 13 | **App Review notes draft** (in repo or wiki) | Document URL schemes (`markdowner://new-window`, `focus`, `next-window`), sample zip path, “no accounts / no network API” |
| 14 | **Export HTML safety polish** | Title already escaped; keep body pipeline intentional for user Markdown → static HTML |
| 15 | **Optional: progress UI for large zips / big files** | Avoid beachballs on big packages |

### 1.3 Nice-to-have (P2) — modern macOS 26+ engineering

| # | Task | Why |
|---|------|-----|
| 16 | **Swift 6 concurrency** | Phase out `nonisolated(unsafe)` globals (`LinkHandling` context → per-window model) |
| 17 | **Stronger document integration** | Proxy icon, Open Recent polish; or eventual `DocumentGroup` / `NSFilePresenter` if you want full document-app behavior |
| 18 | **Localization** | English-only is fine if metadata says so; don’t claim multi-language without `.lproj` / String Catalogs |
| 19 | **CI archive** | Xcode Cloud or GH Action that archives Release with signing secrets (later) |

### 1.4 Shipping scripts (still “code ready”)

Update `scripts/package-dmg.sh` (or add `scripts/notarize.sh`) for **when you have certificates**:

1. Archive / build **Release** with **Developer ID Application** (direct) or prepare for **App Store** archive (store).
2. `xcrun notarytool submit … --wait`
3. `xcrun stapler staple` the `.app` and/or `.dmg`
4. Verify: `spctl -a -vv Markdowner.app` → accepted

Until then, keep documenting: *ad-hoc only; right-click Open*.

### 1.5 Code-ready definition of done

You’re “code ready” for listing when:

- [ ] Markdown UTIs are honest; no blanket ownership of all text  
- [ ] Zip extract is path-safe and size-bounded  
- [ ] Sandbox + bookmarks + packages work under a **Team-signed** build  
- [ ] Privacy manifest present  
- [ ] Support + Privacy links exist in Help/About  
- [ ] Multi-window restore doesn’t destroy user windows  
- [ ] Release notes / review notes describe features accurately  
- [ ] (For public DMG) notarized binary stapled  

---

## 2. What you need to do to list it on the marketplace

This section is **your** work (Apple accounts, metadata, legal, assets). Assumes Section **1** is largely done.

“Marketplace” here means the **Mac App Store**. (Direct website download is a separate path—see §2.5.)

### 2.1 Accounts & membership

| Step | Action |
|------|--------|
| 1 | Enroll in the **[Apple Developer Program](https://developer.apple.com/programs/)** (paid membership, individual or organization) |
| 2 | Accept latest Program License Agreement in [App Store Connect](https://appstoreconnect.apple.com) / developer account |
| 3 | In Xcode → Signing & Capabilities: select your **Team**, bundle id `com.markdowner.app` (or your final id) |
| 4 | Create **Mac App** identifiers / App ID if needed; enable capabilities you actually use (App Sandbox only is fine) |

### 2.2 Certificates & first archive

| Distribution | Certificate / profile | Use for |
|--------------|----------------------|---------|
| **Mac App Store** | Apple Distribution + Mac App Store provisioning | Upload to App Store Connect |
| **Direct download** (optional) | Developer ID Application (+ Developer ID Installer if you ship a pkg) | Notarized DMG outside the store |

**App Store path:**

1. Xcode → **Product → Archive**
2. Organizer → **Distribute App** → App Store Connect  
3. Upload build; wait for processing  

Do **not** ship the current ad-hoc DMG as the store binary.

### 2.3 Create the app record (App Store Connect)

1. **My Apps → + → New App**  
   - Platform: **macOS**  
   - Name: Markdowner (≤ 30 characters; check availability)  
   - Primary language, bundle ID, SKU (internal string, e.g. `markdowner-mac`)  
2. Fill **App Information**  
   - Category: **Productivity** (secondary: Developer Tools if desired)  
   - Content rights / age rating questionnaire (honest; local editor is usually 4+)  
3. **Pricing** — start as **Free** (see Section 3 to charge later)  
4. **Privacy**  
   - Privacy Policy URL (required) — even if “we collect nothing; files stay on device”  
   - App Privacy (“nutrition labels”): for this app, typically **Data Not Collected**  
5. **URLs**  
   - Support URL (required) — GitHub Issues, site contact form, or email landing page  
   - Marketing URL (optional but good)  

### 2.4 Listing assets & copy

| Asset | Guidance |
|-------|----------|
| **Subtitle** | Short value prop (e.g. “WYSIWYG Markdown for folders”) |
| **Description** | What it does: Write/Source/Split, folder sidebar, read-only zip packages, export. No unsubstantiated claims. |
| **Keywords** | Accurate only (markdown, editor, notes, …)—no trademark stuffing |
| **What’s New** | Match the binary (see CHANGELOG) |
| **Screenshots** | macOS screenshots of the **app in use** (sidebar + Write mode; package banner; split). Not just icon art. |
| **App icon** | Same family as `Assets.xcassets` AppIcon |
| **Review notes** | Paste the draft from §1: no login; sample package; URL schemes for ClingBar only; how to open a folder |

### 2.5 Compliance checklist (Mac App Store)

Confirm before **Submit for Review**:

- [ ] Sandboxed Mac app (you already target this)  
- [ ] No custom software update mechanism inside the app (updates go through the App Store)  
- [ ] No license key / own DRM at launch  
- [ ] Self-contained `.app` (no writing helpers outside container except user-selected files)  
- [ ] Help / Support reachable  
- [ ] Privacy questionnaire matches reality (no analytics SDKs added later without updating labels)  
- [ ] Export compliance: usually **No** encryption beyond HTTPS/exempt—answer the export questions honestly (local app with no custom crypto is simple)  
- [ ] Content rights: you own the icon, screenshots, sample content rights  

### 2.6 Submit & review

1. Select the processed build on the version page  
2. Answer encryption / advertising / IDFA questions (likely all no)  
3. **Submit for Review**  
4. Respond in Resolution Center if they ask (common: clarify document types, zip behavior, URL schemes)  

Typical first-review delays come from incomplete metadata, crash on launch, or unclear “what does this app do?”—your sample zip + screenshots help a lot.

### 2.7 After approval

- [ ] Phased release or release immediately  
- [ ] Monitor crash reports in App Store Connect / Xcode Organizer  
- [ ] Ship updates via new archives only (no self-update)  

### 2.8 Alternative: list only as a notarized download (not App Store)

If “marketplace” means **your website / GitHub Releases** only:

1. Developer Program membership still required for **Developer ID** + notarization  
2. Build Release → Developer ID sign → notarize → staple → attach DMG to GitHub Release  
3. No App Store cut; you handle payment yourself if paid (see §3.3)  
4. Users get Gatekeeper-friendly open without right-click (after notarization)  

You can do **both** (store + direct) with careful versioning; paid store vs free direct needs a clear business choice.

---

## 3. What you need to do to charge $2.99

Two common models. Pick one and stick to it in metadata.

### 3.1 Model A — Paid app on the Mac App Store ($2.99) **(simplest for $2.99)**

User pays **once** to download Markdowner from the Mac App Store.

| Step | Action |
|------|--------|
| 1 | **Paid Apps Agreement** — App Store Connect → Agreements, Tax, and Banking → accept **Paid Applications** agreement |
| 2 | **Banking & tax** — bank account, tax forms (W-9 / W-8BEN etc. as applicable). Until cleared, you **cannot** sell. |
| 3 | **Price tier** — App price = **$2.99** (or local equivalents Apple maps for you). Set for all territories or customize. |
| 4 | **No in-app purchase required** for unlock if the whole app is paid upfront. |
| 5 | **Metadata** — description must not promise free features you removed; “What’s New” if converting free→paid later is sensitive (existing free users on other channels are separate). |
| 6 | **Code** — usually **no storekit code** needed for a simple paid download. Optional: receipt validation only if you fear piracy (often unnecessary for a $2.99 utility). |
| 7 | Submit paid version for review like any update/new app. |

**Apple’s cut:** standard App Store commission on the sale (varies by program status / region; plan ~15–30% historically—check current terms). You do **not** set net proceeds; Apple shows estimated proceeds per tier.

**Pros:** one price, no unlock UI, Apple handles tax collection in many regions.  
**Cons:** Mac App Store exclusivity for *that* binary’s updates; harder to also sell the same build cheaply on your site without double-charging policy confusion.

#### Free → paid later

If the app is already free on the store:

- Raising to $2.99 only affects **new** purchasers; people who already downloaded free keep the free app.  
- You generally **cannot** force free users to pay for the same listing.  
- Common pattern: keep free listing and add **IAP Pro** (Model B), or ship a new paid app id (discouraged / confusing).

### 3.2 Model B — Free app + $2.99 In-App Purchase (unlock)

App is free to download; **one non-consumable IAP** unlocks “full” features.

| Step | Action |
|------|--------|
| 1 | Same **Paid Apps** agreement + banking/tax as above |
| 2 | App Store Connect → your app → **In-App Purchases** → **Non-Consumable** e.g. `com.markdowner.app.full` at $2.99 |
| 3 | **Code: StoreKit 2** — product fetch, purchase, `Transaction.currentEntitlements`, restore purchases (required expectation for non-consumables) |
| 4 | Gate features clearly **before** purchase (e.g. export PDF, multi-window, packages—whatever you choose). Don’t hide the price. |
| 5 | UI: purchase sheet, **Restore Purchases**, no custom license keys (guideline **2.4.5(vi)** / **3.1.1**) |
| 6 | Review notes: sandbox IAP test account; which features are locked |
| 7 | Privacy / description screenshots must show paid state honestly if you advertise Pro features |

**Pros:** free try; works if you already have free users.  
**Cons:** more code, more review surface, must implement restore.

### 3.3 Model C — Paid outside the App Store ($2.99 on your site)

Only if you distribute a **notarized Developer ID** build (not the Mac App Store binary’s commercial rules the same way):

| Step | Action |
|------|--------|
| 1 | Payment provider (Stripe, Gumroad, Paddle, etc.) — **you** handle tax (VAT/sales tax), refunds, chargebacks |
| 2 | License delivery: email + license key, or signed token, or just “paid customers get download link” |
| 3 | **If the same features are also on the App Store**, don’t use IAP-bypass patterns *inside* a Mac App Store build. Store build must use IAP for digital unlocks. Direct build can use your own licensing. |
| 4 | Optional: separate bundle IDs (`com.markdowner.app` store vs `com.markdowner.app.direct`) to avoid receipt/channel confusion |

**Pros:** higher cut after payment fees; own customer relationship.  
**Cons:** support burden, tax compliance, piracy, no Apple tax handling.

### 3.4 Code checklist if you add IAP (Model B)

Minimal product work:

- [ ] StoreKit 2 purchase + restore  
- [ ] Durable entitlement (App Store forever for that Apple ID; cache locally, re-verify periodically)  
- [ ] Clear locked vs unlocked UX; no dark patterns  
- [ ] Handle Ask to Buy / parental gates if relevant  
- [ ] TestFlight / Sandbox IAP testing before submit  
- [ ] Update privacy labels if purchase flows introduce any analytics (prefer none)  

**Not required for Model A (paid download only).**

### 3.5 Pricing & positioning tips for $2.99

- One-time $2.99 fits a focused local utility; say **“One-time purchase”** in description.  
- Don’t compare to other apps by name in a disparaging way.  
- If free GitHub builds exist, decide:  
  - **Store = stable notarized / supported**, GitHub = source-only, or  
  - **GitHub lags store**, or  
  - **GitHub is free OSS**, store is convenience binary—be transparent so users don’t feel baited.  
- Educational / volume licensing: Mac App Store has limited options; org sales often use Apple Business / volume, or direct licenses (Model C).

### 3.6 Definition of done for $2.99 (Model A)

- [ ] Paid Applications agreement active; banking/tax green  
- [ ] Price set to $2.99 (and currency mappings reviewed)  
- [ ] Listing copy matches paid product  
- [ ] Build approved and released  
- [ ] You can find the app on the Mac App Store with a price badge  

---

## Quick decision tree

```
Ship to other people?
├─ Yes, Mac App Store (free)
│    → Finish §1 code → §2 listing → price Free
├─ Yes, Mac App Store ($2.99 paid download)
│    → Finish §1 → §2 → §3.1 (banking + price tier)
├─ Yes, free download + $2.99 unlock
│    → Finish §1 + StoreKit (§3.2 / §3.4) → §2 → IAP product
└─ Yes, own website only
     → §1 + Developer ID notarization (§2.8) → optional §3.3 payments
```

---

## Related docs

| Doc | Role |
|-----|------|
| [README.md](../README.md) | Build, ad-hoc DMG, features |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the app works (for review notes) |
| [PACKAGES.md](PACKAGES.md) | Zip package behavior |
| [CHANGELOG.md](../CHANGELOG.md) | What’s New copy source |

---

## Suggested order of work

1. **§1.1 P0 code** (UTIs, zip safety, scopes, restoration, privacy manifest, support links)  
2. **Developer Program + Team-signed sandbox QA**  
3. **§2 App Store Connect record** (free first is fine)  
4. **Submit free** or **§3.1 paid $2.99** once banking is ready  
5. Only then consider IAP or dual-channel direct sales  

Questions to decide early:

- Free store listing first, or launch at $2.99?  
- Keep public GitHub DMGs after a paid store launch?  
- Any features held back for “Pro,” or whole app paid?
