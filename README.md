<div align="center">
  <img src="resources/logo.png" width="90" alt="Facebook Plus logo">
  <h1>Facebook Plus</h1>

  <p>
    <strong>The ultimate privacy and enhancement tweak for the Facebook iOS app.</strong><br>
    <em>Quieten your feed, watch stories anonymously, download Reels & Stories, block incoming calls, confirm interactions, and customize the app's appearance.</em>
  </p>

  <p>
    <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-GPLv3-blue.svg?style=flat-square"></a>
    <img alt="Platform" src="https://img.shields.io/badge/Platform-iOS%2017.0%2B-lightgrey.svg?style=flat-square">
    <img alt="Version" src="https://img.shields.io/badge/Version-1.0.3--1-success.svg?style=flat-square">
  </p>
</div>

---

**Fork release: v1.0.3-1** — based on the newer upstream source snapshot (including Call Blocker, full-screen settings and rewritten LinkBridge), with selectively restored Story/Reels fixes, Vietnamese selector and FBAudioFix deep-link notification. The release number is the fork's independent version identifier, not the upstream source commit version. Tested as a signed triple-tweak IPA on Facebook 585.0.0: Safari Open in Facebook, FBAudioFix background audio, Story/Reels downloads and Files sharing. Rootless, Rootfull and RootHide DEBs passed GitHub Actions compilation; on-device DEB installation has not yet been verified. FBAudioFix and ShopeeBlocker remain standalone, not embedded in Facebook-Plus.

