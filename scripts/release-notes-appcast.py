#!/usr/bin/env python3
"""Inject rolling release notes into a Sparkle appcast item.

Sparkle shows the offered version's notes in the update prompt and does not
concatenate the notes of versions a user skipped, and our feed carries a single
item. A static appcast also cannot be tailored to the exact installed version.
So the inline notes are a ROLLING WINDOW: the current version's notes plus the
few before it, newest first, so someone several versions behind still sees the
recent span inline. A <sparkle:fullReleaseNotesLink> to the public GitHub
releases page remains the complete cumulative changelog.

The appcast's EdDSA signature lives on the <enclosure> and is untouched.

Usage:
  release-notes-appcast.py <appcast.xml> <notesDir> <currentVersion> <full-url> <out.xml> [count]
"""
import html
import os
import re
import sys


def convert_notes(markdown: str) -> str:
    """Format-specific markdown to HTML for our notes; drops the Install section."""
    def inline(text: str) -> str:
        text = html.escape(text)
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
        return text

    out, in_list, in_code, skip = [], False, False, False

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in markdown.splitlines():
        line = raw.rstrip()
        if line.strip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if line.startswith("## "):
            close_list()
            title = line[3:].strip()
            skip = title.lower() == "install"
            if not skip:
                out.append(f"<h4>{inline(title)}</h4>")
            continue
        if skip:
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


def version_tuple(name: str):
    m = re.match(r"v(\d+)\.(\d+)\.(\d+)\.md$", name)
    return tuple(int(x) for x in m.groups()) if m else None


def rolling_notes(notes_dir: str, current: str, count: int) -> str:
    cur = tuple(int(x) for x in current.split("."))
    files = []
    for name in os.listdir(notes_dir):
        v = version_tuple(name)
        if v and v <= cur:
            files.append((v, name))
    files.sort(reverse=True)
    files = files[:count]
    if not files:
        raise SystemExit(f"error: no release notes at or below v{current} in {notes_dir}")

    sections = []
    for v, name in files:
        with open(os.path.join(notes_dir, name), encoding="utf-8") as handle:
            body = convert_notes(handle.read())
        label = ".".join(str(x) for x in v)
        sections.append(f'<h3>Version {label}</h3>\n{body}')
    lead = "" if len(sections) == 1 else "<p><em>Recent updates, newest first:</em></p>\n"
    return lead + "\n".join(sections)


def main() -> int:
    if len(sys.argv) not in (6, 7):
        print(__doc__, file=sys.stderr)
        return 2
    appcast_path, notes_dir, current, full_url, out_path = sys.argv[1:6]
    count = int(sys.argv[6]) if len(sys.argv) == 7 else 6

    with open(appcast_path, encoding="utf-8") as handle:
        appcast = handle.read()
    notes_html = rolling_notes(notes_dir, current, count)

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
