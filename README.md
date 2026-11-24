# YouTube without ads (LDPlayer + iOS IPA)

Two targets, one repo:

| Target | What you get | Status |
| --- | --- | --- |
| **LDPlayer (Android)** | Patched YouTube: no ads, background play, no Premium upsell, full settings | working, script included |
| **iOS IPA** | Tweaked YouTube IPA built on GitHub Actions: no ads, background play, PiP, SponsorBlock | pipeline included, needs your own decrypted IPA |

Everything runs locally / in your own GitHub Actions minutes. Nothing is uploaded anywhere else.

---

## 1. LDPlayer

Verified on LDPlayer 14, Android 14, x86_64, on `E:\LDPlayer\LDPlayer14`.

```powershell
cd ldplayer
.\ytbypass.ps1 -Mode prebuilt
```

That installs a maintained patched build as `app.morphe.android.youtube` **next to** the stock YouTube app (stock stays untouched), plus the microG companion for sign-in.

### Modes

`-Mode prebuilt` (default recommendation)

- Downloads the current patched YouTube build, installs it, installs microG, launches it.
- Works with any YouTube version already in the emulator, because it does not touch it.
- The app appears as a second YouTube icon. Sign in through microG.

`-Mode patch`

- Pulls the YouTube APKs that are installed in the emulator, merges the split APKs into one, runs the patch bundle, signs and installs the result as `com.google.android.youtube`.
- Replaces the stock app, so the icon stays the same.
- **Only works when the installed YouTube version is inside the patch bundle's supported range.** The script tells you when it is not: if the *Hide ads* patch is skipped, the build still shows ads and you should use `-Mode prebuilt`.

Useful switches:

```powershell
.\ytbypass.ps1 -Mode prebuilt -NoInstall        # download only
.\ytbypass.ps1 -Mode patch -ApkPath C:\yt.apk   # patch a specific APK
.\ytbypass.ps1 -Mode patch -PatchesUrl <url>    # different patch bundle
.\ytbypass.ps1 -Device emulator-5554            # pick an instance
```

The script auto-detects `adb.exe`, boots nothing, and downloads a portable JDK if Java is missing.

### After install

1. Open the patched YouTube.
2. Profile picture → **Add account** → the microG sign-in window opens.
3. Settings → the patched settings page has the toggles (ads, background play, shorts, seekbar, and so on).

If playback stutters: LDPlayer settings → give the instance 4+ cores and 4 GB RAM. ARM translation costs performance, the x86_64 native build (`-Mode patch`) is faster when its patches apply.

---

## 2. iOS IPA on GitHub Actions

Workflow: `.github/workflows/build-ipa.yml`

### How it works

The YouTube iOS app cannot be built from source, so the pipeline injects tweaks into a **decrypted YouTube IPA that you supply**:

1. builds the tweaks listed in `ios/scripts/build-tweaks.sh` with Theos
2. injects them with [cyan](https://github.com/asdfzxcvbn/pyzule-rw) (bundles ElleKit, rewrites substrate deps, fakesigns)
3. optionally re-signs with your Apple certificate
4. uploads the finished IPA as an artifact (and optionally a draft release)

Tweaks injected by default:

| Key | Source | What it does |
| --- | --- | --- |
| `ytlite` | [dayanch96/YTLite](https://github.com/dayanch96/YTLite) | ad removal, background playback, UI cleanup — the main Premium-style payload |
| `pip` | [PoomSmart/YouPiP](https://github.com/PoomSmart/YouPiP) | picture-in-picture |
| `ytbypass` | this repo | network-level ad/tracking blocker (doubleclick, `/pageid/`, `/api/stats/ads` …), defence in depth for promoted content that slips past the player hooks |

Your IPA must be **decrypted** (`cryptid == 0`). Dump it from a device you own, for example with `frida-ios-dump` on a jailbroken iPhone. The workflow checks this and stops with a clear error if the binary is still App Store encrypted.

### Run it

1. Push this repo (already done if you are reading it on GitHub).
2. Repo → Settings → Secrets and variables → Actions:

   | Secret | Required | Contents |
   | --- | --- | --- |
   | `YOUTUBE_IPA_URL` | yes | direct download URL of your decrypted YouTube `.ipa` |
   | `SIGN_P12` | no | base64 of your `.p12` (cert + key) |
   | `SIGN_P12_PASSWORD` | no | password of that `.p12` |
   | `SIGN_PROFILE` | no | base64 of your `.mobileprovision` |

3. Actions → **build-ipa** → *Run workflow*.

Inputs:

- `ipa_url` — overrides `YOUTUBE_IPA_URL`
- `tweaks` — `ytlite,pip,ytbypass` (drop any you do not want)
- `app_name`, `bundle_id` — rename the app / give it a second bundle id so it can sit next to the real one
- `sign` — use the `SIGN_*` secrets instead of fakesigning
- `release` — attach the IPA to a draft release instead of only an artifact

Without an IPA URL the run still succeeds: it compiles the tweaks and uploads them as the `YouTube-tweaks` artifact, so you can see the toolchain is healthy and inject them yourself later.

### Installing the IPA

- **TrollStore** (iOS 14.0–16.6.1 / 17.0): install the fakesigned IPA directly.
- **Sideloadly / AltStore / SideStore**: drag the IPA in, sign with your Apple ID. Free accounts expire after 7 days.
- **Paid developer account**: set the `SIGN_*` secrets and turn on `sign`, the artifact is already signed.

### What is not possible

YouTube Premium *downloads* and the "Premium" badge are server-side entitlements tied to your account. No client patch creates them. Everything else in this repo is client-side: ads, background audio, PiP, SponsorBlock, UI.

---

## Repository layout

```
.github/workflows/build-ipa.yml   iOS pipeline (Theos + cyan + optional codesign)
ios/scripts/build-tweaks.sh       builds ytlite / YouPiP / YTBypass dylibs
ios/scripts/sign.sh               p12 + mobileprovision re-signing
ios/tweaks/                       YTBypass tweak (Logos, NSURLProtocol ad blocker)
ldplayer/ytbypass.ps1             LDPlayer install/patch script
```

## Troubleshooting

**"could not pull … (adbd is probably not root)"** — the script runs `adb root` itself; if your build refuses, enable root in LDPlayer settings and rerun.

**`-Mode patch` produces an app that still shows ads** — the installed YouTube is newer than the patch bundle. Use `-Mode prebuilt`, or pass `-ApkPath` with a YouTube APK the bundle lists as supported.

**iOS build: "no Payload/\*.app"** — the URL does not point at a real IPA. Use a direct file link, not a landing page.

**iOS build: "still App Store encrypted"** — you gave it an App Store IPA. Decrypt it first.

**Injected app crashes on launch** — bundle id and minimum iOS must stay compatible with the YouTube build you supplied; try `tweaks: ytbypass` alone to isolate which tweak is at fault, then check `idevicesyslog`.

## Notes

- Patch bundles, tweak sources and the prebuilt Android app are third-party projects; pin or audit them if that matters to you.
- Nothing here bypasses DRM or server-side entitlements.
