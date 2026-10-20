"""MacJournal-Export nachbessern: Einträge mit Platzhalter „nicht umgewandelt“ (RTFD, Text, CSS) füllen.

Liest nur aus dem MacJournal-Datenordner. Anhänge (Bilder, PDFs …) kommen nach
~/Documents/MacJournal-Export/.Anhänge/<id>/ und werden im Eintrag verlinkt.
"""
import os, re, shutil, subprocess, sys, urllib.parse

CONTENT = os.path.expanduser("~/Library/Application Support/MacJournal/MacJournal Data.mjdoc/Content")
EXPORT = os.path.expanduser("~/Documents/MacJournal-Export")
STORE = os.path.join(EXPORT, ".Anhänge")
PLACEHOLDER = re.compile(r"_\(Inhalt vom Typ (\S+) – nicht umgewandelt, liegt in MacJournal: ([0-9A-F-]+)\)_")
IMAGES = {".png", ".jpg", ".jpeg", ".gif", ".tiff", ".tif", ".heic"}


def rtf_text(path):
    # Immer -stdout: sonst schreibt textutil neben das Original in den MacJournal-Ordner.
    out = subprocess.run(["textutil", "-convert", "txt", "-stdout", path], capture_output=True, text=True)
    return out.stdout.replace("￼", "").strip()


def content_for(kind, ident):
    if kind == "com.apple.rtfd":
        folder = os.path.join(CONTENT, ident + ".rtfd")
        text = rtf_text(os.path.join(folder, "TXT.rtf")) if os.path.exists(os.path.join(folder, "TXT.rtf")) else ""
        files = sorted(f for f in os.listdir(folder) if f not in ("TXT.rtf", "MJCustomAttachmentSizes.plist"))
        links = []
        if files:
            dest = os.path.join(STORE, ident)
            os.makedirs(dest, exist_ok=True)
            for f in files:
                src = os.path.join(folder, f)
                if os.path.isdir(src):  # z. B. eingebettete .rtfd-Dokumente
                    shutil.copytree(src, os.path.join(dest, f), dirs_exist_ok=True)
                else:
                    shutil.copy2(src, os.path.join(dest, f))
                url = "file://" + urllib.parse.quote(os.path.join(dest, f))
                if os.path.splitext(f)[1].lower() in IMAGES:
                    links.append(f"![{f}]({url})")
                else:
                    links.append(f"- Anhang: [{f}]({url})")
        parts = [text] + (["**Anhänge**", "\n\n".join(links)] if links else [])
        return "\n\n".join(p for p in parts if p)
    ext = {"public.plain-text": ".txt", "public.css": ".css"}.get(kind)
    path = os.path.join(CONTENT, ident + ext) if ext else None
    if not path or not os.path.exists(path):
        return None
    text = open(path, encoding="utf-8", errors="replace").read().strip()
    return f"```css\n{text}\n```" if ext == ".css" else text


done = missing = 0
for root, dirs, files in os.walk(EXPORT):
    dirs[:] = [d for d in dirs if not d.startswith(".")]
    for name in files:
        if not name.endswith(".md"):
            continue
        path = os.path.join(root, name)
        raw = open(path, encoding="utf-8").read()
        m = PLACEHOLDER.search(raw)
        if not m:
            continue
        body = content_for(m.group(1), m.group(2))
        if body is None:
            missing += 1
            print("fehlt:", path, file=sys.stderr)
            continue
        new = PLACEHOLDER.sub(lambda _: body, raw, count=1)
        # Überschrift, die aus dem Platzhalter entstanden ist, durch den Dateinamen ersetzen.
        title = re.sub(r"^\d{4}-\d{2}-\d{2} ", "", name[:-3])
        new = re.sub(r"^# _\(Inhalt vom Typ.*$", "# " + title, new, count=1, flags=re.M)
        open(path, "w", encoding="utf-8").write(new)
        done += 1
print(done, "Einträge ergänzt,", missing, "nicht gefunden")
