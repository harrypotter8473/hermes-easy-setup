"""Mocked native gateway identity/roster cutover checks; no live imports or IPC."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

from engine.research_team.native_cutover import detach


class NativeCutoverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="hermes-cutover-tests-")
        self.root = Path(self.temporary.name)
        self.source, self.home = self.root / "source", self.root / "home"
        self.source.mkdir()
        self.names = ["research-lead", "research-scout", "research-worker", "research-reviewer"]
        for name in self.names:
            (self.home / "profiles" / name).mkdir(parents=True)
        self.runtime, self.pids, self.probes, self.unserved = {}, {}, [], []
        status = types.ModuleType("gateway.status")
        status.read_runtime_status = lambda path: self.runtime.get(path.parent)
        status.get_runtime_status_running_pid = lambda runtime, expected_home: runtime.get("verified_pid")

        def get_pid(path, *, cleanup_stale):
            self.probes.append((path.parent, cleanup_stale))
            return self.pids.get(path.parent)

        status.get_running_pid = get_pid
        control = types.ModuleType("gateway.control_socket")

        def unserve(home, name):
            self.unserved.append((home, name))
            self.runtime[home]["served_profiles"] = [item for item in self.runtime[home]["served_profiles"] if item != name]
            return {"unserved": name, "served_profiles": self.runtime[home]["served_profiles"]}

        control.request_unserve_profile = unserve
        gateway = types.ModuleType("gateway")
        gateway.__path__ = []
        self.modules = {"gateway": gateway, "gateway.status": status, "gateway.control_socket": control}

    def tearDown(self):
        self.temporary.cleanup()

    def run_cutover(self, timeout=0):
        previous_path = list(sys.path)
        try:
            with patch.dict(sys.modules, self.modules), patch.dict(os.environ), patch("time.sleep"):
                return detach(self.source, self.home, self.names, timeout=timeout)
        finally:
            sys.path[:] = previous_path

    def test_missing_or_invalid_live_root_roster_is_not_detached(self):
        self.pids[self.home] = 100
        for runtime in (None, {}, {"verified_pid": 100},
                        {"verified_pid": 100, "served_profiles": "research-lead"},
                        {"verified_pid": 100, "served_profiles": ["default", "default"]}):
            with self.subTest(runtime=runtime):
                self.runtime[self.home] = runtime
                result = self.run_cutover()
                self.assertFalse(result["detached"])
                self.assertEqual("ExistingGatewayRoutingUnverified", result["reason"])
                self.assertFalse(self.unserved)
        self.assertTrue(self.probes)
        self.assertTrue(all(cleanup is False for _, cleanup in self.probes))

    def test_current_modern_roster_detaches_only_four_selected_profiles(self):
        self.pids[self.home] = 100
        self.runtime[self.home] = {"verified_pid": 100, "served_profiles": ["default", "personal"] + self.names}
        result = self.run_cutover(timeout=1)
        self.assertTrue(result["detached"])
        self.assertEqual([(self.home, name) for name in self.names], self.unserved)
        self.assertEqual(["default", "personal"], self.runtime[self.home]["served_profiles"])
        self.assertEqual(100, self.pids[self.home], "Personal host is never stopped")

    def test_current_root_without_research_profiles_is_already_detached(self):
        self.pids[self.home] = 100
        self.runtime[self.home] = {"verified_pid": 100, "served_profiles": ["default"]}
        self.assertTrue(self.run_cutover()["detached"])
        self.assertEqual([], self.unserved)

    def test_pid_and_status_identity_mismatch_is_held(self):
        self.pids[self.home] = 100
        self.runtime[self.home] = {"verified_pid": 101, "served_profiles": []}
        self.assertEqual("ExistingGatewayRoutingUnverified", self.run_cutover()["reason"])

    def test_live_selected_standalone_is_held_without_personal_stop(self):
        self.pids[self.home / "profiles" / self.names[0]] = 200
        result = self.run_cutover()
        self.assertFalse(result["detached"])
        self.assertEqual("ExistingResearchGatewayStillRunning", result["reason"])
        self.assertEqual([self.names[0]], result["profiles"])
        self.assertFalse(self.unserved)

    def test_stale_roster_with_no_verified_live_pid_does_not_claim_live_owner(self):
        self.runtime[self.home] = {"served_profiles": self.names, "pid": 123}
        self.assertTrue(self.run_cutover()["detached"])
        self.assertFalse(self.unserved)

    def test_legacy_host_without_per_profile_control_is_held(self):
        self.pids[self.home] = 100
        self.runtime[self.home] = {"verified_pid": 100, "served_profiles": ["default"] + self.names}
        del self.modules["gateway.control_socket"].request_unserve_profile
        self.assertFalse(self.run_cutover()["detached"])
        self.assertFalse(self.unserved)

    def test_arbitrary_or_duplicate_profile_set_is_rejected(self):
        for names in (self.names[:3], self.names[:3] + ["default"], [self.names[0]] * 4):
            with self.assertRaisesRegex(ValueError, "ResearchProfileSetRejected"):
                detach(self.source, self.home, names, timeout=0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
