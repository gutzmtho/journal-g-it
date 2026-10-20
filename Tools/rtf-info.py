"""Titel und MacJournal-Nummer aus den Dateimerkmalen in die RTF-Datei selbst schreiben ({\\info{\\title …}{\\doccomm …}}).

Grund: iCloud überträgt Dateimerkmale (xattr) nicht zuverlässig. Im RTF-Kopf reisen sie mit der Datei mit,
auch aufs iPhone. MacJournal hat den Titel meist schon dort; er wird nur ergänzt oder angeglichen.
Aufruf: python3 rtf-info.py <Ordner>
"""
import ctypes, os, re, sys

libc = ctypes.CDLL(None, use_errno=True)


def xattr(path, name):
    buf = ctypes.create_string_buffer(4096)
    n = libc.getxattr(os.fsencode(path), name.encode(), buf, 4096, 0, 0)
    return buf.raw[:n].decode("utf-8").strip() if n > 0 else None


def rtf_escape(text):
    out = []
    for ch in text:
        code = ord(ch)
        if ch in "\\{}":
            out.append("\\" + ch)
        elif 32 <= code < 127:
            out.append(ch)
        elif code < 0x10000:
            out.append(f"\\u{code if code < 32768 else code - 65536}?")
        else:  # außerhalb der BMP: als Ersatzpaar
            code -= 0x10000
            for unit in (0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF)):
                out.append(f"\\u{unit - 65536}?")
    return "".join(out)


def update(rtf_path, title, ids):
    raw = open(rtf_path, "rb").read().decode("latin-1")
    fields = ""
    if title:
        fields += "{\\title " + rtf_escape(title) + "}"
    if ids:
        fields += "{\\doccomm macjournal:" + ids + "}"
    if not fields:
        return False
    if "{\\info" in raw:
        start = raw.index("{\\info")
        # Ende der info-Gruppe suchen (Klammern zählen, \{ \} überspringen)
        depth, i = 0, start
        while i < len(raw):
            c = raw[i]
            if c == "\\":
                i += 2
                continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        group = raw[start:i + 1]
        inner = re.sub(r"\{\\title(?:[^{}\\]|\\.)*\}", "", group)
        inner = re.sub(r"\{\\doccomm(?:[^{}\\]|\\.)*\}", "", inner)
        new_group = "{\\info" + fields + inner[len("{\\info"):]
        new = raw[:start] + new_group + raw[i + 1:]
    else:
        m = re.search(r"\\paperw|\\margl|\\vieww|\\pard", raw)
        pos = m.start() if m else raw.index("\n") + 1
        new = raw[:pos] + "{\\info" + fields + "}\n" + raw[pos:]
    if new == raw:
        return False
    st = os.stat(rtf_path)
    open(rtf_path, "wb").write(new.encode("latin-1"))
    os.utime(rtf_path, (st.st_atime, st.st_mtime))  # Änderungsdatum behalten
    return True


changed = 0
for folder, dirs, files in os.walk(sys.argv[1]):
    dirs[:] = [d for d in dirs if not d.startswith(".") and not d.endswith(".rtfd")]
    entries = [n for n in files if n.endswith(".rtf")] + [d for d in os.listdir(folder) if d.endswith(".rtfd")]
    for name in entries:
        path = os.path.join(folder, name)
        rtf = os.path.join(path, "TXT.rtf") if name.endswith(".rtfd") else path
        if os.path.exists(rtf) and update(rtf, xattr(path, "eu.gutzmannit.journalit.title"), xattr(path, "eu.gutzmannit.journalit.id")):
            changed += 1
print(changed, "RTF-Dateien ergänzt")
