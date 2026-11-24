"""Reads RELEASE_NOTES.md for the release workflow (publish-release.yml).

  release_notes.py json RELEASE_NOTES.md [count]
      The newest [count] (5) versions' notes as JSON for docs/flags.json:
      [{"version": "4.5.4", "notes": ["...", "..."]}, ...]
  release_notes.py markdown RELEASE_NOTES.md VERSION
      VERSION's notes as Markdown lines ("- ..."), or nothing if it has none.
"""
import json
import re
import sys


def read(path):
    releases = []
    current = None
    with open(path, encoding="utf-8") as f:
        for line in f:
            heading = re.match(r"^##\s+v?(\d+\.\d+\.\d+)\s*$", line)
            if heading:
                current = {"version": heading.group(1), "notes": []}
                releases.append(current)
                continue
            if line.startswith("#"):
                current = None
                continue
            note = re.match(r"^[-*]\s+(.*\S)\s*$", line)
            if current is not None and note:
                current["notes"].append(note.group(1))
            elif current is not None and line.strip() and current["notes"]:
                # A note wrapped onto the next line.
                current["notes"][-1] += " " + line.strip()
    return releases


def main():
    # Notes have "…", Sinhala and the like: UTF-8 out, whatever the console.
    sys.stdout.reconfigure(encoding="utf-8")
    mode, path = sys.argv[1], sys.argv[2]
    releases = read(path)
    if mode == "json":
        count = int(sys.argv[3]) if len(sys.argv) > 3 else 5
        print(json.dumps([r for r in releases if r["notes"]][:count],
                         ensure_ascii=False))
    elif mode == "markdown":
        version = sys.argv[3]
        for r in releases:
            if r["version"] == version:
                print("\n".join("- " + n for n in r["notes"]))
                break
    else:
        sys.exit("Unknown mode: " + mode)


if __name__ == "__main__":
    main()
