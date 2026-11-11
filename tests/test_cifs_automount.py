"""linux/cifs-automount.sh, run against a temporary fstab and drop-in dir (no root, no systemctl).
Run: python3 -m unittest discover -s tests   (from the repo root)"""
import getpass
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "linux" / "cifs-automount.sh"


class CifsAutomount(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        self.fstab = self.d / "fstab"
        self.fstab.write_text("# test fstab\n")
        self.cred = self.d / "nas.cred"
        self.cred.write_text("username=u\npassword=p\n")  # leak-check: allow
        self.cred.chmod(0o600)
        self.mnt = self.d / "mnt" / "My Shows"

    def tearDown(self):
        self.tmp.cleanup()

    def run_it(self, *extra, share="My Shows", mnt=None):
        args = ["bash", str(SCRIPT), "--server", "nas.lan", "--share", share, "--mount", str(mnt or self.mnt),
                "--cred", str(self.cred), "--owner", getpass.getuser(), "--fstab", str(self.fstab),
                "--dropin-dir", str(self.d / "systemd"), "--no-reload", *extra]
        return subprocess.run(args, capture_output=True, text=True, stdin=subprocess.DEVNULL)

    def cifs_lines(self):
        return [l for l in self.fstab.read_text().splitlines() if " cifs " in l]

    def test_dry_run_changes_nothing(self):
        p = self.run_it("--for", "jellyfin.service")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("Dry run: nothing changed", p.stdout)
        self.assertEqual(self.cifs_lines(), [])
        self.assertFalse((self.d / "systemd").exists())
        self.assertFalse(self.mnt.exists())

    def test_apply_line_escaping_and_idempotence(self):
        p = self.run_it("--apply", "--after", "tailscaled.service", "--for", "jellyfin.service", "--group-write")
        self.assertEqual(p.returncode, 0, p.stderr)
        lines = self.cifs_lines()
        self.assertEqual(len(lines), 1)
        src, dst, fstype, opts, *_ = lines[0].split()
        self.assertEqual(src, "//nas.lan/My\\040Shows")
        self.assertEqual(dst, str(self.mnt).replace(" ", "\\040"))
        for o in ("x-systemd.automount", "nofail", "_netdev", f"credentials={self.cred}",
                  "x-systemd.after=tailscaled.service", "file_mode=0664", "x-systemd.idle-timeout=0"):
            self.assertIn(o, opts.split(","))
        self.assertTrue(self.mnt.is_dir())
        self.assertTrue(list(self.d.glob("fstab.bak-*")))
        dropin = list((self.d / "systemd" / "jellyfin.service.d").glob("exodus-cifs-*.conf"))
        self.assertEqual(len(dropin), 1)
        body = dropin[0].read_text()
        self.assertIn("Wants=", body)
        self.assertNotIn("Requires=", body)        # the service still starts if the NAS is down
        if shutil.which("systemd-escape"):
            unit = subprocess.run(["systemd-escape", "--path", "--suffix=mount", str(self.mnt)],
                                  capture_output=True, text=True).stdout.strip()
            self.assertIn(f"After={unit} remote-fs.target", body)
        # second run: no duplicate line
        self.assertEqual(self.run_it("--apply", "--after", "tailscaled.service", "--group-write").returncode, 0)
        self.assertEqual(len(self.cifs_lines()), 1)

    @unittest.skipUnless(shutil.which("findmnt"), "needs findmnt")
    def test_findmnt_accepts_the_line(self):
        self.run_it("--apply")
        p = subprocess.run(["findmnt", "--verify", "--tab-file", str(self.fstab)], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)

    def test_differing_entry_left_alone(self):
        self.fstab.write_text(f"//other/x {str(self.mnt).replace(' ', chr(92) + '040')} cifs guest 0 0\n")
        p = self.run_it("--apply")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("differs, left alone", p.stderr)
        self.assertEqual(self.cifs_lines(), [f"//other/x {str(self.mnt).replace(' ', chr(92) + '040')} cifs guest 0 0"])

    def test_missing_cred_without_terminal_refuses(self):
        self.cred.unlink()
        p = self.run_it("--apply")
        self.assertEqual(p.returncode, 1)
        self.assertIn("no terminal", p.stderr)
        self.assertEqual(self.cifs_lines(), [])

    def test_bad_input(self):
        self.assertEqual(self.run_it(share="a,b").returncode, 1)
        self.assertEqual(self.run_it(mnt="relative/dir").returncode, 1)
        p = subprocess.run(["bash", str(SCRIPT), "--server", "nas"], capture_output=True, text=True)
        self.assertIn("required", p.stderr)


if __name__ == "__main__":
    unittest.main()
