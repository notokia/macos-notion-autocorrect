# NotionAutocorrect (macOS · Multi-language)

🌎 **Language:** English | [Português (Brasil)](README.pt-BR.md)

A lightweight, **100% offline** native macOS app (Objective-C · `AppKit` + `ApplicationServices`) that brings **real-time native autocorrect** to **Notion Desktop (`Notion.app`)** — zero setup required.

---

## Why This Exists

The Notion Desktop app for macOS is built on **Electron (Chromium)**. Unlike native Cocoa apps (`NSTextView`), Electron on macOS does not trigger Apple's native `NSSpellChecker` automatic spelling replacement while you type — it only shows red underlines that require right-clicking every word.

## Features (Ready-to-Use)

- **🌐 Zero-Config Smart Language Detection:** Automatically reads your Notion & macOS language preferences and detects in real time whether you are typing in **English (US/UK), Portuguese (BR/PT), Spanish, French, German, or Italian** — or lets you lock a specific language.
- **☁️ Syncs Your macOS / iCloud Text Replacements:** Automatically imports all active shortcuts from *System Settings → Keyboard → Text Replacements*.
- **🍎 Native Apple `NSSpellChecker` Engine:** Fixes typos and missing accents/diacritics locally using Apple's built-in dictionaries (< 1 ms, 100% offline, zero telemetry).
- **🚫 Instant Backspace Undo & Visible Ignored Words List:** Press `Backspace` right after space to undo any unwanted correction — the word is automatically added to your visible **Ignored Words** list (accessible via the **🚫 Ignored Words** button in the app) where you can review, add, or restore words anytime.
- **🧩 Notion-Safe Replacement:** Only replaces the differing suffix of a word so Notion never merges blocks at the start of a line; automatically ignores `/slash` commands, `@mentions`, `` `code` ``, URLs/emails (`example.com`), manual dead-key accents, and uppercase acronyms (`API`, `USA`, `TCC`).
- **⚙️ Launch at Login & Localized UI:** Native control panel automatically translated to your macOS language (EN/PT/ES/FR), with a 1-click **Start automatically at login** toggle.

---

## Installation

### Option 1 — Universal `.dmg` Installer (Apple Silicon + Intel)
Everything is self-contained inside the `.dmg` — no Homebrew, Python, or external dependencies required:
1. Download **`NotionAutocorrect.dmg`** from the [Releases](../../releases) page.
2. Open the `.dmg` and drag **NotionAutocorrect.app** into **Applications**.
3. On first launch, right-click **NotionAutocorrect.app → Open** (or allow it in *System Settings → Privacy & Security*) and toggle **NotionAutocorrect** ON in **System Settings → Privacy & Security → Accessibility**.

### Option 2 — One-Line Terminal Install (Auto-clears Gatekeeper)
```bash
curl -fsSL https://raw.githubusercontent.com/notokia/macos-notion-autocorrect/main/install.sh | zsh
```

### Option 3 — Build from Source
Requires macOS 13.0+ and Xcode Command Line Tools (`xcode-select --install`):
```bash
git clone https://github.com/notokia/macos-notion-autocorrect.git
cd macos-notion-autocorrect
./build.sh
open -a /Applications/NotionAutocorrect.app
```

To generate a universal `.dmg` in `dist/NotionAutocorrect.dmg`:
```bash
./package_dmg.sh
```

---

## Support This Project

If **NotionAutocorrect** saves you time every day, consider giving this repo a ⭐ **Star** or buying me a coffee!

[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/notokia)

> *Disclaimer: This is an independent, open-source utility built for Notion users and is not affiliated with or endorsed by Notion Labs, Inc.*

---

## License

MIT License — see [LICENSE](LICENSE).
