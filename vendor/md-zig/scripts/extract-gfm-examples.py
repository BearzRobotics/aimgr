#!/usr/bin/env python3
"""Writes test/fixtures/gfm-extensions.json from cmark-gfm's spec.txt and
extensions.txt (https://github.com/github/cmark-gfm/tree/master/test).

    scripts/extract-gfm-examples.py spec.txt extensions.txt > test/fixtures/gfm-extensions.json

Keeps every example of extensions.txt, and from spec.txt those that carry an
extension tag (table, strikethrough, autolink, tagfilter, disabled). The task
list examples of spec.txt use an older HTML form (`<input disabled="" type=
"checkbox">`) than extensions.txt (`<input type="checkbox" disabled="" />`), so
only the latter are used.
"""
import json, re, sys

FENCE = "`" * 32

def examples(path, only_tagged):
    out, section = [], ""
    lines = open(path, encoding="utf-8").read().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.startswith("#"):
            section = line.lstrip("# ").strip()
        m = re.match(r"^" + FENCE + r" example ?(.*)$", line)
        if m:
            tag = m.group(1).strip()
            md, html, cur = [], [], None
            i += 1
            cur = md
            while not lines[i].startswith(FENCE):
                if lines[i] == "." and cur is md:
                    cur = html
                else:
                    cur.append(lines[i])
                i += 1
            keep = (not only_tagged) or tag
            if keep:
                out.append({
                    "markdown": "\n".join(md).replace("→", "\t") + "\n" if md else "",
                    "html": "\n".join(html).replace("→", "\t") + "\n" if html else "",
                    "section": section,
                    "tag": tag,
                })
        i += 1
    return out

spec = examples(sys.argv[1], True)
ext = examples(sys.argv[2], False)
seen, result = set(), []
for ex in ext + spec:
    key = (ex["markdown"], ex["html"])
    if key in seen:
        continue
    seen.add(key)
    ex["example"] = len(result) + 1
    result.append(ex)
json.dump(result, sys.stdout, ensure_ascii=False, indent=1)
