"""Render the small Markdown dialect used by the public release documents.

This is a build-time renderer, not a general-purpose Markdown implementation.
Raw HTML is always escaped; license fences preserve their original text.
"""
from html import escape
import re
from urllib.parse import urlsplit


PAGES = {"CHANGELOG.md": "changelog.html", "THIRD_PARTY_NOTICES.md": "notices.html",
         "LICENCE.md": "license.html"}
TOKENS = re.compile(r"`[^`\n]+`|\*\*[^*\n]+\*\*|\[[^\]\n]+\]\([^\s)]+\)|<https://[^>\s]+>|https://[^\s<>]+")


def inline(text):
    parts, end = [], 0
    for match in TOKENS.finditer(text):
        parts.append(escape(text[end:match.start()]))
        token = match.group()
        if token.startswith("`"):
            parts.append("<code>" + escape(token[1:-1]) + "</code>")
        elif token.startswith("**"):
            parts.append("<strong>" + escape(token[2:-2]) + "</strong>")
        else:
            if token.startswith("["):
                label, href = token[1:].split("](", 1)
                href = href[:-1]
            else:
                href = token.strip("<>")
                label = href
            parsed = urlsplit(href)
            if parsed.scheme not in {"", "https", "http"} or href.startswith("//"):
                parts.append(escape(token))
            else:
                href = PAGES.get(href, href)
                parts.append(f'<a href="{escape(href, quote=True)}">{escape(label)}</a>')
        end = match.end()
    parts.append(escape(text[end:]))
    return "".join(parts)


def markdown(source, *, legal=False):
    lines, output, toc, identifiers = source.splitlines(), [], [], set()
    index, last_heading = 0, "License text"
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            index += 1
            continue
        if line.startswith("```"):
            fence, content = re.match(r"^`{3,}", line)[0], []
            index += 1
            while index < len(lines) and lines[index] != fence:
                content.append(lines[index])
                index += 1
            if index == len(lines):
                raise ValueError("Unclosed Markdown fence")
            code = "<pre><code>" + escape("\n".join(content)) + "</code></pre>"
            output.append(f'<details class="license-text"><summary>Read {escape(last_heading)}</summary>{code}</details>'
                          if legal else code)
            index += 1
            continue
        heading = re.fullmatch(r"(#{1,6})\s+(.+)", line)
        if heading:
            level, text = len(heading[1]), heading[2]
            last_heading = text
            if level != 1:
                base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "section"
                anchor, suffix = base, 2
                while anchor in identifiers:
                    anchor, suffix = f"{base}-{suffix}", suffix + 1
                identifiers.add(anchor)
                display = inline(text)
                release = re.fullmatch(r"\[([^]]+)\]\s*\(([^)]+)\)", text)
                if release:
                    display = f'Version {escape(release[1])}<span class="release-date">{escape(release[2])}</span>'
                output.append(f'<h{level} id="{anchor}">{display}</h{level}>')
                if level == 2:
                    toc.append((anchor, f"Version {release[1]}" if release else text))
            index += 1
            continue
        if line.startswith("|") and index + 1 < len(lines) and re.fullmatch(r"[|:\-\s]+", lines[index + 1]):
            cells = lambda row: [cell.strip() for cell in row.strip().strip("|").split("|")]
            header = cells(line)
            output.append('<div class="document-table" tabindex="0" aria-label="Dependency versions and licenses"><table><thead><tr>'
                          + "".join(f'<th scope="col">{inline(cell)}</th>' for cell in header) + "</tr></thead><tbody>")
            index += 2
            while index < len(lines) and lines[index].startswith("|"):
                row = cells(lines[index])
                if len(row) != len(header):
                    raise ValueError("Inconsistent Markdown table columns")
                output.append("<tr>" + "".join(f'<td data-label="{escape(label, quote=True)}">{inline(cell)}</td>'
                    for label, cell in zip(header, row)) + "</tr>")
                index += 1
            output.append("</tbody></table></div>")
            continue
        if re.match(r"^[-*] ", line):
            output.append("<ul>")
            while index < len(lines) and re.match(r"^[-*] ", lines[index]):
                output.append("<li>" + inline(lines[index][2:]) + "</li>")
                index += 1
            output.append("</ul>")
            continue
        paragraph = [line]
        index += 1
        while index < len(lines) and lines[index].strip() and not re.match(r"^(?:#|```|\||[-*] )", lines[index]):
            paragraph.append(lines[index])
            index += 1
        output.append("<p>" + inline(" ".join(paragraph)) + "</p>")
    return "\n".join(output), toc


def page(title, description, source_name, body, toc):
    navigation = "".join(f'<a href="#{anchor}">{escape(label)}</a>' for anchor, label in toc)
    controls = '<button type="button" data-license-toggle hidden>Expand license texts</button>' if 'class="license-text"' in body else ''
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="description" content="{escape(description, quote=True)}"><title>{escape(title)} — MacSCP</title>
<link rel="icon" href="assets/favicon.svg" type="image/svg+xml"><link rel="stylesheet" href="style.css"><link rel="stylesheet" href="macscp.css"><script src="script.js" defer></script></head>
<body class="document-page"><a class="skip" href="#main">Skip to content</a>
<header><div class="header-inner wrap"><a class="document-brand" href="index.html">retroTools / MacSCP</a>
<nav aria-label="Documentation"><a href="guide.html">User guide</a><a href="changelog.html">Release notes</a><a href="notices.html">Third-party notices</a></nav></div></header>
<main id="main" class="wrap document-main"><div class="document-heading"><p class="eyebrow">MACSCP / DOCUMENTATION</p>
<h1>{escape(title)}</h1><p>{escape(description)}</p><div class="document-tools"><a class="document-source" href="{source_name}" download>Download the original source</a>{controls}</div></div>
<div class="document-layout"><aside><nav aria-label="On this page">{navigation}<a href="license.html">Application license</a></nav></aside>
<article class="document-body">{body}</article></div></main>
<footer><div class="wrap footer-bottom"><span>© 2026 retroTools</span><a href="index.html">MacSCP overview</a><a href="license.html">GPLv3 or later</a></div></footer></body></html>
'''


def generated_pages(root):
    pages = {}
    for source_name, title, description, legal in [
        ("CHANGELOG.md", "Release notes", "Changes and improvements in each MacSCP release.", False),
        ("THIRD_PARTY_NOTICES.md", "Third-party notices", "Dependencies, source revisions and original license notices.", True),
    ]:
        body, toc = markdown((root / source_name).read_text(), legal=legal)
        pages[PAGES[source_name]] = page(title, description, source_name, body, toc)
    introduction = (root / "licenses/macSCP-NOTICE.txt").read_text()
    license_text = (root / "LICENSE").read_text()
    body, toc = markdown(introduction)
    toc.append(("gpl", "GNU GPL version 3"))
    body += '<h2 id="gpl">GNU General Public License</h2><pre class="legal-copy"><code>' + escape(license_text) + '</code></pre>'
    pages["license.html"] = page("Application license", "MacSCP is licensed under the GNU GPL, version 3 or later.",
                                 "LICENCE.md", body, toc)
    return pages
