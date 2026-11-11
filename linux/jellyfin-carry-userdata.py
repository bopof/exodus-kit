#!/usr/bin/env python3
"""jellyfin-carry-userdata -- carry watch state from an old Jellyfin server to a new one, by file path.

    jellyfin-carry-userdata.py OLD.db NEW.db --map 'OLD_PREFIX=NEW_PREFIX' [--map ...] [--apply]

You moved Jellyfin from Windows to Linux and rescanned the same media from its new location
(\\\\nas\\Movies -> /mnt/nas/Movies). The new server sees new items with new ids, so everyone's
"played", resume position, play count and favorites are gone. This copies them across: each old
item is found on the new server by its path, with your --map prefixes applied.

    OLD.db   the old server's data/jellyfin.db (Windows: C:\\ProgramData\\Jellyfin\\Server\\data).
             Never written to: it's copied (with its -wal) to a temp folder and read from there, because
             SQLite updates the -shm index next to a database even when it opens it read-only.
    NEW.db   the new server's data/jellyfin.db (Linux package: /var/lib/jellyfin/data/jellyfin.db).
             STOP JELLYFIN FIRST (--apply refuses while the jellyfin service is active).

    --map OLD=NEW      path prefix rewrite, repeatable, longest match wins, case-insensitive. Windows
                       backslashes are turned into slashes, so '\\\\nas\\Movies=/mnt/nas/Movies' works.
                       Old paths outside every --map are skipped (an easy way to leave a library out).
    --user OLD=NEW     old user name -> new user name. By default users are matched by name (ignoring case).
                       Users missing on the new server are skipped: create them first.
    --on-conflict      both servers have state for the same item and user:
                         newest  (default) the one played last wins; favorite if either is; max play count
                         keep    keep the new server's row
                         replace take the old server's row
    --unmatched FILE   write the old paths that found no item on the new server to a CSV
    --not-live         NEW.db is a copy, not the live server's: skip the "is jellyfin running" check
    --apply            write. Without it: report what would happen, change nothing.
                       Before writing, NEW.db is backed up next to itself (.exodus-backup-<time>).

Only the UserData table is written. Users, passwords, devices, library options and plugins are not
touched. Tested with Jellyfin's EF Core database (jellyfin.db, 10.11 and later). Standard library only.
"""
from __future__ import annotations

import argparse
import csv
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unicodedata
from collections import Counter

PK = ("ItemId", "UserId", "CustomDataKey")


def norm_path(p: str) -> str:
    return unicodedata.normalize("NFC", p.replace("\\", "/"))


class PathMap:
    def __init__(self, pairs: list[str]):
        self.rules = []
        for pair in pairs:
            old, sep, new = pair.partition("=")
            if not sep or not old or not new:
                sys.exit(f"--map '{pair}': expected OLD=NEW")
            self.rules.append((norm_path(old).rstrip("/").casefold(), norm_path(new).rstrip("/")))
        self.rules.sort(key=lambda r: len(r[0]), reverse=True)

    def __call__(self, old_path: str) -> str | None:
        p = norm_path(old_path)
        low = p.casefold()
        for old, new in self.rules:
            if low == old or low.startswith(old + "/"):
                return new + p[len(old):]
        return None


def open_db(path: str, readonly: bool) -> sqlite3.Connection:
    if not os.path.isfile(path):
        sys.exit(f"{path}: no such file")
    uri = f"file:{path}?mode=ro" if readonly else f"file:{path}?mode=rw"
    try:
        con = sqlite3.connect(uri, uri=True)
        con.execute("select count(*) from sqlite_master").fetchone()
    except sqlite3.Error as e:
        sys.exit(f"{path}: cannot open ({e})")
    return con


def columns(con: sqlite3.Connection, table: str) -> list[str]:
    return [r[1] for r in con.execute(f'PRAGMA table_info("{table}")')]


