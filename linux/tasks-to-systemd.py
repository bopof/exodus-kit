#!/usr/bin/env python3
"""tasks-to-systemd -- turn a Windows export (windows/export-windows.ps1) into systemd units.

    python3 tasks-to-systemd.py inventory.json -c exodus.config.json -o out/ [--validate]

Writes into out/:
    <prefix>-job-<name>.service + .timer    one per scheduled task
    <prefix>-<name>.service                 one per auto-start third-party service (NSSM-aware)
    REPORT.md                               what was translated, approximated or skipped
    apps.csv                                installed apps, to fill in Linux equivalents

Nothing is installed or enabled. Unmapped actions become units that FAIL with
"not ported yet" -- they never run something wrong quietly.

Standard library only (Python 3.8+).
"""
from __future__ import annotations

import argparse
import csv
import fnmatch
import json
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

NS = {"t": "http://schemas.microsoft.com/windows/2004/02/mit/task"}
DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
DAY_ABBR = {d: d[:3] for d in DAYS}
MONTHS = ["January", "February", "March", "April", "May", "June", "July",
          "August", "September", "October", "November", "December"]
WELL_KNOWN_SIDS = {
    "S-1-5-18": "SYSTEM", "S-1-5-19": "LOCAL SERVICE", "S-1-5-20": "NETWORK SERVICE",
    "localsystem": "SYSTEM", "nt authority\\system": "SYSTEM",
    "nt authority\\localservice": "LOCAL SERVICE", "nt authority\\networkservice": "NETWORK SERVICE",
}
DEFAULT_EXCLUDES = ["\\Microsoft\\*", "\\MicrosoftEdge*", "\\GoogleUpdate*", "\\OneDrive*",
                    "\\Mozilla\\*", "\\NvTm*", "\\NVIDIA*", "\\Adobe*"]


# --------------------------------------------------------------------------- helpers
def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-") or "unnamed"


def iso_duration_seconds(d: str | None) -> int | None:
    """PT1H30M / P1D / PT0S -> seconds. None if absent or unparsable."""
    if not d:
        return None
    m = re.fullmatch(r"P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?", d.strip())
    if not m:
        return None
    dd, hh, mm, ss = (int(x) if x else 0 for x in m.groups())
    return ((dd * 24 + hh) * 60 + mm) * 60 + ss


def human_seconds(n: int) -> str:
    for unit, size in (("d", 86400), ("h", 3600), ("min", 60)):
        if n % size == 0 and n >= size:
            return f"{n // size}{unit}"
    return f"{n}s"


def sd_escape(s: str) -> str:
    """Escape for a systemd unit value that is NOT meant to contain specifiers."""
    return s.replace("%", "%%")


def find(el, path):
    return el.find(path, NS) if el is not None else None


def text(el, path, default=None):
    x = find(el, path)
    return x.text.strip() if x is not None and x.text else default


def kids(el, path):
    x = find(el, path)
    return list(x) if x is not None else []


def children(el, path):
    x = find(el, path)
    return [c.tag.split("}", 1)[-1] for c in x] if x is not None else []


# --------------------------------------------------------------------------- config
@dataclass
class Config:
    prefix: str = "exo"
    default_user: str = "root"
    user_map: dict = field(default_factory=dict)
    path_map: dict = field(default_factory=dict)
    include: list = field(default_factory=list)
    exclude: list = field(default_factory=lambda: list(DEFAULT_EXCLUDES))
    exec_map: dict = field(default_factory=dict)
    after: list = field(default_factory=lambda: ["network-online.target"])
    trusted_interface: str = "<trusted-iface>"
    persistent: bool = True

    @classmethod
    def load(cls, path: str | None) -> "Config":
        if not path:
            return cls()
        data = json.loads(Path(path).read_text(encoding="utf-8"))
        data = {k: v for k, v in data.items() if not k.startswith("_")}
        unknown = set(data) - set(cls.__dataclass_fields__)
        if unknown:
            sys.exit(f"config: unknown keys {sorted(unknown)}")
        return cls(**data)

    def map_path(self, p: str | None) -> str | None:
        if not p:
            return p
        out = p
        for win in sorted(self.path_map, key=len, reverse=True):
            if out.lower().startswith(win.lower()):
                out = self.path_map[win] + out[len(win):]
                return out.replace("\\", "/")
        return out

    def map_user(self, win_user: str | None) -> tuple[str, str | None]:
        """-> (linux user, warning or None)"""
        if not win_user:
            return self.default_user, None
        name = WELL_KNOWN_SIDS.get(win_user, WELL_KNOWN_SIDS.get(win_user.lower(), win_user))
        for cand in (name, name.split("\\")[-1]):
            for k, v in self.user_map.items():
                if k.lower() == cand.lower():
                    return v, None
        if name in ("SYSTEM", "LOCAL SERVICE", "NETWORK SERVICE"):
            return "root", f"ran as {name} on Windows -> root here; consider a dedicated user"
        return self.default_user, f"Windows user '{name}' not in user_map -> {self.default_user}"

    def wanted(self, full_path: str) -> bool:
        if any(fnmatch.fnmatch(full_path, pat) for pat in self.exclude):
            return False
        return not self.include or any(fnmatch.fnmatch(full_path, pat) for pat in self.include)

    def exec_for(self, *keys: str) -> dict | None:
        for k in keys:
            for mk, mv in self.exec_map.items():
                if mk.lower() == k.lower():
                    return {"exec": mv} if isinstance(mv, (str, list)) else mv
        return None


