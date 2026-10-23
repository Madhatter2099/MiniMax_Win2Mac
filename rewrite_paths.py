#!/usr/bin/env python3
"""Rewrite Windows absolute paths inside a MiniMax Code runtime-state.sqlite to macOS paths.

Used by mac-import.sh after a Windows export has been installed. The runtime db stores
absolute workspace paths (sessions, projects, session records, workspace index); after a
cross-OS migration those paths point at a drive letter that does not exist on macOS.

How a path is mapped
  * rule = (windows dir, mac dir), e.g. ("C:\\Users\\me\\OneDrive-個人",
    "/Users/me/Library/CloudStorage/OneDrive-個人")
  * a cell is transformed by replacing "<windows dir>\\<rest>" with "<mac dir>/<rest>",
    where the rest of the path also gets its backslashes turned into slashes
  * JSON cells are decoded first, transformed, and re-encoded - so escaped backslashes
    inside JSON ("C:\\\\Users\\\\me") are handled correctly too

Usage
  python3 rewrite_paths.py --db <runtime-state.sqlite> [--manifest export-manifest.json]
                           [--map 'D:\\Projects=/Users/me/Projects'] [--apply]

Without --apply the script only reports what it would change.
"""

import argparse
import json
import os
import re
import sqlite3
import sys

SEP_W = "\\"


# --------------------------------------------------------------------------- helpers
def log(msg=""):
    print(msg, flush=True)


def strip_sep(path):
    return path.rstrip("/\\") if path else path


def norm_win(p):
    return p.replace("/", SEP_W).rstrip(SEP_W + "/")


def mac_cloud_dirs(mac_home):
    base = os.path.join(mac_home, "Library", "CloudStorage")
    if not os.path.isdir(base):
        return []
    return [
        (name, os.path.join(base, name))
        for name in sorted(os.listdir(base))
        if name.lower().startswith("onedrive")
    ]


def pick_cloud_dir(win_segment, cloud_dirs):
    if not cloud_dirs:
        return None
    if len(cloud_dirs) == 1:
        return cloud_dirs[0][1]
    token = win_segment.rsplit(SEP_W, 1)[-1].replace("OneDrive", "").strip(" -_")
    for name, full in cloud_dirs:
        if token and token.lower() in name.lower():
            return full
    for name, full in cloud_dirs:
        if name.lower().endswith(token.lower()):
            return full
    return None


def build_rules(manifest, extra_maps, mac_home):
    """Return (rules, win_home, observed_paths)."""
    rules = []
    observed = [norm_win(p) for p in (manifest.get("windowsPaths") or []) if p]
    win_home = norm_win(manifest.get("windowsUserProfile") or "") if manifest.get("windowsUserProfile") else ""

    # explicit --map rules first: they win over the auto-detected ones
    for raw in extra_maps:
        sep = "=>" if "=>" in raw else ("=" if "=" in raw else None)
        if not sep:
            log("  (ignoring malformed --map: %s)" % raw)
            continue
        win, mac = raw.split(sep, 1)
        rules.append((strip_sep(norm_win(win)), strip_sep(mac.replace(SEP_W, "/"))))

    if not win_home and observed:
        counts = {}
        for p in observed:
            m = re.match(r"^([A-Za-z]:\\Users\\[^\\]+)", p)
            if m:
                counts[m.group(1)] = counts.get(m.group(1), 0) + 1
        if counts:
            win_home = max(counts.items(), key=lambda kv: kv[1])[0]

    cloud_dirs = mac_cloud_dirs(mac_home)

    if win_home:
        seen = set()
        for p in observed:
            for seg in p.split(SEP_W):
                if not seg.lower().startswith("onedrive") or seg.lower() in seen:
                    continue
                seen.add(seg.lower())
                target = pick_cloud_dir(seg, cloud_dirs)
                if target:
                    rules.append((win_home + SEP_W + seg, strip_sep(target)))
        rules.append((win_home, mac_home))

    # de-dup, longest windows prefix first
    uniq = {}
    for win, mac in rules:
        if win and win not in uniq:
            uniq[win] = mac
    ordered = sorted(uniq.items(), key=lambda kv: len(kv[0]), reverse=True)
    return ordered, win_home, observed


