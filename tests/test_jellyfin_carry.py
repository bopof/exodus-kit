"""linux/jellyfin-carry-userdata.py against two small synthetic jellyfin.db files.
Run: python3 -m unittest discover -s tests   (from the repo root)"""
import importlib.util
import io
import sqlite3
import tempfile
from contextlib import closing
import unittest
from contextlib import redirect_stdout
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("jcarry", ROOT / "linux" / "jellyfin-carry-userdata.py")
jc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(jc)

SCHEMA = """
CREATE TABLE Users (Id TEXT PRIMARY KEY, Username TEXT NOT NULL);
CREATE TABLE BaseItems (Id TEXT PRIMARY KEY, Path TEXT NULL, Type TEXT NULL);
CREATE TABLE UserData (
    ItemId TEXT NOT NULL, UserId TEXT NOT NULL, CustomDataKey TEXT NOT NULL,
    AudioStreamIndex INTEGER NULL, IsFavorite INTEGER NOT NULL, LastPlayedDate TEXT NULL, Likes INTEGER NULL,
    PlayCount INTEGER NOT NULL, PlaybackPositionTicks INTEGER NOT NULL, Played INTEGER NOT NULL,
    Rating REAL NULL, SubtitleStreamIndex INTEGER NULL, RetentionDate TEXT NULL,
    CONSTRAINT PK_UserData PRIMARY KEY (ItemId, UserId, CustomDataKey),
    FOREIGN KEY (ItemId) REFERENCES BaseItems (Id) ON DELETE CASCADE,
    FOREIGN KEY (UserId) REFERENCES Users (Id) ON DELETE CASCADE);
"""
O1, O2, O3, O4, O5 = ("AAAAAAAA-0000-0000-0000-00000000000%d" % i for i in range(1, 6))
N1, N2, N3 = ("BBBBBBBB-0000-0000-0000-00000000000%d" % i for i in range(1, 4))


def ud(item, user, key, played=1, count=1, pos=0, fav=0, last="2026-01-01 10:00:00"):
    return (item, user, key, None, fav, last, None, count, pos, played, None, None, None)


