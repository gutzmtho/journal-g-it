# Journal g-IT

Ein Tagebuch- und Notizprogramm für **Mac und iPhone/iPad**, nach dem Vorbild von MacJournal (wird nicht mehr gepflegt).
Geschrieben in SwiftUI, macOS 15+ und iOS 18+.

Die Einträge sind **gewöhnliche Dateien** in Ordnern: Markdown (`.md`, `.txt`) und Rich Text (`.rtf`, `.rtfd` mit Bildern).
Ordner = Journale, Dateien = Einträge. Es gibt keine eigene Datenbank. Darum lassen sich die Einträge auch mit anderen
Programmen (Finder, TextEdit, Obsidian, Skripte, KI-Assistenten) lesen und schreiben. Mac und iPhone teilen sie über
den iCloud-Ordner der App.

> Kein Produkt von Dan Schimpf Software und nicht mit MacJournal verbunden. Kein Code von MacJournal übernommen.

## Funktionen

- **Journale und Einträge:** verschachtelte Journale, neu, umbenennen, verschieben, kopieren, duplizieren, Papierkorb.
- **Schreiben:** Rich Text mit Schrift, Farben, Bildern und Anhängen; Markdown mit schöner Leseansicht. Diktieren.
  Menü „Text“: Checklisten (☐/☑ bzw. `- [ ]`), Einrücken, Groß/klein, Zeilen sortieren, doppelte Zeilen entfernen,
  Zeilenumbrüche, Mail-Zitate. Eintrag an der Cursor-Stelle teilen, mehrere Einträge zusammenführen, Gliederung,
  Tonaufnahme, Bild oder Datei einfügen. Wortzahl, Schreibziel, Schreib-Timer, Fokus-Modus.
- **Ordnen:** Fahne, Schlagwörter, intelligente Journale (Regeln: Text, Zeitraum, Schlagwörter, Bewertung, Etikett, Status),
  Merkmale (Bewertung, Farb-Etikett, Stimmung, Status, Priorität, Ort mit Karte), Vorlagen mit Platzhaltern, Schnellnotiz.
- **Ansichten:** Liste, Monatskalender, Zeitleiste, Karte; Statistik; Fenster und Tabs. Suche in allen Journalen mit Markierung
  der Fundstellen. Links zwischen Einträgen und „Wer verlinkt hierher?“.
- **Vorlesen:** absatzweise, mit einstellbaren Pausen und aufbereiteter Aussprache (Abkürzungen, Daten, Uhrzeiten).
- **Austausch:** Drucken und PDF, Export als Text oder HTML, „Als HTML kopieren“, Import von Dateien (Markdown, Text, RTF,
  Word, HTML, OpenDocument) und von Kalender-Terminen, Termin oder Erinnerung aus einem Eintrag.
- **Sicherheit:** Journale sperren; Journale oder einzelne Einträge **verschlüsseln** (siehe unten); frühere Versionen
  jedes Eintrags; tägliche Sicherung aller Journale als ZIP.
- **Mitnehmen:** Werkzeuge in `Tools/`, um eine MacJournal-Bibliothek in Ordner mit RTF/RTFD-Dateien zu übertragen
  (Titel, Datum, Bilder, Links zwischen Einträgen bleiben).

## Wo was gespeichert wird

| Was | Wo |
|---|---|
| Einträge | `.md`/`.txt`/`.rtf`/`.rtfd` im iCloud-Ordner der App (oder in freigegebenen Ordnern) |
| Datum, Fahne, Schlagwörter, Merkmale (Markdown) | Kopf der Datei: `datum:`, `markiert: ja`, `tags: [A, B]`, `bewertung: 4`, `ort: …`, `geo: 53.87, 10.69` |
| Titel, Schlagwörter, Merkmale (Rich Text) | RTF-Kopf: `{\info{\title …}{\keywords …}}` |
| Intelligente Journale, gesperrte/verschlüsselte Journale | JSON-Dateien im iCloud-Ordner der App |
| Frühere Versionen, Sicherungen | nur auf dem Gerät (Programm-Support der App) |

## Verschlüsselung

- Jede Datei wird mit **AES-256-GCM** (CryptoKit) verschlüsselt: `JGITENC1` + Nonce + Text + Prüfsumme.
  Name und Endung bleiben; bei `.rtfd` ist jede Datei im Paket verschlüsselt.
- Ein zufälliger Schlüssel; er liegt, mit dem Passwort verschlossen (PBKDF2-SHA256, 600.000 Runden), in
  `Verschlüsselung.json` im iCloud-Ordner. Zum Öffnen das Passwort (Vorgabe) oder wahlweise Touch ID / Face ID
  (dann liegt der Schlüssel im iCloud-Schlüsselbund; zum Ersatz gibt es einen Wiederherstellungsschlüssel).
- Der Inhalt verschlüsselter Einträge kommt nie in den Zwischenspeicher. Ohne Passwort ist er verloren.
- Code: `Shared/Vault.swift`, `Shared/JournalLock.swift`.

## Bauen

Voraussetzung: Xcode 27 und [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open JournalIT.xcodeproj
```

Vor dem ersten Bauen: `Config/Local.xcconfig.example` nach `Config/Local.xcconfig` kopieren und die eigene Team-ID von Apple
eintragen. In `project.yml` die Bundle-IDs (`eu.gutzmannit.journalit…`), den iCloud-Container (`iCloud.eu.gutzmannit.journalit`)
und die Schlüsselbund-Gruppe anpassen.

Aufbau: `Shared/` (Daten, Ansichten für beide), `App/` (Mac), `iOS/` (iPhone/iPad), `Tools/` (Hilfsskripte, Symbole).

## Lizenz

MIT, siehe [LICENSE](LICENSE).
