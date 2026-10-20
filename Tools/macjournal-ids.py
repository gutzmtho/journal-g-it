"""MacJournal-Eintragsnummern an die exportierten Dateien hängen, damit Links macjournal://<id> funktionieren.

Ordnet jede .rtf/.rtfd im MacJournal-Export über ihren Inhalt (Prüfsumme) dem Original in
MacJournal zu und schreibt die Eintragsnummer(n) in das Dateimerkmal eu.gutzmannit.journalit.id
(mehrere durch Komma, wenn Einträge doppelt sind). Liest nur aus dem MacJournal-Ordner.
"""
import ctypes, gzip, hashlib, os, re, xml.etree.ElementTree as ET

DOC = os.path.expanduser("~/Library/Application Support/MacJournal/MacJournal Data.mjdoc")
EXPORT = os.path.expanduser("~/Documents/MacJournal-Export")
ATTR = b"eu.gutzmannit.journalit.id"
libc = ctypes.CDLL(None, use_errno=True)


def digest(path):
    if path.endswith(".rtfd"):
        path = os.path.join(path, "TXT.rtf")
    if not os.path.exists(path):
        return None
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


root = ET.fromstring(gzip.open(os.path.join(DOC, "index.mjml.gz")).read())
by_hash = {}
for entry in root.iter("entry"):
    content = entry.find("content")
    if content is None:
        continue
    ext = {"public.rtf": ".rtf", "com.apple.rtfd": ".rtfd"}.get(content.get("type"))
    if not ext:
        continue
    h = digest(os.path.join(DOC, "Content", content.get("id") + ext))
    if h:
        by_hash.setdefault(h, []).append(entry.get("id"))

tagged = missing = 0
for folder, dirs, files in os.walk(EXPORT):
    dirs[:] = [d for d in dirs if not d.startswith(".") and not d.endswith(".rtfd")]
    names = files + [d for d in os.listdir(folder) if d.endswith(".rtfd")]
    for name in names:
        if not (name.endswith(".rtf") or name.endswith(".rtfd")):
            continue
        path = os.path.join(folder, name)
        ids = by_hash.get(digest(path))
        if not ids:
            missing += 1
            continue
        value = ",".join(ids).encode()
        if libc.setxattr(os.fsencode(path), ATTR, value, len(value), 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "setxattr", path)
        tagged += 1
print(f"{tagged} Dateien mit Eintragsnummer, {missing} ohne Treffer (seitdem geändert)")
