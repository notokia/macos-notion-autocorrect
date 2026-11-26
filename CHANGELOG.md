# Changelog

## [v2.3.0] - 2026-11-23

### Added
- **Native Dead-Key Keyboard Composition (`UCKeyTranslate`):** Full support for international & dead-key keyboard layouts (such as *US-International*, *Brazilian - Pro*, *Spanish*, and *French* layouts) so words typed with manual accents/cedillas (`' + c → ç`, `~ + a → ã`, `^ + e → ê`) are accurately tracked and corrected when containing typos.
- **Smarter `NSSpellChecker` Fallback Engine:** Added Damerau-Levenshtein edit-distance scoring over dictionary suggestions when macOS `correctionForWordRange:` returns `nil` or invalid synthetic forms, catching significantly more real-world typing errors without introducing false positives.
- **Expanded Punctuation Delimiters:** Words followed by `:`, `)`, `]`, and closing quotes (`"`, `”`) are now automatically corrected (e.g., `Introduction:` or `(recieve)`), while preserving URL schemes (`http:`, `https:`, `mailto:`).
- **Auto-Hide from Dock / `Cmd+Tab` When Closed:** Closing the Control Panel window (`Cmd+W` or red `X`) now switches the app to background accessory mode so it won't be accidentally quit while closing apps, reappearing whenever opened from Spotlight, Applications, or the Menu Bar.

### Fixed
- **Mid-Word Cursor Edit Protection:** Navigating with arrow keys (`←`/`→`) or pressing `Backspace` into a previous word now safely skips autocorrect until the next word boundary so existing word suffixes are never altered.
- **Expanded Portuguese Homograph Dictionary:** Added 25+ high-frequency Portuguese words whose unaccented forms were previously skipped due to rare verb homographs in Apple's dictionary.

---

## [v2.2.1] - 2026-11-19

- Initial public release with zero-config multi-language detection, macOS/iCloud Text Replacements sync, 1-Backspace Undo + visible Ignored Words manager, Notion-safe suffix replacement, custom AppIcon, and Universal `.dmg` installer.
