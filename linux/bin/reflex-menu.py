#!/usr/bin/env python3
"""Install or remove the Reflex rows in Omarchy's user menu extension.

The menu file is user-owned: it also carries unrelated groups. This changes
only the reflex and reflex.* keys, keeps the other keys, preserves the leading
comment block and backs the file up before writing.

Usage:
  reflex-menu.py install <reflex-menu.json> <omarchy-menu.jsonc>
  reflex-menu.py remove  <omarchy-menu.jsonc>
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import time


def strip_jsonc(text: str) -> str:
    """Remove // and /* */ comments outside strings, keeping newlines."""
    out = []
    i = 0
    n = len(text)
    in_string = False
    escaped = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            i += 2
            while i < n and text[i] not in "\r\n":
                i += 1
            continue
        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def load_target(path: str):
    if not os.path.exists(path):
        return "", "", {}
    with open(path, "r", encoding="utf-8") as handle:
        raw = handle.read()
    # Find the opening brace outside comments and strings. A schema comment
    # may itself contain a brace before the real object.
    start = 0
    while start < len(raw):
        if raw[start].isspace():
            start += 1
            continue
        if raw.startswith("//", start):
            newline = raw.find("\n", start)
            start = len(raw) if newline < 0 else newline + 1
            continue
        if raw.startswith("/*", start):
            close = raw.find("*/", start + 2)
            if close < 0:
                raise SystemExit(f"menu: unterminated comment in {path}")
            start = close + 2
            continue
        break
    if start >= len(raw) or raw[start] != "{":
        raise SystemExit(f"menu: no object in {path}")
    prefix = raw[:start]
    if prefix and not prefix.endswith("\n"):
        prefix += "\n"
    # Omarchy ships its schema comment block inside the object, after the
    # opening brace. Keep that block when the JSON is rewritten.
    rest = raw[start + 1:]
    lines = rest.splitlines(keepends=True)
    block = []
    for line in lines:
        text = line.strip()
        if text == "" or text.startswith("//"):
            block.append(line)
        else:
            break
    comments = "".join(block)
    try:
        data = json.loads(strip_jsonc(raw[start:]))
    except json.JSONDecodeError as error:
        raise SystemExit(f"menu: {path} is not valid JSONC: {error}")
    if not isinstance(data, dict):
        raise SystemExit(f"menu: {path} does not contain an object")
    return prefix, comments, data


def backup(path: str) -> None:
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    shutil.copy2(path, f"{path}.bak-reflex-{stamp}")


def write(path: str, prefix: str, comments: str, data: dict) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    mode = 0o600
    if os.path.exists(path):
        mode = os.stat(path).st_mode & 0o777
    if data:
        body = json.dumps(data, indent=2, ensure_ascii=False)
        lines = body.splitlines(keepends=True)
        if comments:
            body = lines[0] + comments + "".join(lines[1:])
        text = prefix + body + "\n"
    else:
        # Keep the user-owned file and its schema comments when the last
        # managed row is removed; do not delete the whole menu.
        text = prefix + "{\n" + comments + "}\n"
    handle, temp = tempfile.mkstemp(
        prefix=".omarchy-menu.", dir=os.path.dirname(path) or "."
    )
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    action = sys.argv[1]
    if action == "install":
        if len(sys.argv) != 4:
            raise SystemExit(__doc__)
        source, target = sys.argv[2], sys.argv[3]
        with open(source, "r", encoding="utf-8") as handle:
            rows = json.load(handle)
        if not isinstance(rows, dict) or "reflex" not in rows:
            raise SystemExit(f"menu: {source} has no reflex rows")
        prefix, comments, data = load_target(target)
        managed = [key for key in data if key == "reflex" or key.startswith("reflex.")]
        changed = any(data.get(key) != value for key, value in rows.items()) or any(
            key not in rows for key in managed
        )
        if not changed:
            print(f"menu: Reflex rows already current in {target}")
            return
        if os.path.exists(target):
            backup(target)
        # Drop stale managed rows so removing a row from the source also
        # removes it from the user's menu.
        for key in managed:
            if key not in rows:
                del data[key]
        data.update(rows)
        write(target, prefix, comments, data)
        print(f"menu: installed Reflex rows in {target}")
        return
    if action == "remove":
        if len(sys.argv) != 3:
            raise SystemExit(__doc__)
        target = sys.argv[2]
        if not os.path.exists(target):
            print(f"menu: {target} does not exist")
            return
        prefix, comments, data = load_target(target)
        removed = [key for key in data if key == "reflex" or key.startswith("reflex.")]
        if not removed:
            print(f"menu: no Reflex rows in {target}")
            return
        backup(target)
        for key in removed:
            del data[key]
        write(target, prefix, comments, data)
        print(f"menu: removed {len(removed)} Reflex row(s) from {target}")
        return
    raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