**Release automation:** [Publish fork DEBs](.github/workflows/release-fork.yml) creates three versioned packages and GitHub tag `v1.0.3-1`. The [APT publisher](https://github.com/ttlongdl/repo/actions/workflows/publish-fbplus-roothide.yml) and [triple-tweak IPA patcher](https://github.com/ttlongdl/Facebook-IPA-Patcher/actions/workflows/patch-facebook.yml) are separate manual workflows. The IPA patcher names output `FB <Facebook version> Plus v1.0.3-1 (Triple-Tweak).ipa` and enables Files sharing.

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
      <td>Remove Ads & Sponsored Posts<br>Hide "People you may know", Group & Page suggestions<br>Remove Reels carousel, Threads promo & <b>Stories</b> (tray + single cards)<br><b>Confirm before liking</b> (prevents accidental likes)</td>
    </tr>
    <tr>
      <td nowrap>🎬 <b>Reels</b></td>
      <td><b>Confirm before liking</b><br><b>Hide overlay</b> — one tap strips likes, comments, share & caption, leaving just the clean video<br>Save <b>Reels</b> to Photos</td>
    </tr>
    <tr>
      <td nowrap>📖 <b>Stories</b></td>
      <td>Watch stories anonymously (Ghost Mode)<br>Disable auto-advance<br>Hide Story Suggestions<br>Save <b>Stories</b> (video & photo) to Photos</td>
    </tr>
    <tr>
      <td nowrap>📞 <b>Calls & Privacy</b></td>
      <td><b>Incoming Call Blocker</b> — silently block incoming VoIP / Messenger calls inside Facebook without disturbing your app experience</td>
    </tr>
    <tr>
      <td nowrap>🧭 <b>Links</b></td>
      <td>Open external links in your <b>default browser</b> instead of the in-app browser<br><b>Open in Facebook</b> Safari extension — reopens facebook.com links from Safari in the app, routing directly to the <b>exact Reel / post / photo / story destination</b> (including FaceWeb deep links)</td>
    </tr>
    <tr>
      <td nowrap>🎨 <b>Appearance</b></td>
      <td><b>OLED Dark Mode</b> (true black — preserves post dividers, rounded avatars & status bar legibility)<br>Custom App-Icon Picker with multiple alternate icons</td>
    </tr>
    <tr>
      <td nowrap>🔔 <b>Updates</b></td>
      <td>Built-in <b>update checker</b> — notified in-app when a new version ships, with the changelog and one-tap download from GitHub or Telegram<br>Manual re-check from <b>Settings → Check for Update</b></td>
    </tr>
  </tbody>
</table>

💡 **Dedicated Settings Page:** Access the dedicated full-screen tweak settings anytime by long-pressing any **tab bar item** (classic or modern liquid-glass bar), long-pressing the **"facebook" wordmark**, or via the **native Facebook settings entry**.

---

## 🗺️ Roadmap & Credits

Planned features and fixes, together with the project's provenance and credits,
are documented in **[ROADMAP_AND_CREDITS.md](ROADMAP_AND_CREDITS.md)**.
Contributions and suggestions are welcome — open an issue or a pull request.

---

## 🔒 Security & Disclaimer

Please read **[SECURITY.md](SECURITY.md)** for our security policy, account safety guidelines, and disclaimer of warranty/liability. Use Facebook Plus at your own risk.

---

## 🚀 Install Facebook Plus v1.0.3-1

This is the **ttlongdl fork** of [SHAJON-404/Facebook-Plus](https://github.com/SHAJON-404/Facebook-Plus). It retains the newer upstream Call Blocker, full-screen settings, and rewritten LinkBridge, with selected fork fixes for Story/Reels, Vietnamese language selection, and a notification used by standalone FBAudioFix. The fork version `1.0.3-1` is independent of the upstream source version.

- **Jailbroken devices:** Download [v1.0.3-1 DEBs](https://github.com/ttlongdl/Facebook-Plus/releases/tag/v1.0.3-1) for Rootless, Rootfull, or RootHide. Rootless (`iphoneos-arm64`) and RootHide (`iphoneos-arm64e`) are also published to the [ttlongdl APT repository](https://github.com/ttlongdl/repo).
- **Sideloaded Facebook:** Use the [Facebook IPA Patcher](https://github.com/ttlongdl/Facebook-IPA-Patcher), which injects Facebook Plus, **standalone** FBAudioFix 0.3.20, standalone ShopeeBlocker, and the Safari **Open in Facebook** extension into a decrypted Facebook IPA supplied by the user. The output uses `FB <Facebook-version> Plus v<FBPlus-version>.ipa`; for example, `FB 585.0.0 Plus v1.0.3-1.ipa`. Sign the IPA and its extension with Feather or another compatible signer.
- **Feather personal source:** The [Sync Feather Source workflow](https://github.com/ttlongdl/Facebook-IPA-Patcher/actions/workflows/sync-feather-source.yml) updates [personal-source.json](https://github.com/ttlongdl/feather/blob/main/personal-source.json) separately after the IPA is published.

**Compatibility and test status:** Rootless, Rootfull, and RootHide packages passed GitHub Actions builds. A signed Facebook 585.0.0 triple-tweak test IPA passed on-device checks for Safari deep links, FBAudioFix background playback, Story/Reels downloads, and Files app visibility. DEB runtime behavior and other Facebook/iOS versions may differ. The standalone audio and Shopee tweaks are **not included** in Facebook Plus DEBs.

**Files sharing:** The triple-tweak IPA Patcher enables `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` in the Facebook app's `Info.plist`. This exposes the app's Documents folder in Files, not its entire sandbox.

## ⚡ GitHub Actions workflows

| Workflow | Purpose |
|---|---|
| [Build Tweak (.deb)](.github/workflows/build.yml) | CI compile checks for Rootless / Rootfull |
| [Build Facebook Plus RootHide DEB](.github/workflows/build-roothide.yml) | RootHide compile checks |
| [Publish Facebook Plus fork DEBs](.github/workflows/release-fork.yml) | Manual versioned GitHub release of three DEBs |
| [Test Triple-Tweak Facebook IPA](.github/workflows/test-triple-ipa.yml) | Manual unsigned IPA integration test; does **not** publish a release |
| [Facebook IPA Patcher](https://github.com/ttlongdl/Facebook-IPA-Patcher/actions/workflows/patch-facebook.yml) | Release-driven IPA creation from a user-provided decrypted Facebook IPA |

The `release-fork.yml` workflow requires a `control` version in `major.minor.patch-build` format and publishes a tag `v<version>`. To update the APT source, run the separate [APT publishing workflow](https://github.com/ttlongdl/repo/actions/workflows/publish-fbplus-roothide.yml) **after** the DEB release succeeds.

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
   - Run `./build.sh` to build the default schemes, or narrow it with the
     `SCHEMES` variable (e.g. `SCHEMES="rootless rootfull" ./build.sh`).
   - To also produce an injected `.ipa`, place a decrypted Facebook `.ipa` at
     `test/com.facebook.Facebook.ipa` before running.

   **What `build.sh` does:**
   - Builds one versioned `.deb` per scheme into `packages/`:

     | Scheme | Output |
     |---|---|
     | `rootless` | `Facebook-Plus-v<version>-rootless.deb` |
     | `rootfull` | `Facebook-Plus-v<version>-rootfull.deb` |
     | `roothide` | `Facebook-Plus-v<version>-roothide.deb` (RootHide Theos required) |

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

Theos does not emit a compilation database by default, causing editors to fail at finding the iOS SDK. Generate one with [`bear`](https://github.com/rizsotto/Bear):

```bash
make compile-commands
```

This writes a per-machine `.clangd` (with your theos path and SDK baked in) and a `compile_commands.json`. The database is produced with `bear parse-sh` from theos's own dry-run (`make -n`) rather than by intercepting the build, because macOS strips the interception mechanism (`DYLD_INSERT_LIBRARIES`) from the Xcode toolchain's Apple-signed clang, leaving a plain `bear -- make` empty. Re-run it after adding new source files. Note: Logos `.xm` files cannot be fully parsed by clang, so `.clangd` suppresses false diagnostics while ensuring they compile correctly.

</details>

---

## 🏗️ Project Architecture

```text
├── Localizations       # Translations (ar, bn, de, es, fr, hi, id, it, ja, ko, zh-Hant, etc.)
├── OpenInFacebookSafariExtension  # Safari web extension built into PlugIns ("Open in Facebook")
├── resources           # Assets (App icons, SVGs, and asset bundles)
│   ├── bundle          # Compiled UI images and tweak resources
│   ├── logo            # Custom app-icons drop folder for build.sh injection
│   └── svg             # Source vector graphics
├── scripts             # Python utility scripts (e.g., icon merging, svg rendering)
├── src                 # Tweak source code
│   ├── Core            # Constructor, preferences, and resources
│   ├── Features        # All hooks & feature implementations:
│   │   ├── AppChrome   # UI settings gesture (TabBar, Wordmark long-press & Settings Button)
│   │   ├── AppIcons    # Custom app-icon picker logic
│   │   ├── Calls       # Incoming Call Blocker (PushKit & CallKit interceptors)
│   │   ├── Downloads   # Reel & Story media downloaders (save to Photos)
│   │   ├── Feed        # Feed-related hooks (ads, suggestions, Reels, Stories removal)
│   │   ├── Language    # UI language override hooks
│   │   ├── LikeConfirmation # Confirm before liking logic
│   │   ├── Links       # Open external links in default browser & inbound link bridge
│   │   ├── OLED        # True black dark mode implementation
│   │   ├── Onboarding  # Welcome screen controller
│   │   ├── Stories     # Story-related hooks (Ghost mode, auto-advance block)
│   │   └── Update      # In-app update checker + update screen (GitHub Releases)
│   ├── PluginsInject   # Sideload compatibility layer (Keychain / App-Group / CloudKit)
│   ├── Settings        # Dedicated full-screen Facebook Plus settings UI
│   └── UI              # Shared UI components
│       ├── Sheet       # Detent & Presentation controllers
│       └── Toast       # HUD / Progress pills
└── test                # Input IPA directory and test scripts
```

**Resilient Hooking:** Each hook dynamically verifies that its target class and selector exist before installation. If a Facebook update changes a specific class, only that single feature degrades safely without crashing the entire tweak. The settings gesture, for example, hooks both the classic tab bar and the new iOS 26 liquid-glass bars so long-press keeps working across iOS versions.

## 📜 Provenance & Credits

Third-party code, inspirations, and attributions are documented in
**[ROADMAP_AND_CREDITS.md](ROADMAP_AND_CREDITS.md)**.

## ⚖️ License

This project is open-source and distributed under the terms of the **[GNU General Public License v3.0 (GPL-3.0)](LICENSE)**.
Please refer to the `LICENSE` file for more details.

---
<p align="center">
  <b>Copyright &copy; 2026 S. SHAJON</b>
</p>
