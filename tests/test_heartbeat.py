"""Heartbeats: linux/run-monitored.sh and the converter's exec_map "heartbeat" key.
Run: python3 -m unittest discover -s tests   (from the repo root)"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import test_tasks_to_systemd as tts
from test_tasks_to_systemd import ROOT, t2s

WRAPPER = ROOT / "linux" / "run-monitored.sh"
FAKE_CURL = """#!/bin/sh
# fake curl: logs its arguments (one line per call), fails when $FAKE_CURL_FAIL is set
echo "$*" >> "$FAKE_LOG"
[ -z "$FAKE_CURL_FAIL" ]
"""


class Wrapper(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        (d / "bin").mkdir()
        (d / "bin" / "curl").write_text(FAKE_CURL)
        (d / "bin" / "curl").chmod(0o755)
        self.log = d / "curl.log"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("HEARTBEAT_", "CREDENTIALS_"))}
        self.env.update(PATH=f"{d / 'bin'}:{os.environ['PATH']}", FAKE_LOG=str(self.log),
                        HEARTBEAT_RETRY_SLEEP="0")

    def tearDown(self):
        self.tmp.cleanup()

    def run_job(self, cmd, **env):
        e = dict(self.env, **env)
        p = subprocess.run(["bash", str(WRAPPER), "my-job", "--", "sh", "-c", cmd],
                           capture_output=True, text=True, env=e)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return p, calls

    def test_no_url_runs_without_push(self):
        p, calls = self.run_job("echo hi; exit 3")
        self.assertEqual((p.returncode, p.stdout, calls), (3, "hi\n", []))

    def test_kuma_up_and_down(self):
        url = "https://kuma.example/api/push/TOKEN?status=up&msg=OK&ping="
        p, calls = self.run_job("exit 0", HEARTBEAT_URL=url)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertIn("https://kuma.example/api/push/TOKEN ", calls[0] + " ")   # query string dropped
        self.assertIn("status=up", calls[0])
        self.assertIn("msg=my-job exit 0", calls[0])
        self.assertIn("ping=", calls[0])
        self.log.unlink()
        p, calls = self.run_job("exit 4", HEARTBEAT_URL=url)
        self.assertEqual(p.returncode, 4)
        self.assertIn("status=down", calls[0])

    def test_healthchecks_exit_code(self):
        p, calls = self.run_job("exit 2", HEARTBEAT_URL="https://hc-ping.com/abc-uuid/")
        self.assertEqual(p.returncode, 2)
        self.assertTrue(calls[0].endswith("https://hc-ping.com/abc-uuid/2"), calls)

    def test_plain_pings_only_on_success(self):
        _, calls = self.run_job("exit 1", HEARTBEAT_URL="https://mon.example/beat")
        self.assertEqual(calls, [])
        _, calls = self.run_job("exit 0", HEARTBEAT_URL="https://mon.example/beat")
        self.assertTrue(calls[0].endswith("https://mon.example/beat"))

    def test_credential_file_wins_and_failed_push_keeps_exit_code(self):
        creds = Path(self.tmp.name) / "creds"
        creds.mkdir()
        (creds / "heartbeat-url").write_text("https://hc-ping.com/from-cred\n")
        p, calls = self.run_job("exit 0", CREDENTIALS_DIRECTORY=str(creds), FAKE_CURL_FAIL="1",
                                HEARTBEAT_URL="https://hc-ping.com/ignored")
        self.assertEqual(p.returncode, 0)                      # push failed, job still succeeded
        self.assertEqual(len(calls), 3)                        # 3 tries
        self.assertTrue(all("from-cred/0" in c for c in calls))
        self.assertIn("heartbeat push failed", p.stderr)

    def test_no_command(self):
        p = subprocess.run(["bash", str(WRAPPER), "x", "--"], capture_output=True, text=True, env=self.env)
        self.assertEqual(p.returncode, 2)


class Converter(tts.Cutover):
    """exec_map "heartbeat": wrapped ExecStart, LoadCredential, REPORT, cutover-linux checks."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        d = Path(cls.tmp.name)
        cfg = json.loads((ROOT / "examples/exodus.config.sample-test.json").read_text())
        cfg["exec_map"]["\\Nightly Backup"]["heartbeat"] = True
        cfg["exec_map"]["\\Weekly Report"] = {"exec": ["/bin/true", "/bin/false"], "heartbeat": True}
        cfg["heartbeat_wrapper"] = str(d / "wrapper")
        cfg["heartbeat_dir"] = str(d / "hb")
        (d / "cfg.json").write_text(json.dumps(cfg))
        cls.out = d / "out"
        t2s.main([str(ROOT / "examples/inventory.sample.json"), "-c", str(d / "cfg.json"), "-o", str(cls.out)])

    def test_unit_wrapped(self):
        s = (self.out / "exo-job-nightly-backup.service").read_text()
        d = self.tmp.name
        self.assertIn(f"ExecStart={d}/wrapper exo-job-nightly-backup -- /usr/bin/rsync", s)
        self.assertIn(f"LoadCredential=heartbeat-url:{d}/hb/exo-job-nightly-backup.url", s)
        r = (self.out / "REPORT.md").read_text()
        self.assertIn("## Heartbeats", r)
        self.assertIn(f"{d}/hb/exo-job-nightly-backup.url", r)

    def test_multi_exec_not_wrapped(self):
        s = (self.out / "exo-job-weekly-report.service").read_text()
        self.assertNotIn("heartbeat-url", s)
        self.assertIn("heartbeat needs a single exec", (self.out / "REPORT.md").read_text())

    def test_unmapped_not_wrapped(self):
        self.assertNotIn("heartbeat-url", (self.out / "exo-job-daily-collect.service").read_text())

    def test_cutover_checks_wrapper_and_url_file(self):
        etc = self.install("etc-hb", ported_only=True)
        p = self.run_sh("cutover-linux.sh", etc, "--dry-run")
        self.assertEqual(p.returncode, 1)
        self.assertIn("install linux/run-monitored.sh", p.stderr)
        self.assertIn("exo-job-nightly-backup.url (heartbeat URL", p.stderr)
        d = Path(self.tmp.name)
        (d / "wrapper").write_text("#!/bin/sh\n")
        (d / "wrapper").chmod(0o755)
        (d / "hb").mkdir()
        (d / "hb" / "exo-job-nightly-backup.url").write_text("https://hc-ping.com/x\n")
        p = self.run_sh("cutover-linux.sh", etc, "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)

    # inherited Cutover tests that don't apply with heartbeat files missing
    test_linux_dry_run_ok = test_windows_dry_run = test_lists = None


if __name__ == "__main__":
    unittest.main()
