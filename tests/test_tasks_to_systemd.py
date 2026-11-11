"""Run: python3 -m unittest discover -s tests   (from the repo root)"""
import importlib.util
import shutil
import sys
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("t2s", ROOT / "linux" / "tasks-to-systemd.py")
t2s = importlib.util.module_from_spec(spec)
sys.modules["t2s"] = t2s
spec.loader.exec_module(t2s)


class SampleInventory(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name)
        rc = t2s.main([str(ROOT / "examples/inventory.sample.json"),
                       "-c", str(ROOT / "examples/exodus.config.sample-test.json"),
                       "-o", str(cls.out), "--validate"])
        assert rc == 0, "converter reported validation errors"

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def timer(self, name):
        return (self.out / f"exo-job-{name}.timer").read_text()

    def service(self, name):
        return (self.out / f"{name}.service").read_text()

    def test_calendar_translations(self):
        cases = {
            "nightly-backup": "OnCalendar=*-*-* 18:30:00",
            "weekly-report": "OnCalendar=Mon,Fri *-*-* 06:00:00",
            "monthly-audit": "OnCalendar=*-*-01,15 09:00:00",
            "month-end": "OnCalendar=*-03,06,09,12~01 22:00:00",
            "first-monday": "OnCalendar=Mon *-*-01..07 07:00:00",
            "last-friday": "OnCalendar=Fri *-*~07/1 17:00:00",
            "every-15-minutes": "OnCalendar=*-*-* *:05/15:00",
            "work-hours-hourly": "OnCalendar=*-*-* 08..17/1:00:00",
        }
        for name, line in cases.items():
            with self.subTest(name=name):
                self.assertIn(line, self.timer(name))

    def test_monotonic_and_boot(self):
        self.assertIn("OnUnitActiveSec=90min", self.timer("every-90-minutes"))
        self.assertIn("OnBootSec=2min", self.timer("at-boot"))
        self.assertIn("RandomizedDelaySec=2min", self.timer("daily-collect"))

    def test_untranslatable_triggers_get_no_timer(self):
        for name in ("at-logon", "on-event"):
            self.assertFalse((self.out / f"exo-job-{name}.timer").exists())
        self.assertIn("LogonTrigger", (self.out / "REPORT.md").read_text())

    def test_unmapped_units_fail_loudly(self):
        s = self.service("exo-job-weekly-report")
        self.assertIn("not ported yet", s)
        self.assertIn("exit 1", s)

    def test_mapping_paths_users_credentials(self):
        s = self.service("exo-job-daily-collect")
        self.assertIn("User=alice", s)
        self.assertIn("WorkingDirectory=/home/alice/projects/myapp", s)
        self.assertIn("LoadCredential=api-token:/etc/myapp/api.token", s)
        self.assertIn("RequiresMountsFor=/mnt/nas/backup", self.service("exo-job-nightly-backup"))
        self.assertIn("User=root", self.service("exo-job-every-15-minutes"))   # S-1-5-18
        self.assertIn("TimeoutStartSec=infinity", self.service("exo-job-unlimited"))

    def test_services(self):
        self.assertIn("Restart=always", self.service("exo-mydashboard"))
        self.assertIn("streamlit", self.service("exo-mydashboard"))
        self.assertFalse((self.out / "exo-manualthing.service").exists())   # Manual start type

    def test_excludes(self):
        self.assertFalse((self.out / "exo-job-excludedbyconfig.service").exists())

    def test_firewall_and_apps(self):
        r = (self.out / "REPORT.md").read_text()
        self.assertIn("ufw allow in on tailscale0 to any port 8501 proto tcp", r)
        self.assertIn("VLC media player", (self.out / "apps.csv").read_text())

    @unittest.skipUnless(shutil.which("systemd-analyze"), "needs systemd-analyze")
    def test_units_verify(self):
        files = sorted(str(p) for p in self.out.glob("exo-*.*"))
        p = subprocess.run(["systemd-analyze", "verify", "--man=no", *files],
                           capture_output=True, text=True, cwd=self.out)
        bad = [l for l in p.stderr.splitlines()
               if "exo-" in l and not any(k in l for k in ("user", "is not executable", "dependency"))]
        self.assertEqual(bad, [])


class Units(unittest.TestCase):
    def test_iso_duration(self):
        self.assertEqual(t2s.iso_duration_seconds("PT1H30M"), 5400)
        self.assertEqual(t2s.iso_duration_seconds("P1D"), 86400)
        self.assertEqual(t2s.iso_duration_seconds("PT0S"), 0)
        self.assertIsNone(t2s.iso_duration_seconds("garbage"))

    def test_path_map_longest_prefix(self):
        c = t2s.Config(path_map={"C:\\Users": "/home", "C:\\Users\\Alice": "/home/alice"})
        self.assertEqual(c.map_path("c:\\users\\alice\\x\\y.txt"), "/home/alice/x/y.txt")


if __name__ == "__main__":
    unittest.main()
