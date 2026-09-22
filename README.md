<div align="center">
  <img src="resources/logo.png" width="90" alt="Facebook Plus logo">
  <h1>Facebook Plus</h1>

  <p>
    <strong>The ultimate privacy and enhancement tweak for the Facebook iOS app.</strong><br>
    <em>Quieten your feed, watch stories anonymously, download Reels & Stories, confirm interactions, and customize the app's appearance.</em>
  </p>

  <p>
    <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-GPLv3-blue.svg?style=flat-square"></a>
    <img alt="Platform" src="https://img.shields.io/badge/Platform-iOS%2017.0%2B-lightgrey.svg?style=flat-square">
    <img alt="Version" src="https://img.shields.io/badge/Fork%20Version-1.0.1--2-success.svg?style=flat-square">
  </p>
</div>

---

## 🔧 ttlongdl Fork — Local Add-ons

This fork tracks **SHAJON-404/Facebook-Plus** upstream and keeps local changes isolated so upstream updates can be synced with minimal conflicts. The current fork release is **1.0.1-2**: upstream **1.0.1** plus the local add-on revision.

### Local additions

- **DeepLinkBridge** — `addons/DeepLinkBridge.xm` restores exact Facebook link routing for sideloaded builds. It accepts the fork's bridge route (`fb://fbbridge/open?url=...`) and forwards the original Facebook HTTPS URL into Facebook through its browsing-web `NSUserActivity` handler, allowing a Reel/post/photo link to open at the intended destination instead of falling back to Home.
- **FBAudioFix** — `addons/FBAudioFix.xm` reduces unwanted Facebook audio-session takeovers during passive browsing while preserving intentional Facebook media playback. The add-on is compiled directly into `FacebookPlus.dylib`; no separate FBAudioFix dylib is required in the integrated build.
- **Open in Facebook Safari Extension** — `OpenInFacebookSafariExtension/` is the fork's Safari web extension for sideloaded Facebook. It catches supported Facebook links in Safari and hands them to DeepLinkBridge. The extension is built as `OpenInFacebookSafariExtension.appex` when producing a sideloaded IPA.
- **Injection export** — GitHub Actions builds the normal rootless/rootfull `.deb` packages and also exports `FacebookPlus.dylib` + `FacebookPlus.bundle` as a separate injection artifact for TrollFools/manual IPA workflows.

> **External-link behavior in 1.0.1-2:** DeepLinkBridge now signals a short external-navigation window to FBAudioFix. If Facebook actually requests playback while resolving that destination, media is allowed to take over background audio; non-media destinations keep background audio playing. Some complex shared/group links may still resolve to the group/feed rather than the exact post, and links kept inside third-party in-app browsers may bypass the Safari extension entirely.

### Versioning

Fork releases use `<upstream-version>-<addon-revision>`. For example, upstream `1.0.1` + the first local add-on revision is `1.0.1-2`; addon-only changes increment the suffix (the current tested revision is `1.0.1-2`). When upstream moves to a new version, the local suffix starts again at `-1`.

## ✨ Features

<table>
  <thead>
    <tr>
      <th>Category</th>
      <th>Features</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td nowrap>📰 <b>Feed</b></td>
      <td>Remove Ads & Sponsored Posts<br>Hide "People you may know", Group & Page suggestions<br>Remove Reels carousel & Threads promo<br><b>Confirm before liking</b> (prevents accidental likes)</td>
    </tr>
    <tr>
      <td nowrap>🎬 <b>Reels</b></td>
      <td><b>Confirm before liking</b><br>Save <b>Reels</b> to Photos</td>
    </tr>
    <tr>
      <td nowrap>📖 <b>Stories</b></td>
      <td>Watch stories anonymously (Ghost Mode)<br>Disable auto-advance<br>Hide Story Suggestions<br> Save <b>Stories</b> (video & photo) to Photos</td>
    </tr>
    <tr>
      <td nowrap>🧭 <b>Links</b></td>
      <td>Open external links in your <b>default browser</b> instead of the in-app browser<br><b>Open in Facebook</b> Safari extension — reopens facebook.com links from Safari in the app</td>
    </tr>
    <tr>
      <td nowrap>🎨 <b>Appearance</b></td>
      <td><b>OLED Dark Mode</b> (True black)<br>Custom App-Icon Picker (Seamless integration with <code>CFBundleAlternateIcons</code>)</td>
    </tr>
    <tr>
      <td nowrap>🔔 <b>Updates</b></td>
      <td>Built-in <b>update checker</b> — notified in-app when a new version ships, with the changelog and one-tap download from GitHub or Telegram<br>Manual re-check from <b>Settings → Check for Update</b></td>
    </tr>
  </tbody>
</table>

💡 **Settings:** Long-press any **tab bar item** (classic or the new iOS 26 liquid-glass bar) or the **native Facebook settings button**.

---

## 🚀 Installation

Download the pre-built `.ipa` file from the **[Releases](../../releases)** section and install it on your device using **Feather**, **Ksing**, or any other sideloading tool of your choice.

## 🛠️ Building from Source & Automated Injection

