"""MacJournal-Export mit Formatierung neu schreiben.

Der erste Export nahm nur reinen Text (textutil -convert txt). Dabei gingen Schreibmaschinenschrift
(Courier usw.), fett, kursiv, Listen und Zeilenumbrüche verloren. Dieses Skript liest jedes RTF
noch einmal als HTML (textutil -convert html -stdout) und macht daraus Markdown:
  - Absätze ganz in Schreibmaschinenschrift → Code-Block ```
  - einzelne Wörter in Schreibmaschinenschrift → `Code`
  - fett/kursiv → **…** / *…*, Listen → „- “, Links → [Text](URL), Tabellen → Markdown-Tabelle
Farben gibt es in Markdown nicht; sie fallen weg.

Nur Einträge, deren Text noch genau dem ersten Export entspricht, werden ersetzt.
Was der Nutzer seitdem geändert hat, bleibt unberührt. Liest nur aus dem MacJournal-Ordner.
Aufruf: python3 macjournal-format.py [--test <content-id>]
"""
import gzip, html, os, re, subprocess, sys
from html.parser import HTMLParser
from concurrent.futures import ThreadPoolExecutor

DOC = os.path.expanduser("~/Library/Application Support/MacJournal/MacJournal Data.mjdoc")
EXPORT = os.path.expanduser("~/Documents/MacJournal-Export")
MONO = re.compile(r"courier|monaco|menlo|mono|consola|lucida console|andale|ocr|fixed", re.I)


def textutil(fmt, path):
    # Immer -stdout: sonst schreibt textutil neben das Original in den MacJournal-Ordner.
    return subprocess.run(["textutil", "-convert", fmt, "-stdout", path], capture_output=True, text=True).stdout


class Converter(HTMLParser):
    """Liest das HTML von textutil Absatz für Absatz."""

    def __init__(self, styles):
        super().__init__(convert_charrefs=True)
        self.styles = styles          # Klasse → ist Schreibmaschinenschrift?
        self.lines = []               # (art, text): art = "text" | "code" | "item" | "blank" | "table"
        self.stack = []               # offene Tags mit Eigenschaften
        self.runs = None              # [(text, mono, bold, italic, href)]
        self.para_mono = False
        self.list_depth = 0
        self.table = None
        self.row = None

    def flags(self):
        mono = self.para_mono
        bold = italic = False
        href = None
        for tag, attrs in self.stack:
            cls = attrs.get("class", "")
            if cls in self.styles:
                mono = self.styles[cls]
            if tag == "b" or tag == "strong":
                bold = True
            if tag == "i" or tag == "em":
                italic = True
            if tag == "a" and attrs.get("href"):
                href = attrs["href"]
        return mono, bold, italic, href

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ("p", "li", "td", "th"):
            if tag == "p" and self.table is not None and self.row is not None:
                return  # Absätze in Tabellenzellen gehören zur Zelle
            self.runs = []
            self.para_mono = self.styles.get(attrs.get("class", ""), False)
            self.kind = "item" if tag == "li" else "text"
        elif tag in ("ul", "ol"):
            self.list_depth += 1
        elif tag == "table":
            self.table = []
        elif tag == "tr":
            self.row = []
        elif tag == "br" and self.runs is not None:
            self.runs.append(("\n", self.flags()[0], False, False, None))
        if tag not in ("br", "img", "meta"):
            self.stack.append((tag, attrs))

    def handle_endtag(self, tag):
        while self.stack:
            t, _ = self.stack.pop()
            if t == tag:
                break
        if tag in ("td", "th") and self.row is not None:
            self.row.append(render_inline(self.runs or []).replace("\n", " ").replace("|", "\\|"))
            self.runs = None
        elif tag == "tr" and self.table is not None:
            self.table.append(self.row or [])
            self.row = None
        elif tag == "table":
            if self.table:
                self.lines.append(("table", self.table))
            self.table = None
        elif tag in ("p", "li") and self.runs is not None and self.row is None:
            self.finish_paragraph()
        elif tag in ("ul", "ol"):
            self.list_depth -= 1

    def handle_data(self, data):
        if self.runs is None:
            return
        mono, bold, italic, href = self.flags()
        self.runs.append((data, mono, bold, italic, href))

    def finish_paragraph(self):
        runs, self.runs = self.runs, None
        text = "".join(r[0] for r in runs)
        for part in split_runs(runs):
            plain = "".join(r[0] for r in part)
            if not plain.strip():
                self.lines.append(("blank", ""))
            elif self.kind == "item":
                self.lines.append(("item", "  " * max(self.list_depth - 1, 0) + "- " + render_inline(part).strip()))
                self.kind = "text"  # Zeilenumbrüche im Punkt: Rest als Text
            elif all(r[1] for r in part if r[0].strip()):
                self.lines.append(("code", plain.rstrip()))
            else:
                self.lines.append(("text", render_inline(part)))
        if not text:
            self.lines.append(("blank", ""))


