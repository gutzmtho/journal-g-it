"""Docmost-Seiten (ProseMirror-JSON aus der DB) als Markdown-Ordner ausgeben."""
import json, os, re, sys

src, out = sys.argv[1], sys.argv[2]
pages = json.load(open(src))
byid = {p["id"]: p for p in pages}
URL = os.environ.get("DOCMOST_URL", "https://docmost.example.com")  # eigene Docmost-Adresse


def marks(text, ms):
    for m in ms or []:
        t = m["type"]
        if t == "code":
            text = f"`{text}`"
        elif t == "bold" and text.strip():
            text = f"**{text}**"
        elif t == "italic" and text.strip():
            text = f"*{text}*"
        elif t == "link":
            text = f"[{text}]({m.get('attrs', {}).get('href', '')})"
    return text


def inline(n):
    out = []
    for c in n.get("content", []) or []:
        t = c["type"]
        if t == "text":
            out.append(marks(c.get("text", ""), c.get("marks")))
        elif t == "hardBreak":
            out.append("  \n")
        elif t == "image":
            out.append(img(c))
        else:
            out.append(inline(c))
    return "".join(out)


def img(n):
    s = n.get("attrs", {}).get("src") or ""
    if s.startswith("/"):
        s = URL + s
    return f"![Bild]({s})"


def cell(n):
    return " ".join(inline(p) if p["type"] != "image" else img(p) for p in n.get("content", []) or []).replace("|", "\\|").replace("\n", " ")


def block(n, indent=""):
    t = n["type"]
    if t == "paragraph":
        return indent + inline(n)
    if t == "heading":
        lvl = min(n.get("attrs", {}).get("level", 2) + 1, 6)  # "#" bleibt dem Seitentitel
        return "#" * lvl + " " + inline(n)
    if t == "codeBlock":
        lang = n.get("attrs", {}).get("language") or ""
        code = "".join(c.get("text", "") for c in n.get("content", []) or []).rstrip("\n")
        return "\n".join(indent + l for l in f"```{lang}\n{code}\n```".split("\n"))
    if t == "horizontalRule":
        return "---"
    if t == "image":
        return img(n)
    if t == "blockquote":
        return "\n".join("> " + l for l in blocks(n).split("\n"))
    if t in ("bulletList", "orderedList", "taskList"):
        items = []
        for i, li in enumerate(n.get("content", []) or [], 1):
            bullet = f"{i}." if t == "orderedList" else "-"
            kids = li.get("content", []) or []
            first = block(kids[0]).strip() if kids else ""
            rest = [block(k, indent + "    ") for k in kids[1:]]
            items.append("\n".join([f"{indent}{bullet} {first}"] + rest))
        return "\n".join(items)
    if t == "table":
        rows = [[cell(c) for c in r.get("content", []) or []] for r in n.get("content", []) or []]
        if not rows:
            return ""
        w = max(len(r) for r in rows)
        rows = [r + [""] * (w - len(r)) for r in rows]
        lines = ["| " + " | ".join(rows[0]) + " |", "|" + "---|" * w]
        lines += ["| " + " | ".join(r) + " |" for r in rows[1:]]
        return "\n".join(lines)
    return blocks(n) if n.get("content") else inline(n)


def blocks(n):
    return "\n\n".join(b for b in (block(c) for c in n.get("content", []) or []))


def safe(s):
    s = re.sub(r'[/:\\]', "-", (s or "Ohne Titel").strip()) or "Ohne Titel"
    return s[:120]


def folder(p):
    parts = []
    q = p
    while q.get("parent_page_id") and q["parent_page_id"] in byid:
        q = byid[q["parent_page_id"]]
        parts.insert(0, safe(q["title"]))
    return os.path.join(out, safe(p["space"]), *parts)


used = set()
for p in pages:
    d = folder(p)
    os.makedirs(d, exist_ok=True)
    name = safe(p["title"])
    path = os.path.join(d, name + ".md")
    i = 2
    while path in used:
        path = os.path.join(d, f"{name} ({i}).md"); i += 1
    used.add(path)
    body = blocks(p["content"]) if p.get("content") else ""
    body = re.sub(r"\n{3,}", "\n\n", body).strip()
    text = (f"---\ndatum: {p['updated_at'][:10]}\nerstellt: {p['created_at'][:10]}\n"
            f"quelle: Docmost / {p['space']}\n---\n\n# {p['title'] or 'Ohne Titel'}\n\n{body}\n")
    open(path, "w").write(text)
print(len(used), "Dateien")