# --------------------------------------------------------------------------- text transform
def make_transformer(rules):
    """Return a function that rewrites every windows path inside a decoded string."""
    compiled = []
    for win, mac in rules:
        win_pat = re.escape(win + SEP_W)
        tail_pat = r"((?:[^\\/:*?\"<>|\r\n]+[\\/])*)"

        def repl(m, mac=mac):
            tail = m.group(1).replace(SEP_W, "/")
            return mac + "/" + tail

        compiled.append((re.compile(win_pat + tail_pat), repl))

    def transform(text):
        if not isinstance(text, str) or not text:
            return text, False
        out = text
        changed = False
        for pattern, repl in compiled:
            new = pattern.sub(repl, out)
            if new != out:
                out = new
                changed = True
        return out, changed

    return transform


def walk_json(node, transform, counter):
    if isinstance(node, str):
        new, changed = transform(node)
        if changed:
            counter[0] += 1
        return new
    if isinstance(node, list):
        return [walk_json(x, transform, counter) for x in node]
    if isinstance(node, dict):
        return {k: walk_json(v, transform, counter) for k, v in node.items()}
    return node


def transform_value(value, transform):
    """Transform a cell value. Returns (new_value, changed)."""
    if value is None or not isinstance(value, str):
        return value, False
    stripped = value.strip()
    if stripped[:1] in ("{", "["):
        try:
            parsed = json.loads(value)
        except (ValueError, TypeError):
            parsed = None
        if parsed is not None:
            counter = [0]
            new_node = walk_json(parsed, transform, counter)
            if counter[0]:
                return json.dumps(new_node, ensure_ascii=False), True
            return value, False
    new, changed = transform(value)
    return new, changed


# --------------------------------------------------------------------------- db passes
def table_columns(conn):
    rows = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"
    ).fetchall()
    cols = []
    for (table,) in rows:
        if "_fts" in table:
            continue
        safe = table.replace('"', '""')
        for info in conn.execute('PRAGMA table_info("%s")' % safe):
            if (info[2] or "").upper() in ("TEXT", "CLOB", ""):
                cols.append((table, info[1]))
    return cols


def pass_projects(conn, transform):
    """Projects first: sessions point at a project by workspace_dir."""
    rows = conn.execute(
        "SELECT project_id, workspace_dir FROM local_runtime_projects WHERE workspace_dir IS NOT NULL"
    ).fetchall()
    changed = 0
    merged = 0
    by_new = {}
    for pid, wdir in rows:
        new, did = transform_value(wdir, transform)
        if not did:
            continue
        by_new.setdefault(new, []).append((pid, wdir))
    for new, items in by_new.items():
        if len(items) == 1:
            pid = items[0][0]
            conn.execute(
                "UPDATE local_runtime_projects SET workspace_dir = ? WHERE project_id = ?", (new, pid)
            )
            changed += 1
        else:
            keep, *rest = sorted(items, key=lambda x: x[0])
            keep_id = keep[0]
            for pid, _old in rest:
                conn.execute(
                    "UPDATE local_runtime_sessions SET project_id = ? WHERE project_id = ?",
                    (keep_id, pid),
                )
                conn.execute("DELETE FROM local_runtime_projects WHERE project_id = ?", (pid,))
                merged += 1
            conn.execute(
                "UPDATE local_runtime_projects SET workspace_dir = ? WHERE project_id = ?",
                (new, keep_id),
            )
            changed += 1
    return changed, merged


def pass_sessions(conn, transform):
    changed = 0
    for col in ("project_workspace_dir", "workspace_dir"):
        rows = conn.execute(
            'SELECT session_id, "%s" FROM local_runtime_sessions WHERE "%s" IS NOT NULL' % (col, col)
        ).fetchall()
        for sid, value in rows:
            new, did = transform_value(value, transform)
            if did:
                conn.execute(
                    'UPDATE local_runtime_sessions SET "%s" = ? WHERE session_id = ?' % col, (new, sid)
                )
                changed += 1
    return changed