def check_schema(old: sqlite3.Connection, new: sqlite3.Connection) -> list[str]:
    for name, con in (("old", old), ("new", new)):
        for table, need in (("Users", {"Id", "Username"}), ("BaseItems", {"Id", "Path"}),
                            ("UserData", set(PK) | {"LastPlayedDate", "PlayCount", "IsFavorite"})):
            missing = need - set(columns(con, table))
            if missing:
                sys.exit(f"{name} DB: table {table} lacks {sorted(missing)}. "
                         "Not a Jellyfin 10.11+ jellyfin.db (older servers keep user data in library.db).")
    oc, nc = columns(old, "UserData"), columns(new, "UserData")
    extra = [c for c in oc if c not in nc]
    if extra:
        print(f"note: old UserData columns not on the new server, dropped: {extra}", file=sys.stderr)
    return [c for c in oc if c in nc]


def jellyfin_running() -> bool:
    if not shutil.which("systemctl"):
        return False
    return subprocess.run(["systemctl", "is-active", "--quiet", "jellyfin"]).returncode == 0


def same_id(a: str, b: str) -> bool:
    return a.replace("-", "").lower() == b.replace("-", "").lower()


def restyle_id(new_id: str, like: str) -> str:
    """new_id written the way the old key was (Jellyfin keys use the lowercase item id)."""
    s = new_id.lower()
    return s if "-" in like else s.replace("-", "")


def merge(old: dict, cur: dict, policy: str) -> dict | None:
    """-> the row to write over cur, or None to keep cur as is."""
    if policy == "keep":
        return None
    if policy == "replace":
        return old
    newer = old if (old.get("LastPlayedDate") or "") > (cur.get("LastPlayedDate") or "") else cur
    out = dict(newer)
    out["IsFavorite"] = int(bool(old.get("IsFavorite")) or bool(cur.get("IsFavorite")))
    out["PlayCount"] = max(old.get("PlayCount") or 0, cur.get("PlayCount") or 0)
    out.update({k: cur[k] for k in PK})
    return None if out == cur else out


def plan(old, new, cols, pmap: PathMap, user_map: dict, policy: str):
    stats, per_user, unmatched = Counter(), Counter(), []
    new_users = {u.casefold(): i for i, u in new.execute("select Id, Username from Users")}
    old_users = dict(old.execute("select Id, Username from Users"))
    umap = {}
    for oid, name in old_users.items():
        target = user_map.get(name.casefold(), name)
        umap[oid] = (name, new_users.get(target.casefold()))
    exact, folded = {}, {}
    for iid, p in new.execute("select Id, Path from BaseItems where Path is not null"):
        n = norm_path(p)
        exact[n] = iid
        folded.setdefault(n.casefold(), []).append(iid)
    old_paths = dict(old.execute("select Id, Path from BaseItems"))

    sel = ", ".join(f'd."{c}"' for c in cols)
    writes = []
    for row in old.execute(f"select {sel} from UserData d"):
        r = dict(zip(cols, row))
        stats["old rows"] += 1
        uname, new_uid = umap.get(r["UserId"], ("?", None))
        if not new_uid:
            stats[f"skipped: user '{uname}' not on the new server"] += 1
            continue
        path = old_paths.get(r["ItemId"])
        if not path:
            stats["skipped: old item has no path (placeholder or detached)"] += 1
            continue
        target = pmap(path)
        if target is None:
            stats["skipped: path outside every --map"] += 1
            continue
        new_iid = exact.get(target)
        if not new_iid:
            cand = folded.get(target.casefold(), [])
            if len(cand) == 1:
                new_iid = cand[0]
                stats["matched ignoring case"] += 1
        if not new_iid:
            stats["skipped: no item with that path on the new server"] += 1
            unmatched.append((uname, path, target))
            continue
        key = r["CustomDataKey"]
        if same_id(key, r["ItemId"]):
            key = restyle_id(new_iid, key)
        writes.append(dict(r, ItemId=new_iid, UserId=new_uid, CustomDataKey=key))
        per_user[uname] += 1

    actions = []
    q = f"select {', '.join(chr(34) + c + chr(34) for c in cols)} from UserData where ItemId=? and UserId=? and CustomDataKey=?"
    for w in writes:
        cur = new.execute(q, (w["ItemId"], w["UserId"], w["CustomDataKey"])).fetchone()
        if cur is None:
            actions.append(("insert", w))
            stats["to insert"] += 1
            continue
        m = merge(w, dict(zip(cols, cur)), policy)
        if m is None:
            stats["already there (kept)"] += 1
        else:
            actions.append(("update", m))
            stats["to update"] += 1
    return stats, per_user, unmatched, actions


