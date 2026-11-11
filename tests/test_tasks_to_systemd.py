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
        self.assertIn("Wait = $true", (self.out / "cutover-windows.ps1").read_text(encoding="utf-8-sig"))
        ps = (self.out / "cutover-windows.ps1").read_text(encoding="utf-8-sig")
        self.assertIn("Name = 'At Logon'; WasDisabled = $false; Wait = $false", ps)
        self.assertIn("Name = 'At Boot'; WasDisabled = $false; Wait = $false", ps)
        self.assertIn("Name = 'Every 15 Minutes'; WasDisabled = $false; Wait = $true", ps)

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


class Cutover(unittest.TestCase):
    """The generated cutover/rollback scripts, run in dry-run mode against fakes."""
    FAKE_SYSTEMCTL = """#!/bin/sh
# fake: 'show -P FragmentPath UNIT' prints $FAKE_ETC/UNIT if it exists, anything else is logged
if [ "$1" = show ]; then [ -f "$FAKE_ETC/$4" ] && echo "$FAKE_ETC/$4"; exit 0; fi
echo "$@" >> "$FAKE_ETC/calls.log"
"""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.out = Path(cls.tmp.name) / "out"
        t2s.main([str(ROOT / "examples/inventory.sample.json"),
                  "-c", str(ROOT / "examples/exodus.config.sample-test.json"), "-o", str(cls.out)])

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_sh(self, script, etc, *args):
        import os
        bindir = Path(self.tmp.name) / "bin"
        bindir.mkdir(exist_ok=True)
        (bindir / "systemctl").write_text(self.FAKE_SYSTEMCTL)
        (bindir / "systemctl").chmod(0o755)
        env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", FAKE_ETC=str(etc))
        return subprocess.run(["bash", str(self.out / script), *args], capture_output=True, text=True, env=env)

    def install(self, name, ported_only=False):
        etc = Path(self.tmp.name) / name
        etc.mkdir()
        for f in self.out.glob("exo-*.*"):
            body = f.read_text()
            if ported_only:
                body = body.replace("is not ported yet", "was a TODO")
            (etc / f.name).write_text(body)
        return etc

    def test_lists(self):
        sh = (self.out / "cutover-linux.sh").read_text()
        self.assertIn("exo-job-nightly-backup.timer", sh)
        self.assertIn("exo-mydashboard.service", sh)
        self.assertNotIn("exo-job-disabled-task.timer", sh)      # disabled on Windows -> not enabled
        self.assertNotIn("exo-job-at-logon", sh)                  # no timer -> nothing to enable
        self.assertIn("exo-job-at-logon.service", (self.out / "rollback-linux.sh").read_text())
        ps = (self.out / "rollback-windows.ps1").read_bytes()
        self.assertTrue(ps.startswith(b"\xef\xbb\xbf") and b"\r\n" in ps)  # BOM + CRLF for PS 5.1
        self.assertIn(b"Path = '\\MyApp\\'; Name = 'Daily Collect'", ps)
        self.assertIn("cutover-linux.sh", (self.out / "REPORT.md").read_text())

    def test_ps_quote(self):
        self.assertEqual(t2s.ps_quote("Bob's \u2019task"), "'Bob''s \u2019\u2019task'")
        self.assertEqual(t2s.split_task("\\A\\B\\name"), ("\\A\\B\\", "name"))
        self.assertEqual(t2s.split_task("name"), ("\\", "name"))

    def test_linux_refuses_when_not_installed(self):
        p = self.run_sh("cutover-linux.sh", Path(self.tmp.name), "--dry-run")
        self.assertEqual(p.returncode, 1)
        self.assertIn("not installed in systemd", p.stderr)

    def test_linux_refuses_unported(self):
        p = self.run_sh("cutover-linux.sh", self.install("etc-todo"), "--dry-run")
        self.assertEqual(p.returncode, 1)
        self.assertIn("not ported yet", p.stderr)

    def test_linux_dry_run_ok(self):
        etc = self.install("etc-ok", ported_only=True)
        p = self.run_sh("cutover-linux.sh", etc, "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("would enable --now: exo-mydashboard.service", p.stdout)
        p = self.run_sh("rollback-linux.sh", etc, "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse((etc / "calls.log").exists())                # dry run changed nothing

    def test_linux_needs_root(self):
        import os
        if os.geteuid() == 0:
            self.skipTest("running as root")
        self.assertEqual(self.run_sh("rollback-linux.sh", Path(self.tmp.name)).returncode, 1)

    @unittest.skipUnless(shutil.which("pwsh"), "needs pwsh")
    def test_windows_dry_run(self):
        stubs = (
            "function Get-ScheduledTask { param($TaskPath, $TaskName, $ErrorAction) "
            "[pscustomobject]@{ TaskPath = $TaskPath; TaskName = $TaskName; "
            "State = $(if ($TaskName -in 'Nightly Backup', 'At Logon') { 'Running' } "
            "elseif ($TaskName -eq 'Disabled Task') { 'Disabled' } else { 'Ready' }) } }; "
            "function Get-Service { param($Name, $ErrorAction) [pscustomobject]@{ Name = $Name; Status = 'Running' } }; ")
        p = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-c",
                            stubs + f"& '{self.out}/cutover-windows.ps1' -DryRun; exit $LASTEXITCODE"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("would stop + disable service  MyDashboard", p.stdout)
        self.assertIn("already disabled  \\Disabled Task", p.stdout)
        self.assertNotIn("would disable task  \\Disabled Task", p.stdout)
        self.assertIn("STILL RUNNING: \\Nightly Backup", p.stdout + p.stderr)
        self.assertNotIn("At Logon", (p.stdout + p.stderr).split("STILL RUNNING")[1])   # agent: not waited for
        self.assertIn("not waited for (logon/boot/event task, the shutdown ends it): \\At Logon", p.stdout)
        p = subprocess.run(["pwsh", "-NoProfile", "-NonInteractive", "-c",
                            stubs + f"& '{self.out}/rollback-windows.ps1' -DryRun; exit $LASTEXITCODE"],
                           capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("left disabled (it was at export)  \\Disabled Task", p.stdout)


class Units(unittest.TestCase):
    def test_vendor_excludes_case_insensitive(self):
        cfg = t2s.Config()
        for name in ("\\ASUS\\AcPowerNotification", "\\asus\\ASUSUpdateTaskMachineCore",
                     "\\BraveSoftwareUpdateTaskMachineCore{0F7B4B0E-1E7A-4B3A-9A4C-000000000000}",
                     "\\GoogleUpdaterTaskSystem140.0.0.0{X}", "\\NvTmRep_CrashReport1_{X}",
                     "service:gupdate", "service:GUPDATEM", "service:brave", "service:NVDisplay.ContainerLocalSystem"):
            self.assertFalse(cfg.wanted(name), name)
        for name in ("\\Weekly Update Reboot", "\\App Watchdog", "\\Nightly Backup",
                     "service:MyDashboard", "\\HPC Jobs\\x", "service:bravo-api"):
            self.assertTrue(cfg.wanted(name), name)
        extra = t2s.Config(exclude_extra=["\\Nightly*"])
        self.assertFalse(extra.wanted("\\nightly backup"))
        self.assertFalse(extra.wanted("\\ASUS\\AcPowerNotification"))        # defaults kept
        self.assertTrue(t2s.Config(exclude=[]).wanted("\\ASUS\\AcPowerNotification"))
        self.assertEqual(t2s.Config(include=["\\A*"]).excluded_by("\\B"), "(not in include)")
        keep = t2s.Config(keep=["service:steam client service"], exclude_extra=["service:Steam*"])
        self.assertTrue(keep.wanted("service:Steam Client Service"))           # keep wins over both lists
        self.assertFalse(keep.wanted("service:gupdate"))                       # other defaults kept

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