def pass_generic(conn, transform, skip):
    changed = 0
    for table, col in table_columns(conn):
        if (table, col) in skip:
            continue
        safe_t = table.replace('"', '""')
        safe_c = col.replace('"', '""')
        rows = conn.execute(
            'SELECT rowid, "%s" FROM "%s" WHERE "%s" IS NOT NULL' % (safe_c, safe_t, safe_c)
        ).fetchall()
        if not rows:
            continue
        for rid, value in rows:
            new, did = transform_value(value, transform)
            if did:
                conn.execute(
                    'UPDATE "%s" SET "%s" = ? WHERE rowid = ?' % (safe_t, safe_c), (new, rid)
                )
                changed += 1
    return changed


def pass_files(root, transform):
    """Fix the absolute paths stored in the on-disk session history files."""
    if not root or not os.path.isdir(root):
        return 0
    changed = 0
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if not name.endswith((".json", ".jsonl", ".md", ".txt")):
                continue
            path = os.path.join(dirpath, name)
            try:
                if os.path.getsize(path) > 64 * 1024 * 1024:
                    continue
                with open(path, "r", encoding="utf-8", errors="ignore") as fh:
                    text = fh.read()
            except OSError:
                continue
            new, did = transform_value(text, transform)
            if did:
                try:
                    with open(path, "w", encoding="utf-8") as fh:
                        fh.write(new)
                    changed += 1
                except OSError:
                    pass
    return changed


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--manifest", default=None)
    ap.add_argument("--map", action="append", default=[], dest="maps")
    ap.add_argument("--sessions-dir", default=None)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    if not os.path.exists(args.db):
        log("db not found: %s" % args.db)
        return 2

    manifest = {}
    if args.manifest and os.path.exists(args.manifest):
        try:
            with open(args.manifest, "r", encoding="utf-8-sig") as fh:
                manifest = json.load(fh)
        except Exception as exc:  # noqa: BLE001
            log("  (manifest unreadable: %s)" % exc)

    mac_home = os.path.expanduser("~")
    rules, win_home, observed = build_rules(manifest, args.maps, mac_home)

    log("Windows profile root : %s" % (win_home or "(not detected)"))
    log("macOS home           : %s" % mac_home)
    log("path rules (longest prefix first):")
    if not rules:
        log("  (none detected - windows paths stay unchanged)")
    for win, mac in rules:
        log("  %-42s -> %s" % (win, mac))

    unresolved = [p for p in observed if not any(w in p for w, _ in rules)]
    if unresolved:
        log("")
        log("Windows paths no rule covers (add --map 'WIN=>MAC' for them):")
        for p in unresolved:
            log("  %s" % p)

    if not args.apply:
        log("")
        log("Dry run. Re-run with --apply to write the changes.")
        return 0

    transform = make_transformer(rules)
    conn = sqlite3.connect(args.db)
    try:
        conn.execute("PRAGMA foreign_keys=OFF")
        log("")
        log("Applying...")
        n_proj, n_merge = pass_projects(conn, transform)
        n_sess = pass_sessions(conn, transform)
        n_gen = pass_generic(
            conn,
            transform,
            skip={
                ("local_runtime_projects", "workspace_dir"),
                ("local_runtime_sessions", "project_workspace_dir"),
                ("local_runtime_sessions", "workspace_dir"),
            },
        )
        conn.commit()

        sessions_dir = args.sessions_dir
        if not sessions_dir:
            guess = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(args.db))), "sessions")
            sessions_dir = guess if os.path.isdir(guess) else None
        n_files = pass_files(sessions_dir, transform) if sessions_dir else 0

        log("  project rows rewritten : %d (merged duplicates: %d)" % (n_proj, n_merge))
        log("  session rows rewritten  : %d" % n_sess)
        log("  other cells rewritten   : %d" % n_gen)
        log("  history files rewritten : %d" % n_files)

        left = conn.execute(
            "SELECT COUNT(*) FROM local_runtime_projects WHERE workspace_dir LIKE '%:\\%'"
        ).fetchone()[0]
        if left:
            log("")
            log("  %d project row(s) still contain a windows drive letter - see the list above." % left)
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
