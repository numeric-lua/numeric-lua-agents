#!/usr/bin/env python3
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("scheduler", ROOT / "scheduler.py")
scheduler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scheduler)


class RotationTests(unittest.TestCase):
    def test_rotation_is_fourteen_slots_and_half_luar(self):
        self.assertEqual(len(scheduler.ROTATION), 14)
        self.assertEqual(scheduler.ROTATION.count("luar"), 7)
        self.assertEqual(set(scheduler.ROTATION), set(["luar"] + scheduler.PROJECTS))

    def test_window_weekday_and_weekend(self):
        tz = scheduler.TZ
        self.assertTrue(scheduler.is_open(datetime(2026, 11, 23, 7, 0, tzinfo=tz)))
        self.assertTrue(scheduler.is_open(datetime(2026, 11, 23, 21, 59, tzinfo=tz)))
        self.assertFalse(scheduler.is_open(datetime(2026, 11, 23, 22, 0, tzinfo=tz)))
        self.assertTrue(scheduler.is_open(datetime(2026, 11, 22, 23, 0, tzinfo=tz)))
        self.assertFalse(scheduler.is_open(datetime(2026, 11, 23, 0, 0, tzinfo=tz)))

    def test_monday_midnight_waits_for_seven(self):
        tz = scheduler.TZ
        monday = datetime(2026, 11, 23, 0, 0, tzinfo=tz)
        nxt = scheduler.next_open(monday)
        self.assertEqual(nxt.weekday(), 0)
        self.assertEqual(nxt.hour, 7)

    def test_friday_close_opens_saturday_midnight(self):
        tz = scheduler.TZ
        friday = datetime(2026, 11, 27, 22, 0, tzinfo=tz)
        self.assertEqual(scheduler.next_open(friday).weekday(), 5)
        self.assertEqual(scheduler.next_open(friday).hour, 0)


class CleanupTests(unittest.TestCase):
    def test_cleanup_clears_non_dsh_active_pid(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            state_path = tmp / "state.json"
            log_path = tmp / "service.log"
            state = {"active": {"pid": os.getpid(), "project": "x"}, "slot": 3}
            state_path.write_text(json.dumps(state))
            paths = {"state": state_path, "log": log_path}
            scheduler.cleanup_orphan(paths, state, 1)
            saved = json.loads(state_path.read_text())
            self.assertNotIn("active", saved)
            self.assertEqual(saved["slot"], 3)


class QuotaResetTests(unittest.TestCase):
    def test_just_after_midnight_resets_today(self):
        tz = scheduler.TZ
        now = datetime(2026, 11, 25, 0, 3, tzinfo=tz)
        self.assertEqual(scheduler.next_quota_reset(now),
                         datetime(2026, 11, 25, 0, 5, tzinfo=tz))

    def test_after_the_boundary_resets_tomorrow(self):
        tz = scheduler.TZ
        now = datetime(2026, 11, 25, 0, 6, tzinfo=tz)
        self.assertEqual(scheduler.next_quota_reset(now),
                         datetime(2026, 11, 26, 0, 5, tzinfo=tz))

    def test_at_the_boundary_resets_tomorrow(self):
        tz = scheduler.TZ
        now = datetime(2026, 11, 25, 0, 5, tzinfo=tz)
        self.assertEqual(scheduler.next_quota_reset(now),
                         datetime(2026, 11, 26, 0, 5, tzinfo=tz))


class OnceTests(unittest.TestCase):
    def test_once_invokes_one_fake_worker_and_records_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            repo = tmp / "luar"
            (repo / ".git").mkdir(parents=True)
            fake = tmp / "fake-dsh"
            invocation = tmp / "invocation.txt"
            fake.write_text(
                "#!/bin/sh\ncat > " + str(invocation) + "\n"
                "echo fake-dsh-ok\n")
            fake.chmod(0o755)
            config = tmp / "config.json"
            config.write_text(json.dumps({
                "dsh": str(fake),
                "profile": "headless",
                "projects": {"luar": str(repo)},
                "contribution_guard": False,
            }))
            env = os.environ.copy()
            env["NUMERIC_LUA_SERVICE_STATE"] = str(tmp / "state")
            env["NUMERIC_LUA_SERVICE_CONFIG"] = str(config)
            agents = tmp / "agents.json"
            agents.write_text(json.dumps({"luar": "session-11111111-1111-1111-1111-111111111111"}))
            env["NUMERIC_LUA_SERVICE_AGENTS"] = str(agents)
            result = subprocess.run(
                [sys.executable, str(ROOT / "scheduler.py"), "--once", "--ignore-window"],
                env=env, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            prompt = invocation.read_text()
            self.assertIn("FIVE", prompt)
            self.assertIn("Do not create tags or GitHub releases", prompt)
            self.assertNotIn("cut a release", prompt)
            state = json.loads((tmp / "state" / "state.json").read_text())
            self.assertEqual(state["runs"], 1)
            self.assertEqual(state["counts"], {"luar": 1})
            self.assertEqual(state["slot"], 1)
            self.assertEqual(len(state["history"]), 1)


class PromptTests(unittest.TestCase):
    def test_every_project_prompt_forbids_releases_and_requires_tests(self):
        for project in scheduler.PROMPTS:
            prompt = scheduler.build_prompt(project)
            self.assertIn("Do not create tags or GitHub releases", prompt)
            self.assertNotIn("cut a release", prompt)
            self.assertIn("push only after the repository's tests pass", prompt)


class ContributionGuardTests(unittest.TestCase):
    """The quota is an absolute count, independent of GitHub's relative level."""

    def setUp(self):
        self._original = scheduler.contribution_status

    def tearDown(self):
        scheduler.contribution_status = self._original

    def test_count_at_quota_stops_even_at_lower_level(self):
        scheduler.contribution_status = lambda: (100, "SECOND_QUARTILE")
        self.assertTrue(scheduler.contribution_reached({"contribution_min": 100}))

    def test_count_above_quota_stops_at_any_level(self):
        scheduler.contribution_status = lambda: (150, "FIRST_QUARTILE")
        self.assertTrue(scheduler.contribution_reached({"contribution_min": 100}))

    def test_count_below_quota_keeps_work_even_at_top_level(self):
        scheduler.contribution_status = lambda: (99, "FOURTH_QUARTILE")
        self.assertFalse(scheduler.contribution_reached({"contribution_min": 100}))

    def test_unavailable_status_does_not_stop_work(self):
        scheduler.contribution_status = lambda: None
        self.assertFalse(scheduler.contribution_reached({"contribution_min": 100}))

    def test_guard_can_be_disabled(self):
        scheduler.contribution_status = lambda: (1000, "FOURTH_QUARTILE")
        self.assertFalse(scheduler.contribution_reached({
            "contribution_min": 100,
            "contribution_guard": False,
        }))

    def test_status_can_be_reused_without_another_query(self):
        calls = []
        scheduler.contribution_status = lambda: calls.append(True)
        self.assertTrue(scheduler.contribution_reached(
            {"contribution_min": 100}, (100, "SECOND_QUARTILE")))
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
