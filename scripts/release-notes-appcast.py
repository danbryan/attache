#!/usr/bin/env python3
"""Inject release notes into a Sparkle appcast item.

Reads a generated appcast.xml and a release-notes markdown file, converts the
notes to a small HTML fragment (dropping the Install boilerplate), and writes a
new appcast that carries:

  - an inline <description> with that fragment, so the Sparkle update prompt
    shows what changed in the offered version, and
  - a <sparkle:fullReleaseNotesLink> to the public GitHub releases page, the
    cumulative changelog for anyone several versions behind.

The appcast's EdDSA signature lives on the <enclosure> element and is left
untouched, so editing the surrounding XML is safe.

Usage: release-notes-appcast.py <appcast.xml> <notes.md> <full-notes-url> <out.xml>
"""
import html
import re
import sys


def convert_notes(markdown: str) -> str:
    """Minimal, format-specific markdown to HTML for our release notes.

    Handles the shapes our notes actually use: a lead paragraph, `##` section
    headers, `-` bullets, `**bold**`, and inline `code`. The Install section is
    dropped because it is boilerplate that does not belong in an in-app update
    prompt.
    """
    def inline(text: str) -> str:
        text = html.escape(text)
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
        return text

    lines = markdown.splitlines()
    out: list[str] = []
    in_list = False
    in_code = False
    skip_section = False

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in lines:
        line = raw.rstrip()
        if line.strip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if line.startswith("## "):
            close_list()
            title = line[3:].strip()
            skip_section = title.lower() == "install"
            if not skip_section:
                out.append(f"<h4>{inline(title)}</h4>")
            continue
        if skip_section:
            continue
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:].strip())}</li>")
            continue
        if not line.strip():
            close_list()
            continue
        close_list()
        out.append(f"<p>{inline(line.strip())}</p>")

    close_list()
    return "\n".join(out).strip()


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    appcast_path, notes_path, full_url, out_path = sys.argv[1:5]

    with open(appcast_path, encoding="utf-8") as handle:
        appcast = handle.read()
    with open(notes_path, encoding="utf-8") as handle:
        notes_html = convert_notes(handle.read())

    if "<description>" in appcast:
        print("appcast already has a description; not double-injecting", file=sys.stderr)
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write(appcast)
        return 0

    anchor = re.search(r"([ \t]*)<sparkle:shortVersionString>.*?</sparkle:shortVersionString>", appcast)
    if not anchor:
        print("error: no shortVersionString element to anchor notes to", file=sys.stderr)
        return 1

    indent = anchor.group(1)
    injection = (
        f"\n{indent}<description><![CDATA[\n{notes_html}\n]]></description>"
        f"\n{indent}<sparkle:fullReleaseNotesLink>{html.escape(full_url)}</sparkle:fullReleaseNotesLink>"
    )
    injected = appcast[: anchor.end()] + injection + appcast[anchor.end():]

    with open(out_path, "w", encoding="utf-8") as handle:
        handle.write(injected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