This project requires [Theos](https://theos.dev) to build. Ensure you have it installed and configured.

1. **Clone the repository** (including submodules):
   ```bash
   git clone --recursive https://github.com/ttlongdl/Facebook-Plus.git
   cd Facebook-Plus
   ```

2. **Set up Python Environment**:
   Create a virtual environment and install the required tools:
   ```bash
   python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt && pipx install --force https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip && pipx inject --force cyan lief
   ```

3. **Automated Pipeline (`build.sh`)**:
   - Run `./build.sh` to build **every packaging scheme**, or narrow it with the
     `SCHEMES` variable (e.g. `SCHEMES="rootless rootfull" ./build.sh`).
   - To also produce an injected `.ipa`, place a decrypted Facebook `.ipa` at
     `test/com.facebook.Facebook.ipa` before running.

   **What `build.sh` does:**
   - Builds one versioned `.deb` per scheme into `packages/`:

     | Scheme | Output |
     |---|---|
     | `rootless` | `Facebook-Plus-v<version>-rootless.deb` |
     | `rootfull` | `Facebook-Plus-v<version>-rootfull.deb` |

   - If a decrypted `.ipa` is present, injects the **rootless** build into it with
     `cyan` and writes `packages/Facebook-Plus-v<facebook-version>-rootless.ipa`.
     The same `cyan` run also:
     - builds every Safari web extension under `OpenInFacebookSafariExtension/`
       from source and injects the resulting `.appex` into the app's `PlugIns/`;
     - merges any custom app icons (`fbplus_*.png` in `resources/logo/`) into
       `CFBundleAlternateIcons` via `scripts/icon_plist.py`, preserving
       Facebook's native icons;
     - fakesigns every injected binary for sideloading.


<details>
<summary><b>Code Editor Setup</b></summary>

Theos does not emit a compilation database by default, causing editors to fail at finding the iOS SDK. You can generate one using [`bear`](https://github.com/rizsotto/Bear):

```bash
make compile-commands
```

This generates `compile_commands.json`. Re-run this after adding new source files. Note: Logos `.xm` files cannot be fully parsed by clang, so `.clangd` suppresses false diagnostics while ensuring they compile correctly.

</details>

---

## 🏗️ Project Architecture

```text
├── addons              # ttlongdl local add-ons (DeepLinkBridge, FBAudioFix)
├── Localizations       # Translations (ar, bn, de, es, fr, hi, id, it, ja, ko, etc.)
├── OpenInFacebookSafariExtension  # Safari web extension built into PlugIns ("Open in Facebook")
├── resources           # Assets (App icons, SVGs, and asset bundles)
│   ├── bundle          # Compiled UI images and tweak resources
│   ├── logo            # Custom app-icons drop folder for build.sh injection
│   └── svg             # Source vector graphics
├── scripts             # Python utility scripts (e.g., icon merging, svg rendering)
├── src                 # Tweak source code
│   ├── Core            # Constructor, preferences, resources, and diagnostics
│   ├── Features        # All the hooks for modifying the Facebook app:
│   │   ├── AppChrome   # UI settings gesture (TabBar & Settings Button)
│   │   ├── AppIcons    # Custom app-icon picker logic
│   │   ├── Diagnostics # Diagnostics and logging controllers
│   │   ├── Downloads   # Reel & Story media downloaders (save to Photos)
│   │   ├── Feed        # Feed-related hooks (ads, suggestions, Reels)
│   │   ├── Language    # UI language override hooks
│   │   ├── LikeConfirmation # Confirm before liking logic
│   │   ├── Links       # Open external links in the default browser (not the IAB)
│   │   ├── Menu        # Diagnostics for blocking server-driven menu sections
│   │   ├── OLED        # True dark mode implementation
│   │   ├── Onboarding  # Welcome screen controller
│   │   ├── Stories     # Story-related hooks (Ghost mode, auto-advance block)
│   │   └── Update      # In-app update checker + update screen (GitHub Releases)
│   ├── PluginsInject   # Sideload compatibility layer (Keychain / App-Group / CloudKit)
│   ├── Settings        # The Facebook Plus in-app settings UI
│   └── UI              # Shared UI components
│       ├── Sheet       # Bottom sheet controllers
│       └── Toast       # HUD / Progress pills
└── test                # Input IPA directory and test scripts
```

**Resilient Hooking:** Each hook dynamically verifies that its target class and selector exist before installation. If a Facebook update changes a specific class, only that single feature degrades safely without crashing the entire tweak. The settings gesture, for example, hooks both the classic tab bar and the new iOS 26 liquid-glass bars so long-press keeps working across iOS versions.

## 📜 Provenance & Credits

- **Upstream:** This repository is a fork of **SHAJON-404/Facebook-Plus**. The main Facebook Plus feature set and project architecture remain credited to S. SHAJON; fork-specific additions are documented separately above.
- **ttlongdl fork add-ons:** DeepLinkBridge, FBAudioFix integration, the Safari “Open in Facebook” routing workflow, and injection-export workflow are maintained in this fork as local additions.

- **Idea & Inspiration:** The core concept of this tweak was inspired by the closed-source Facebook tweak **[Glow](https://github.com/dayanch96/Glow)**. This project is a clean reimplementation based on its behavioral analysis.
- **Story & Reels Downloader:** The media download feature (`src/Features/Downloads/`) was contributed by **[ttlongdl](https://github.com/ttlongdl/Facebook-Plus)** via their GPLv3 fork, and is integrated here with attribution as required by the license.
- **"Open in Facebook" Safari Extension:** The bundled Safari web extension (`OpenInFacebookSafariExtension/`, built from source into the IPA) is our own, independently written implementation — its own `NSExtension` host, manifest and link-routing scripts, with no third-party binary or source bundled. See `OpenInFacebookSafariExtension/README.md` for details.
- **Compatibility Layer:** The sideloading compatibility layer (`src/PluginsInject/`) is copied and derived directly from **[zxPluginsInject](https://github.com/asdfzxcvbn/zxPluginsInject)**.
- **Symbol Rebinding:** Uses **[fishhook](https://github.com/facebook/fishhook)** for dynamic symbol rebinding.

## ⚖️ License

This project is open-source and distributed under the terms of the **[GNU General Public License v3.0 (GPL-3.0)](LICENSE)**.
Please refer to the `LICENSE` file for more details.

---
<p align="center">
  <b>Copyright &copy; 2026 S. SHAJON</b>
</p>
