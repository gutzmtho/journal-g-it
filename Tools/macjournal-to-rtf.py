"""MacJournal-Export auf die Original-Dateien umstellen: .md → .rtf bzw. .rtfd (Farben und Bilder bleiben).

Ersetzt nur Einträge, die noch genau so sind, wie die Export-Skripte sie geschrieben haben
(macjournal-format.py bzw. macjournal-rtfd.py). Was der Nutzer geändert hat, bleibt Markdown.
Der Titel aus MacJournal (mit „:“, „/“ usw.) kommt in das Dateimerkmal eu.gutzmannit.journalit.title.
Text- und CSS-Einträge bleiben Markdown (dort gibt es keine Formatierung).
Liest nur aus dem MacJournal-Ordner. Aufruf: python3 macjournal-to-rtf.py [--dry]
"""
import importlib.util, os, re, shutil, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fmt = load("macjournal-format")
DOC, EXPORT, CONTENT = fmt.DOC, fmt.EXPORT, os.path.join(fmt.DOC, "Content")
TITLE_ATTR = "eu.gutzmannit.journalit.title"
DRY = "--dry" in sys.argv


def set_title(path, title):
    """Dateimerkmal setzen (über libc; das Programm xattr stolpert über Titel wie „-- files.sql“)."""
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    value = title.encode("utf-8")
    if libc.setxattr(os.fsencode(path), TITLE_ATTR.encode(), value, len(value), 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "setxattr", path)


def rtfd_body(cid):
    """Text, wie macjournal-rtfd.py ihn geschrieben hat (ohne Anhänge zu kopieren)."""
    import urllib.parse
    folder = os.path.join(CONTENT, cid + ".rtfd")
    txt = os.path.join(folder, "TXT.rtf")
    text = fmt.textutil("txt", txt).replace("￼", "").strip() if os.path.exists(txt) else ""
    files = sorted(f for f in os.listdir(folder) if f not in ("TXT.rtf", "MJCustomAttachmentSizes.plist"))
    links = []
    for f in files:
        url = "file://" + urllib.parse.quote(os.path.join(EXPORT, ".Anhänge", cid, f))
        ext = os.path.splitext(f)[1].lower()
        links.append(f"![{f}]({url})" if ext in {".png", ".jpg", ".jpeg", ".gif", ".tiff", ".tif", ".heic"} else f"- Anhang: [{f}]({url})")
    parts = [text] + (["**Anhänge**", "\n\n".join(links)] if links else [])
    return "\n\n".join(p for p in parts if p)


def main():
    import gzip
    xml = gzip.open(os.path.join(DOC, "index.mjml.gz")).read().decode("utf-8")
    items = re.findall(r'<content type="(public\.rtf|com\.apple\.rtfd)" id="([0-9A-F-]+)"', xml)
    print(len(items), "RTF/RTFD-Einträge in MacJournal", flush=True)

    def expected(item):
        kind, cid = item
        try:
            if kind == "public.rtf":
                path = os.path.join(CONTENT, cid + ".rtf")
                return kind, cid, fmt.to_markdown(fmt.textutil("html", path)), fmt.textutil("txt", path)
            return kind, cid, rtfd_body(cid), None
        except Exception as e:  # fehlende Datei o. ä.
            print("übersprungen:", cid, e, file=sys.stderr)
            return kind, cid, None, None

    by_body, by_plain = {}, {}
    with ThreadPoolExecutor(8) as pool:
        for n, (kind, cid, body, plain) in enumerate(pool.map(expected, items), 1):
            if body is not None:
                by_body.setdefault(fmt.squash(body), (kind, cid))
            if plain is not None:
                by_plain.setdefault(fmt.squash(plain), (kind, cid))  # Einträge, die macjournal-format nicht anfasste
            if n % 400 == 0:
                print(n, "gelesen", flush=True)

    done = kept = 0
    for root, dirs, files in os.walk(EXPORT):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in sorted(files):
            if not name.endswith(".md"):
                continue
            path = os.path.join(root, name)
            raw = open(path, encoding="utf-8").read()
            m = re.match(r"---\n(.*?)\n---\n\n# ([^\n]*)\n(.*)", raw, re.S)
            if not m or "quelle: MacJournal" not in m.group(1):
                continue
            title, body = m.group(2).strip(), m.group(3)
            hit = by_body.get(fmt.squash(body)) or by_plain.get(fmt.squash(body))
            if not hit:
                kept += 1
                continue
            kind, cid = hit
            ext = ".rtf" if kind == "public.rtf" else ".rtfd"
            target = os.path.join(root, name[:-3] + ext)
            n = 2
            while os.path.exists(target):
                target = os.path.join(root, f"{name[:-3]} ({n}){ext}"); n += 1
            if not DRY:
                src = os.path.join(CONTENT, cid + ext)
                if ext == ".rtfd":
                    shutil.copytree(src, target)
                else:
                    shutil.copy2(src, target)
                set_title(target, title)
                # Datum wie bisher: aus dem Kopf der .md (steht auch vorne im Dateinamen).
                os.remove(path)
            done += 1
    print(f"{done} auf RTF/RTFD umgestellt, {kept} bleiben Markdown (geändert oder ohne Formatierung)")


if __name__ == "__main__":
    main()