def make(path, users, items, rows):
    con = sqlite3.connect(path)
    con.executescript(SCHEMA)
    con.executemany("insert into Users values (?,?)", users)
    con.executemany("insert into BaseItems values (?,?,'Movie')", items)
    con.executemany("insert into UserData values (?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    con.commit()
    con.close()


class Carry(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.old, self.new = str(d / "old.db"), str(d / "new.db")
        make(self.old, [("OU1", "Alice"), ("OU2", "bob"), ("OU3", "ghost")],
             [(O1, r"\\nas\Movies\Film A (2001)\a.mkv"), (O2, r"\\NAS\movies\Film B\b.mkv"),
              (O3, r"\\nas\Music\song.flac"), (O4, None), (O5, r"\\nas\Movies\Gone\gone.mkv")],
             [ud(O1, "OU1", O1.lower()), ud(O1, "OU1", "tt0000001"),
              ud(O2, "OU1", "tt0000002", played=0, pos=5000, last="2026-03-01 10:00:00", fav=1),
              ud(O1, "OU2", "tt0000001", count=4),
              ud(O3, "OU1", "song"), ud(O4, "OU1", "placeholder"), ud(O5, "OU1", "gone"),
              ud(O1, "OU3", "tt0000001")])
        make(self.new, [("NU1", "alice"), ("NU2", "Robert")],
             [(N1, "/mnt/nas/Movies/Film A (2001)/a.mkv"), (N2, "/mnt/nas/Movies/Film B/b.mkv"),
              (N3, "/mnt/nas/Movies/other.mkv")],
             [ud(N2, "NU1", "tt0000002", played=1, count=2, last="2026-02-01 10:00:00")])

    def tearDown(self):
        self.tmp.cleanup()

    def run_it(self, *extra):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = jc.main([self.old, self.new, "--map", r"\\nas\Movies=/mnt/nas/Movies", "--not-live", *extra])
        return rc, buf.getvalue()

    def rows(self):
        with closing(sqlite3.connect(self.new)) as con:
            return {(r[0], r[1], r[2]): r for r in con.execute("select * from UserData")}

    def test_dry_run_reports_and_changes_nothing(self):
        before = self.rows()
        rc, out = self.run_it()
        self.assertEqual(rc, 0)
        self.assertEqual(self.rows(), before)
        self.assertIn("skipped: user 'bob' not on the new server", out)
        self.assertIn("skipped: user 'ghost' not on the new server", out)
        self.assertIn("skipped: path outside every --map", out)               # Music not mapped
        self.assertIn("skipped: old item has no path", out)
        self.assertIn("skipped: no item with that path on the new server", out)
        self.assertIn("no match: \\\\nas\\Movies\\Gone\\gone.mkv", out)
        self.assertIn("Dry run", out)

    def test_apply_maps_items_users_and_item_id_key(self):
        rc, out = self.run_it("--apply", "--user", "bob=Robert")
        self.assertEqual(rc, 0, out)
        r = self.rows()
        self.assertIn((N1, "NU1", N1.lower()), r)              # key that was the old item id -> new item id
        self.assertNotIn((N1, "NU1", O1.lower()), r)
        self.assertIn((N1, "NU1", "tt0000001"), r)             # provider keys kept as they are
        self.assertEqual(r[(N1, "NU2", "tt0000001")][7], 4)    # bob -> Robert via --user, play count kept
        self.assertTrue(list(Path(self.tmp.name).glob("new.db.exodus-backup-*")))
        with closing(sqlite3.connect(self.new)) as con:
            self.assertEqual(con.execute("pragma foreign_key_check").fetchall(), [])

    def test_case_insensitive_prefix_and_newest_merge(self):
        self.run_it("--apply")
        row = self.rows()[(N2, "NU1", "tt0000002")]
        # old row (played later, unwatched, at 5000 ticks, favorite) wins over the new one; play count max
        self.assertEqual((row[9], row[8], row[4], row[7], row[5]), (0, 5000, 1, 2, "2026-03-01 10:00:00"))

    def test_keep_policy(self):
        self.run_it("--apply", "--on-conflict", "keep")
        row = self.rows()[(N2, "NU1", "tt0000002")]
        self.assertEqual((row[9], row[7]), (1, 2))

    def test_old_db_never_written(self):
        before = Path(self.old).stat().st_mtime_ns
        self.run_it("--apply")
        self.assertEqual(Path(self.old).stat().st_mtime_ns, before)
        self.assertFalse(Path(self.old + "-shm").exists())

    def test_rerun_is_idempotent(self):
        self.run_it("--apply")
        first = self.rows()
        rc, out = self.run_it("--apply")
        self.assertEqual(self.rows(), first)
        self.assertIn("Nothing to write", out)

    def test_pathmap(self):
        m = jc.PathMap([r"\\nas\Movies=/mnt/m", r"\\nas\Movies\Kids=/srv/kids"])
        self.assertEqual(m(r"\\NAS\movies\Kids\x.mkv"), "/srv/kids/x.mkv")      # longest prefix wins
        self.assertEqual(m(r"\\nas\Movies\x.mkv"), "/mnt/m/x.mkv")
        self.assertIsNone(m(r"\\nas\MoviesOld\x.mkv"))                          # whole components only

    def test_rejects_non_jellyfin_db(self):
        bad = str(Path(self.tmp.name) / "bad.db")
        with closing(sqlite3.connect(bad)) as con:
            con.executescript("create table Users (Id text, Username text);")
        with self.assertRaises(SystemExit) as e, redirect_stdout(io.StringIO()):
            jc.main([bad, self.new, "--map", "a=b"])
        self.assertIn("lacks", str(e.exception))


if __name__ == "__main__":
    unittest.main()