def backup(path: str, con: sqlite3.Connection) -> str:
    dst = f"{path}.exodus-backup-{time.strftime('%Y%m%d-%H%M%S')}"
    b = sqlite3.connect(dst)
    con.backup(b)
    b.close()
    st = os.stat(path)
    os.chmod(dst, st.st_mode & 0o777)
    if os.geteuid() == 0:
        os.chown(dst, st.st_uid, st.st_gid)
    return dst


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split("\n\n", 2)[2])
    ap.add_argument("old_db")
    ap.add_argument("new_db")
    ap.add_argument("--map", action="append", required=True, metavar="OLD=NEW")
    ap.add_argument("--user", action="append", default=[], metavar="OLD=NEW")
    ap.add_argument("--on-conflict", choices=("newest", "keep", "replace"), default="newest")
    ap.add_argument("--unmatched", metavar="CSV")
    ap.add_argument("--not-live", action="store_true")
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)

    user_map = {}
    for pair in a.user:
        o, sep, n = pair.partition("=")
        if not sep:
            sys.exit(f"--user '{pair}': expected OLD=NEW")
        user_map[o.casefold()] = n
    if a.apply and not a.not_live and jellyfin_running():
        sys.exit("jellyfin is running: sudo systemctl stop jellyfin, then run this again")

    tmp = tempfile.TemporaryDirectory(prefix="jellyfin-carry-")
    try:
        return run(a, user_map, tmp.name)
    finally:
        tmp.cleanup()


def run(a, user_map: dict, tmpdir: str) -> int:
    old_copy = os.path.join(tmpdir, "old.db")
    if not os.path.isfile(a.old_db):
        sys.exit(f"{a.old_db}: no such file")
    shutil.copyfile(a.old_db, old_copy)
    if os.path.isfile(a.old_db + "-wal"):
        shutil.copyfile(a.old_db + "-wal", old_copy + "-wal")
    old = open_db(old_copy, readonly=True)
    try:
        return carry(a, user_map, old)
    finally:
        old.close()


def carry(a, user_map: dict, old: sqlite3.Connection) -> int:
    new = open_db(a.new_db, readonly=not a.apply)
    try:
        return write(a, user_map, old, new)
    finally:
        new.close()


def write(a, user_map: dict, old: sqlite3.Connection, new: sqlite3.Connection) -> int:
    cols = check_schema(old, new)
    stats, per_user, unmatched, actions = plan(old, new, cols, PathMap(a.map), user_map, a.on_conflict)

    for k, v in stats.items():
        print(f"{v:7d}  {k}")
    if per_user:
        print("per user: " + ", ".join(f"{u} {n}" for u, n in sorted(per_user.items())))
    for u, p, t in unmatched[:10]:
        print(f"  no match: {p}  ->  {t}")
    if len(unmatched) > 10:
        print(f"  ... {len(unmatched) - 10} more" + ("" if a.unmatched else " (--unmatched FILE lists them all)"))
    if a.unmatched:
        with open(a.unmatched, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["user", "old_path", "looked_for"])
            w.writerows(unmatched)

    if not a.apply:
        print("Dry run: nothing changed. Stop Jellyfin, then add --apply.")
        return 0
    if not actions:
        print("Nothing to write.")
        return 0
    wal = a.new_db + "-wal"
    if os.path.exists(wal) and os.path.getsize(wal) > 0:
        print(f"note: {wal} is not empty (Jellyfin not stopped cleanly?); SQLite will include it.", file=sys.stderr)
    dst = backup(a.new_db, new)
    print(f"backup: {dst}")
    qcols = ", ".join(f'"{c}"' for c in cols)
    marks = ", ".join("?" for _ in cols)
    new.execute("PRAGMA foreign_keys = ON")      # no-op inside a transaction, so before it
    try:
        with new:
            new.executemany(f"insert or replace into UserData ({qcols}) values ({marks})",
                            [tuple(r[c] for c in cols) for _, r in actions])
    except sqlite3.Error as e:
        sys.exit(f"write failed, nothing changed ({e}). Backup kept at {dst}")
    print(f"wrote {len(actions)} row(s). Start Jellyfin again: sudo systemctl start jellyfin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
