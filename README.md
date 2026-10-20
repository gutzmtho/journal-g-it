# Journal g-IT

[Deutsch](README.de.md) · **English**

A journal and notes app for **Mac and iPhone/iPad**, modelled on MacJournal (which is no longer maintained).
Written in SwiftUI, macOS 15+ and iOS 18+. The app itself is in German.

Entries are **plain files** in folders: Markdown (`.md`, `.txt`) and Rich Text (`.rtf`, `.rtfd` with images).
Folders = journals, files = entries. There is no database of its own, so entries can also be read and written by
other programs (Finder, TextEdit, Obsidian, scripts, AI assistants). Mac and iPhone share them through the app's
iCloud folder.

> Not a product of Dan Schimpf Software and not affiliated with MacJournal. No MacJournal code was used.

## Features

- **Journals and entries:** nested journals; new, rename, move, copy, duplicate, trash.
- **Writing:** Rich Text with fonts, colours, images and attachments; Markdown with a clean reading view. Dictation.
  "Text" menu: checklists (☐/☑ or `- [ ]`), indent, upper/lower case, sort lines, remove duplicate lines, join lines,
  remove mail quotes. Split an entry at the cursor, merge several entries, outlines, audio recording, insert image or file.
  Word count, writing goal, writing timer, focus mode.
- **Organising:** flags, tags, smart journals (rules: text, period, tags, rating, label, status), attributes (rating,
  colour label, mood, status, priority, location with map), templates with placeholders, quick note.
- **Views:** list, month calendar, timeline, map; statistics; windows and tabs. Search across all journals with highlighted
  matches. Links between entries and "Who links here?".
- **Read aloud:** paragraph by paragraph, with adjustable pauses and prepared pronunciation (abbreviations, dates, times).
- **Exchange:** print and PDF, export as text or HTML, "Copy as HTML", import files (Markdown, text, RTF, Word, HTML,
  OpenDocument) and calendar events, create an event or reminder from an entry.
- **Security:** lock journals; **encrypt** journals or single entries (see below); earlier versions of every entry;
  daily backup of all journals as ZIP, with restoring single entries.
- **Migration:** tools in `Tools/` to move a MacJournal library into folders of RTF/RTFD files (titles, dates, images and
  links between entries are kept).

## Where things are stored

| What | Where |
|---|---|
| Entries | `.md`/`.txt`/`.rtf`/`.rtfd` in the app's iCloud folder (or in folders you grant access to) |
| Date, flag, tags, attributes (Markdown) | file header: `datum:`, `markiert: ja`, `tags: [A, B]`, `bewertung: 4`, `ort: …`, `geo: 53.87, 10.69` |
| Title, tags, attributes (Rich Text) | RTF info: `{\info{\title …}{\keywords …}}` |
| Smart journals, locked/encrypted journals | JSON files in the app's iCloud folder |
| Earlier versions, backups | on the device only (the app's Application Support) |

## Encryption

- Each file is encrypted with **AES-256-GCM** (CryptoKit): `JGITENC1` + nonce + ciphertext + tag.
  Name and extension stay; in an `.rtfd` package every file is encrypted.
- One random key, sealed with the password (PBKDF2-SHA256, 600,000 rounds) in `Verschlüsselung.json` in the iCloud folder.
  Unlock with the password (default) or optionally Touch ID / Face ID (the key then lives in the iCloud Keychain;
  a recovery key is shown once as a fallback).
- Content of encrypted entries never goes into the cache. Without the password it is lost.
- Code: `Shared/Vault.swift`, `Shared/JournalLock.swift`.

## Building

Requires Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open JournalIT.xcodeproj
```

Before the first build: copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and enter your own Apple team ID.
In `project.yml`, change the bundle IDs (`eu.gutzmannit.journalit…`), the iCloud container (`iCloud.eu.gutzmannit.journalit`)
and the keychain group.

Layout: `Shared/` (data and views for both), `App/` (Mac), `iOS/` (iPhone/iPad), `Tools/` (helper scripts, icons).

## Licence

MIT, see [LICENSE](LICENSE).