def split_runs(runs):
    """Ein Absatz mit <br> wird zu mehreren Zeilen."""
    parts, cur = [], []
    for r in runs:
        pieces = r[0].split("\n")
        for i, p in enumerate(pieces):
            if i > 0:
                parts.append(cur)
                cur = []
            if p:
                cur.append((p,) + r[1:])
    parts.append(cur)
    return parts


def render_inline(runs):
    """Fett, kursiv, `Code` und Links für eine Zeile; gleiche Nachbarn zusammenfassen."""
    merged = []
    for text, mono, bold, italic, href in runs:
        key = (mono, bold and not mono, italic and not mono, href)
        if merged and merged[-1][1] == key:
            merged[-1][0] += text
        else:
            merged.append([text, key])
    out = []
    for text, (mono, bold, italic, href) in merged:
        core = text.strip()
        if not core:
            out.append(text)
            continue
        lead = text[: len(text) - len(text.lstrip())]
        trail = text[len(text.rstrip()):]
        if mono:
            core = f"``{core}``" if "`" in core else f"`{core}`"
        else:
            core = re.sub(r"([*_\\])", r"\\\1", core)
            if italic:
                core = f"*{core}*"
            if bold:
                core = f"**{core}**"
        if href:
            core = f"[{core}]({href})"
        out.append(lead + core + trail)
    return re.sub(r"[ \t]+$", "", "".join(out))


def to_markdown(html_text):
    styles = {}
    for cls, body in re.findall(r"(?:p|span|td|li)\.(\w+)\s*\{([^}]*)\}", html_text):
        font = re.search(r"font:\s*([^;]+)", body)
        fam = re.search(r"font-family:\s*([^;]+)", body)
        if font or fam:
            styles[cls] = bool(MONO.search((font or fam).group(1)))
    conv = Converter(styles)
    body = html_text.split("<body>", 1)[-1]
    conv.feed(body)
    conv.close()

    out, i, lines = [], 0, conv.lines
    while i < len(lines):
        kind, text = lines[i]
        if kind == "code":
            # Code-Block bis zur nächsten Nicht-Code-Zeile; Leerzeilen dazwischen gehören dazu.
            block, j = [], i
            while j < len(lines) and lines[j][0] in ("code", "blank"):
                if lines[j][0] == "blank" and next((k for k, _ in lines[j:] if k != "blank"), None) != "code":
                    break
                block.append(lines[j][1])
                j += 1
            fence = "````" if any("```" in b for b in block) else "```"
            out += ["", fence] + block + [fence, ""]
            i = j
            continue
        if kind == "table":
            rows = text
            w = max(len(r) for r in rows) or 1
            rows = [r + [""] * (w - len(r)) for r in rows]
            out += [""] + ["| " + " | ".join(rows[0]) + " |", "|" + "---|" * w] + ["| " + " | ".join(r) + " |" for r in rows[1:]] + [""]
        elif kind == "blank":
            out.append("")
        else:
            out.append(text)
        i += 1
    md = "\n".join(out)
    md = re.sub(r"\n{3,}", "\n\n", md).strip()
    return md


def squash(s):
    return re.sub(r"\s+", "", s)


def entries():
    xml = gzip.open(os.path.join(DOC, "index.mjml.gz")).read().decode("utf-8")
    return re.findall(r'<content type="public\.rtf" id="([0-9A-F-]+)"', xml)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--test":
        print(to_markdown(textutil("html", os.path.join(DOC, "Content", sys.argv[2] + ".rtf"))))
        return

    ids = entries()
    print(len(ids), "RTF-Einträge in MacJournal", flush=True)

    def load(cid):
        path = os.path.join(DOC, "Content", cid + ".rtf")
        if not os.path.exists(path):
            return cid, None, None
        return cid, textutil("txt", path), textutil("html", path)

    by_text = {}
    with ThreadPoolExecutor(8) as pool:
        for n, (cid, txt, htm) in enumerate(pool.map(load, ids), 1):
            if txt is not None:
                by_text.setdefault(squash(txt), htm)
            if n % 200 == 0:
                print(n, "gelesen", flush=True)

    changed = same = edited = 0
    for root, dirs, files in os.walk(EXPORT):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for name in files:
            if not name.endswith(".md"):
                continue
            path = os.path.join(root, name)
            raw = open(path, encoding="utf-8").read()
            m = re.match(r"(---\n.*?\n---\n\n# [^\n]*\n)(.*)", raw, re.S)
            if not m or "quelle: MacJournal" not in m.group(1):
                continue
            head, body = m.groups()
            htm = by_text.get(squash(body))
            if htm is None:
                edited += 1  # seit dem Export geändert oder anders erzeugt: nicht anfassen
                continue
            new = head + "\n" + to_markdown(htm) + "\n"
            if new == raw:
                same += 1
                continue
            open(path, "w", encoding="utf-8").write(new)
            changed += 1
    print(f"{changed} neu formatiert, {same} unverändert, {edited} nicht angefasst (geändert oder ohne RTF)")


if __name__ == "__main__":
    main()