# --------------------------------------------------------------------------- triggers
@dataclass
class Schedule:
    on_calendar: list = field(default_factory=list)
    on_boot_sec: int | None = None
    on_unit_active_sec: int | None = None
    randomized_delay: int = 0
    notes: list = field(default_factory=list)      # approximations
    skipped: list = field(default_factory=list)    # triggers we could not express


def months_spec(trig) -> str:
    ms = children(trig, "t:Months")
    if not ms or set(ms) >= set(MONTHS):
        return "*"
    return ",".join(f"{MONTHS.index(m) + 1:02d}" for m in MONTHS if m in ms)


def repetition_time_specs(start_h: int, start_m: int, start_s: int, trig, sched: Schedule) -> list[str] | None:
    """Translate <Repetition> into the time part(s) of OnCalendar. None = no repetition."""
    rep = find(trig, "t:Repetition")
    iv = iso_duration_seconds(text(rep, "t:Interval"))
    if not iv:
        return None
    dur = iso_duration_seconds(text(rep, "t:Duration"))
    full_day = dur is None or dur == 0 or dur >= 86400
    if iv % 3600 == 0 and 24 % (iv // 3600) == 0:
        step = iv // 3600
        if full_day:
            return [f"{start_h % step:02d}/{step}:{start_m:02d}:{start_s:02d}"]
        end_h = min(23, start_h + (dur - 1) // 3600)
        sched.notes.append(f"repeat every {step}h for {human_seconds(dur)}: hours {start_h}..{end_h}")
        return [f"{start_h:02d}..{end_h:02d}/{step}:{start_m:02d}:{start_s:02d}"]
    if iv % 60 == 0 and iv < 3600 and 60 % (iv // 60) == 0:
        step = iv // 60
        if full_day:
            return [f"*:{start_m % step:02d}/{step}:{start_s:02d}"]
        end_h = min(23, start_h + (dur - 1) // 3600)
        sched.notes.append(f"repeat every {step}min for {human_seconds(dur)}: approximated as hours "
                           f"{start_h}..{end_h} (whole hours)")
        return [f"{start_h:02d}..{end_h:02d}:{start_m % step:02d}/{step}:{start_s:02d}"]
    # Interval that doesn't divide the hour/day evenly: monotonic timer instead.
    sched.on_unit_active_sec = iv
    sched.on_boot_sec = sched.on_boot_sec or 300
    sched.notes.append(f"repeat every {human_seconds(iv)} -> OnUnitActiveSec (not wall-clock aligned)")
    return []


def parse_triggers(root, sched: Schedule) -> None:
    trigs = find(root, "t:Triggers")
    if trigs is None or len(trigs) == 0:
        sched.skipped.append("no triggers (on-demand task) -> service only, no timer")
        return
    for trig in trigs:
        kind = trig.tag.split("}", 1)[-1]
        if text(trig, "t:Enabled", "true").lower() == "false":
            sched.skipped.append(f"{kind}: disabled on Windows")
            continue
        rd = iso_duration_seconds(text(trig, "t:RandomDelay")) or 0
        sched.randomized_delay = max(sched.randomized_delay, rd)

        if kind == "BootTrigger":
            sched.on_boot_sec = iso_duration_seconds(text(trig, "t:Delay")) or 60
            continue
        if kind == "LogonTrigger":
            sched.skipped.append("LogonTrigger: make it a `systemd --user` unit (WantedBy=default.target) "
                                 "or an XDG autostart entry")
            continue
        if kind == "TimeTrigger":
            rep = repetition_time_specs(0, 0, 0, trig, Schedule())
            if rep is None:
                sched.skipped.append(f"TimeTrigger (one-shot at {text(trig, 't:StartBoundary')}): "
                                     "use `systemd-run --on-calendar` if still needed")
                continue
        if kind not in ("CalendarTrigger", "TimeTrigger"):
            sched.skipped.append(f"{kind}: no systemd timer equivalent (look at path/socket units, udev, "
                                 "or a journal watcher)")
            continue

        sb = text(trig, "t:StartBoundary", "")
        m = re.search(r"T(\d{2}):(\d{2}):(\d{2})", sb)
        h, mi, s = (int(x) for x in m.groups()) if m else (0, 0, 0)
        if re.search(r"(Z|[+-]\d{2}:\d{2})$", sb):
            sched.notes.append(f"StartBoundary {sb} has a UTC offset ('synchronize across time zones'); "
                               "used as local time")
        times = repetition_time_specs(h, mi, s, trig, sched)
        if times == []:
            continue                      # handled as monotonic
        times = times or [f"{h:02d}:{mi:02d}:{s:02d}"]

        days: list[str] = []              # date parts like "Mon,Fri *-*-*"
        if kind == "TimeTrigger":
            days = ["*-*-*"]
        elif find(trig, "t:ScheduleByDay") is not None:
            n = int(text(trig, "t:ScheduleByDay/t:DaysInterval", "1"))
            if n == 1:
                days = ["*-*-*"]
            else:
                days = [f"*-*-01/{n}"]
                sched.notes.append(f"every {n} days -> days 1,{1 + n},… of each month (resets monthly)")
        elif find(trig, "t:ScheduleByWeek") is not None:
            wd = [DAY_ABBR[d] for d in DAYS if d in children(trig, "t:ScheduleByWeek/t:DaysOfWeek")]
            wi = int(text(trig, "t:ScheduleByWeek/t:WeeksInterval", "1"))
            if wi > 1:
                sched.notes.append(f"every {wi} weeks -> every week (systemd can't skip weeks; "
                                   "add a week-parity check in the job if it matters)")
            days = [f"{','.join(wd) or 'Mon'} *-*-*"]
        elif find(trig, "t:ScheduleByMonth") is not None:
            mspec = months_spec(find(trig, "t:ScheduleByMonth"))
            dlist = [d.text.strip() for d in kids(trig, "t:ScheduleByMonth/t:DaysOfMonth")]
            nums = [f"{int(d):02d}" for d in dlist if d.isdigit()]
            if nums:
                days.append(f"*-{mspec}-{','.join(nums)}")
                if any(int(d) > 28 for d in nums):
                    sched.notes.append("day 29-31: skipped in shorter months, as on Windows")
            if any(d.lower() == "last" for d in dlist):
                days.append(f"*-{mspec}~01")
        elif find(trig, "t:ScheduleByMonthDayOfWeek") is not None:
            b = find(trig, "t:ScheduleByMonthDayOfWeek")
            mspec = months_spec(b)
            wd = ",".join(DAY_ABBR[d] for d in DAYS if d in children(b, "t:DaysOfWeek")) or "Mon"
            for w in [x.text.strip() for x in kids(b, "t:Weeks")]:
                if w.isdigit():
                    a = (int(w) - 1) * 7 + 1
                    days.append(f"{wd} *-{mspec}-{a:02d}..{a + 6:02d}")
                elif w.lower() == "last":
                    days.append(f"{wd} *-{mspec}~07/1")
        else:
            sched.skipped.append(f"{kind}: unrecognised schedule block")
            continue
        sched.on_calendar += [f"{d} {t}" for d in days for t in times]


# --------------------------------------------------------------------------- units
UNIT_HEADER = "# Generated by exodus-kit tasks-to-systemd. Review before installing.\n"


def exec_lines(cfg: Config, mapping: dict | None, win_cmds: list[str], unit: str) -> tuple[list[str], bool]:
    if mapping and mapping.get("exec"):
        ex = mapping["exec"]
        return ([f"ExecStart={e}" for e in ex] if isinstance(ex, list) else [f"ExecStart={ex}"]), True
    msg = f"exodus-kit: {unit} is not ported yet - add it to exec_map"
    return [f"ExecStart=/bin/sh -c 'echo \"{msg}\" >&2; exit 1'"], False


def common_unit(cfg: Config, mapping: dict | None) -> list[str]:
    after = list(cfg.after) + list((mapping or {}).get("after", []))
    lines = [f"Wants={' '.join(a for a in after if a.endswith('.target'))}" if any(a.endswith(".target") for a in after) else None,
             f"After={' '.join(after)}" if after else None]
    rmf = (mapping or {}).get("requires_mounts_for")
    if rmf:
        lines.append(f"RequiresMountsFor={' '.join(rmf)}")
    return [l for l in lines if l]


def service_env(mapping: dict | None) -> list[str]:
    env = (mapping or {}).get("environment", {})
    return [f'Environment="{k}={sd_escape(str(v))}"' for k, v in env.items()]


@dataclass
class Result:
    kind: str
    name: str
    unit: str
    ported: bool
    schedule: list = field(default_factory=list)
    notes: list = field(default_factory=list)
    skipped: list = field(default_factory=list)
    windows: list = field(default_factory=list)
    disabled_on_windows: bool = False


def convert_task(cfg: Config, task: dict, out: Path) -> Result | None:
    full = (task.get("path") or "\\") + task["name"]
    if not cfg.wanted(full):
        return None
    xml = re.sub(r"^\s*<\?xml[^>]*\?>", "", task["xml"])
    root = ET.fromstring(xml)
    unit = f"{cfg.prefix}-job-{slug(task['name'])}"
    sched = Schedule()
    parse_triggers(root, sched)

    win_cmds = []
    for a in kids(root, "t:Actions"):
        kind = a.tag.split("}", 1)[-1]
        if kind == "Exec":
            win_cmds.append(" ".join(x for x in (text(a, "t:Command"), text(a, "t:Arguments")) if x))
        else:
            sched.skipped.append(f"action {kind}: not an executable, port by hand")
    mapping = cfg.exec_for(full, task["name"])
    win_wd = text(root, "t:Actions/t:Exec/t:WorkingDirectory")
    wd = (mapping or {}).get("workdir") or cfg.map_path(win_wd)

    uid = text(root, "t:Principals/t:Principal/t:UserId") or text(root, "t:Principals/t:Principal/t:GroupId")
    user, uwarn = cfg.map_user(uid)
    user = (mapping or {}).get("user", user)
    if uwarn and not (mapping or {}).get("user"):
        sched.notes.append(uwarn)

    limit = iso_duration_seconds(text(root, "t:Settings/t:ExecutionTimeLimit", "PT72H"))
    timeout = "infinity" if limit == 0 else human_seconds(limit or 72 * 3600)
    swa = text(root, "t:Settings/t:StartWhenAvailable", "false").lower() == "true"
    enabled = text(root, "t:Settings/t:Enabled", "true").lower() != "false"

    ex, ported = exec_lines(cfg, mapping, win_cmds, unit)
    svc = [UNIT_HEADER, "[Unit]", f"Description={sd_escape('Job: ' + task['name'])} (ported from Task Scheduler)"]
    svc += common_unit(cfg, mapping)
    svc += ["", "[Service]", "Type=oneshot", f"User={user}"]
    svc += [f"WorkingDirectory={wd}"] if wd and not re.match(r"^[A-Za-z]:", wd) else []
    svc += ["Environment=PYTHONUNBUFFERED=1"] + service_env(mapping)
    svc += [f"LoadCredential={c}" for c in (mapping or {}).get("credentials", [])]
    svc += ex + [f"TimeoutStartSec={timeout}", "",
                 "# Windows action(s), for reference:"] + [f"#   {sd_escape(c)}" for c in win_cmds]
    (out / f"{unit}.service").write_text("\n".join(svc) + "\n", encoding="utf-8")

    if sched.on_calendar or sched.on_boot_sec or sched.on_unit_active_sec:
        persistent = cfg.persistent or swa
        tm = [UNIT_HEADER, "[Unit]", f"Description={sd_escape('Schedule: ' + task['name'])}", "", "[Timer]"]
        tm += [f"OnCalendar={c}" for c in sched.on_calendar]
        tm += [f"OnBootSec={human_seconds(sched.on_boot_sec)}"] if sched.on_boot_sec else []
        tm += [f"OnUnitActiveSec={human_seconds(sched.on_unit_active_sec)}"] if sched.on_unit_active_sec else []
        tm += [f"RandomizedDelaySec={human_seconds(sched.randomized_delay)}"] if sched.randomized_delay else []
        tm += [f"Persistent={'true' if persistent and sched.on_calendar else 'false'}", "",
               "[Install]", "WantedBy=timers.target"]
        (out / f"{unit}.timer").write_text("\n".join(tm) + "\n", encoding="utf-8")

    return Result("task", full, unit, ported, sched.on_calendar + (
        [f"OnBootSec={human_seconds(sched.on_boot_sec)}"] if sched.on_boot_sec else []) + (
        [f"OnUnitActiveSec={human_seconds(sched.on_unit_active_sec)}"] if sched.on_unit_active_sec else []),
        sched.notes, sched.skipped, win_cmds, not enabled)


def convert_service(cfg: Config, s: dict, out: Path) -> Result | None:
    if (s.get("startType") or "").lower() not in ("automatic", "auto", "autodelayedstart", "automaticdelayedstart"):
        return None
    if not cfg.wanted("service:" + s["name"]):
        return None
    unit = f"{cfg.prefix}-{slug(s['name'])}"
    nssm = s.get("nssm") or {}
    win_cmd = " ".join(x for x in (nssm.get("application"), nssm.get("parameters")) if x) or s.get("binaryPath", "")
    mapping = cfg.exec_for("service:" + s["name"], s["name"])
    user, uwarn = cfg.map_user(s.get("account") or "SYSTEM")
    user = (mapping or {}).get("user", user)
    notes = [uwarn] if uwarn and not (mapping or {}).get("user") else []
    wd = (mapping or {}).get("workdir") or cfg.map_path(nssm.get("directory"))
    ex, ported = exec_lines(cfg, mapping, [win_cmd], unit)
    lines = [UNIT_HEADER, "[Unit]",
             f"Description={sd_escape(s.get('displayName') or s['name'])} (was Windows service {sd_escape(s['name'])})"]
    lines += common_unit(cfg, mapping)
    lines += ["", "[Service]", f"User={user}"]
    lines += [f"WorkingDirectory={wd}"] if wd and not re.match(r"^[A-Za-z]:", wd) else []
    lines += ["Environment=PYTHONUNBUFFERED=1"] + service_env(mapping)
    lines += [f"LoadCredential={c}" for c in (mapping or {}).get("credentials", [])]
    lines += ex + ["Restart=always", "RestartSec=5",
                   "NoNewPrivileges=yes", "PrivateTmp=yes", "ProtectSystem=full", "",
                   "[Install]", "WantedBy=multi-user.target", "",
                   "# Windows command, for reference:", f"#   {sd_escape(win_cmd)}"]
    (out / f"{unit}.service").write_text("\n".join(lines) + "\n", encoding="utf-8")
    if nssm:
        notes.append("NSSM wrapper detected: command taken from its Parameters key")
    return Result("service", s["name"], unit, ported, [], notes, [], [win_cmd])


# --------------------------------------------------------------------------- validation + report
def validate(results: list[Result]) -> list[str]:
    if not shutil.which("systemd-analyze"):
        return ["systemd-analyze not found: calendar expressions not validated"]
    errs = []
    for r in results:
        for c in r.schedule:
            if not c.startswith("On"):
                p = subprocess.run(["systemd-analyze", "calendar", c], capture_output=True, text=True)
                if p.returncode != 0:
                    errs.append(f"{r.unit}: invalid OnCalendar '{c}': {p.stderr.strip()}")
    return errs


def report(cfg: Config, inv: dict, results: list[Result], out: Path, errors: list[str]) -> None:
    tasks = [r for r in results if r.kind == "task"]
    svcs = [r for r in results if r.kind == "service"]
    todo = [r for r in results if not r.ported]
    L = ["# exodus-kit conversion report", "",
         f"Source: export from {inv.get('exportedAt', '?')} ({inv.get('os', '?')})", "",
         f"- {len(tasks)} scheduled task(s) -> `{cfg.prefix}-job-*.service` + `.timer`",
         f"- {len(svcs)} auto-start service(s) -> `{cfg.prefix}-*.service`",
         f"- **{len(todo)} unit(s) still need a Linux command** (`exec_map`): they fail on purpose until then",
         ""]
    if errors:
        L += ["## ❌ Validation errors", ""] + [f"- {e}" for e in errors] + [""]
    L += ["## Install (disabled) and test", "", "```bash",
          f"sudo cp {out}/{cfg.prefix}-*.service {out}/{cfg.prefix}-*.timer /etc/systemd/system/",
          "sudo systemctl daemon-reload",
          f"sudo systemctl start {cfg.prefix}-job-<name>.service && journalctl -u {cfg.prefix}-job-<name> -e",
          f"systemctl list-timers '{cfg.prefix}-*' --all       # after enabling, at cutover",
          "```", "", "## Units", "",
          "| Unit | Windows | Schedule | Ported | Notes |", "|---|---|---|---|---|"]
    for r in results:
        notes = "; ".join((["disabled on Windows"] if r.disabled_on_windows else [])
                          + r.notes + [f"⚠️ skipped: {s}" for s in r.skipped])
        sched = "<br>".join(f"`{c}`" for c in r.schedule) or ("service" if r.kind == "service" else "—")
        L.append(f"| `{r.unit}` | {r.name.replace('|', '/')} | {sched} | {'✅' if r.ported else '❌ TODO'} | "
                 f"{notes.replace('|', '/')} |")
    fw = inv.get("firewall") or []
    if fw:
        L += ["", "## Firewall (inbound allow rules found on Windows)", "",
              f"Suggested ufw rules, opened only on `{cfg.trusted_interface}`. Review each one:", "", "```bash",
              "sudo ufw default deny incoming"]
        seen = set()
        for r in fw:
            port, proto = str(r.get("localPort") or ""), (r.get("protocol") or "tcp").lower()
            if not port or port.lower() == "any" or (port, proto) in seen:
                continue
            seen.add((port, proto))
            L.append(f"sudo ufw allow in on {cfg.trusted_interface} to any port {port.replace('-', ':')} proto {proto}"
                     f"   # {r.get('name', '')}")
        L += ["```"]
    L += ["", "## Apps", "", f"{len(inv.get('apps') or [])} installed app(s) listed in `apps.csv`. "
          "Fill in the `linux` column (see https://github.com/LucasFormiga/winuxdb); "
          "leave `stays-on-windows` for the ones that won't move.", ""]
    (out / "REPORT.md").write_text("\n".join(L), encoding="utf-8")


def write_apps(inv: dict, out: Path) -> None:
    with (out / "apps.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["name", "version", "publisher", "source", "linux", "how"])
        for a in sorted(inv.get("apps") or [], key=lambda a: (a.get("name") or "").lower()):
            w.writerow([a.get("name"), a.get("version"), a.get("publisher"), a.get("source"), "", ""])


def load_inventory(path: str) -> dict:
    raw = Path(path).read_bytes()
    for enc in ("utf-8-sig", "utf-16"):       # PowerShell 5.1 may write UTF-16
        try:
            return json.loads(raw.decode(enc))
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
    sys.exit(f"{path}: not valid JSON (UTF-8 or UTF-16)")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("inventory")
    ap.add_argument("-c", "--config")
    ap.add_argument("-o", "--out", default="out")
    ap.add_argument("--validate", action="store_true", help="check OnCalendar with systemd-analyze")
    a = ap.parse_args(argv)

    cfg = Config.load(a.config)
    inv = load_inventory(a.inventory)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    results: list[Result] = []
    for t in inv.get("scheduledTasks") or []:
        try:
            r = convert_task(cfg, t, out)
        except ET.ParseError as e:
            print(f"skip task {t.get('name')}: bad XML ({e})", file=sys.stderr)
            continue
        if r:
            results.append(r)
    for s in inv.get("services") or []:
        r = convert_service(cfg, s, out)
        if r:
            results.append(r)
    errors = validate(results) if a.validate else []
    report(cfg, inv, results, out, errors)
    write_apps(inv, out)
    todo = sum(not r.ported for r in results)
    print(f"{len(results)} unit(s) written to {out}/ ({todo} still need exec_map). Read {out}/REPORT.md")
    for e in errors:
        print("ERROR:", e, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
