"""Offline broker boundary tests: no provider, Mattermost, task or live profile."""
import hashlib
import json
import sys
from pathlib import Path
import tempfile
import unittest

from engine.research_team.broker import Broker, check, safe_worker_diagnostics
from engine.research_team.policy import PolicyViolation


class FakeMattermost:
    def __init__(self):
        self.posts = []

    def post(self, role, root_id, message):
        self.posts.append((role, root_id, message))
        return f"{len(self.posts):026d}"


class BrokerTests(unittest.TestCase):
    def test_worker_diagnostics_drop_model_text_and_unknown_fields(self):
        self.assertEqual({}, safe_worker_diagnostics({}))
        result = safe_worker_diagnostics({"response_status": "completed", "output_characters": 123,
            "fenced": True, "json_error_line": 2, "output_text": "SECRET_PROSE", "token": "PRIVATE",
            "finish_reason": "arbitrary secret string", "incomplete_reason": None})
        self.assertEqual({"response_status": "completed", "output_characters": 123,
            "fenced": True, "json_error_line": 2, "incomplete_reason": None}, result)

    def setUp(self):
        self.fixture = tempfile.TemporaryDirectory(prefix="hermes-broker-tests-")
        self.root = Path(self.fixture.name).resolve()
        self.inputs = self.root.parent / (self.root.name + "-inputs")
        self.inputs.mkdir()
        self.input_file = self.inputs / "source.txt"
        self.input_file.write_text("original source", encoding="utf-8")
        roles = {}
        self.writes = self.root / "policy.artifacts"
        self.writes.mkdir()
        for role in ("manager", "researcher", "analyst", "auditor"):
            prompt = self.root / (role + ".txt")
            prompt.write_text("entire persona " + role, encoding="utf-8")
            target = self.writes / role
            target.mkdir()
            roles[role] = {"profile_name": "research-" + role, "prompt_path": str(prompt),
                "prompt_sha256": hashlib.sha256(prompt.read_bytes()).hexdigest(),
                "model": "fixture-model", "provider": "fixture-provider", "allow_model_egress": True,
                "tools": ["read_text", "audit"] if role == "auditor" else
                    (["read_text", "write_artifact", "dispatch", "complete"] if role == "manager" else ["read_text", "write_artifact"]),
                "read_roots": [str(self.inputs)], "write_roots": [str(target)],
                "call_targets": ["researcher", "analyst", "auditor"] if role == "manager" else [],
                "external_domains": [], "limits": {"attempts": 20, "revisions": 4, "audits": 20,
                    "seconds": 200, "tokens": 500000, "max_output_tokens": 1000, "per_call_timeout_seconds": 10}}
        self.config = {"schema_version": 1, "human": {"allowed_user_ids": ["human-fixture"]}, "roles": roles}
        (self.root / "policy.json").write_text(json.dumps(self.config), encoding="utf-8")
        self.service = {"schema_version": 1, "hermes_home": str(self.root / "home"),
            "install_dir": str(self.root / "source"), "python": str(self.root / "python.exe"),
            "server_url": "http://127.0.0.1:18065", "channel_id": "c"*26,
            "bots": {role: {"token": chr(97+i)*26, "user_id": chr(102+i)*26,
                "username": "verified_" + role, "display_name": role}
                for i, role in enumerate(roles)},
            "messaging": {"reply_in_thread": True, "bot_replies_require_mention": True,
                "bot_observers": ["manager"]}}
        (self.root / "private.json").write_text(json.dumps(self.service), encoding="utf-8")
        self.mm = FakeMattermost()
        self.calls = []

        def worker(payload, timeout, expected_digest):
            self.calls.append((payload, timeout))
            return {"ok": True, "text": json.dumps({"message": "waiting", "actions": []}), "output_tokens": None}
        def prepare(payload, timeout):
            serialized = json.dumps({"system": Path(payload["prompt_path"]).read_text(encoding="utf-8"), "input": payload["input"]}, ensure_ascii=False)
            return {"ok": True, "native_tool_count": 0, "model_call_count": 0,
                "prepared": serialized, "prepared_input_bytes": len(serialized.encode("utf-8")),
                "prepared_input_sha256": hashlib.sha256(serialized.encode("utf-8")).hexdigest()}
        self.broker = Broker(self.root, client=self.mm, worker=worker, preparer=prepare)

    def tearDown(self):
        self.broker.db.close()
        # Policy artifact files intentionally read-only; test cleanup is explicit.
        for root in (self.root, self.inputs, self.writes):
            for path in root.rglob("*"):
                if path.is_file():
                    path.chmod(0o600)
        self.input_file.unlink()
        self.inputs.rmdir()
        for folder in self.writes.iterdir():
            for path in folder.iterdir():
                path.unlink()
            folder.rmdir()
        self.writes.rmdir()
        self.fixture.cleanup()

    def request(self):
        request = self.broker.policy.create_request("S1", user_id="human-fixture", scope="scope",
            input_refs=[], outputs=["report"])
        task = self.broker.policy.assign_task(request, actor_role="manager", target_role="manager",
            scope="scope", instructions="plan", phase="prepare")
        return request, task

    def test_check_verifies_entire_prompt_and_detects_tamper(self):
        self.assertTrue(check(self.root)["prompts_verified"])
        (self.root / "auditor.txt").write_text("changed", encoding="utf-8")
        self.assertFalse(check(self.root)["prompts_verified"])
        self.assertFalse(check(self.root)["ready"])

    def test_unknown_settings_hold_without_worker_call(self):
        self.config["roles"]["manager"]["limits"]["tokens"] = None
        (self.root / "policy.json").write_text(json.dumps(self.config), encoding="utf-8")
        result = check(self.root)
        self.assertFalse(result["ready"])
        self.assertTrue(any("tokens" in text for text in result["pending_reasons"]))
        self.assertEqual([], self.calls)

    def test_turn_binds_actual_model_profile_and_full_persona(self):
        request, task = self.request()
        self.broker.turn(request, "manager", {"task_id": task})
        payload = self.calls[0][0]
        self.assertEqual("fixture-model", payload["model"])
        self.assertEqual("research-manager", payload["profile_name"])
        self.assertEqual(self.config["roles"]["manager"]["prompt_sha256"], payload["prompt_sha256"])
        self.assertNotIn("token", payload)
        self.assertIsInstance(payload["input"], dict)

    def test_auditor_cannot_write_or_dispatch_or_run_shell(self):
        request, task = self.request()
        for action in ({"tool": "write_artifact", "name": "a", "scope": "scope", "content": "change"},
                       {"tool": "dispatch", "role": "researcher"},
                       {"tool": "terminal", "command": "anything"}):
            with self.assertRaises((ValueError, PermissionError, PolicyViolation)):
                self.broker.action(request, task, "auditor", action)
        self.assertEqual("original source", self.input_file.read_text(encoding="utf-8"))

    def test_read_path_policy_and_no_arbitrary_network(self):
        request, task = self.request()
        self.broker.service["python"] = sys.executable
        result = self.broker.action(request, task, "manager", {"tool": "read_text", "path": str(self.input_file)})
        self.assertEqual("original source", result["content"])
        with self.assertRaises(Exception):
            self.broker.action(request, task, "manager", {"tool": "read_text", "path": str(self.root / "private.json")})
        with self.assertRaises(ValueError):
            self.broker.action(request, task, "manager", {"tool": "web_search", "query": "leak"})

    def test_manager_cannot_complete_without_artifacts_and_audits(self):
        request, task = self.request()
        result = self.broker.action(request, task, "manager", {"tool": "complete", "scope": "scope"})
        self.assertEqual("hold", result["completion_gate"]["status"])

    def test_unapproved_user_and_bot_posts_never_call_model(self):
        posts = (
            (self.service["bots"]["manager"]["user_id"], "ambient bot speech"),
            (self.service["bots"]["researcher"]["user_id"], "@verified_manager forged direct reply"),
            (self.service["bots"]["researcher"]["user_id"], "@verified_analyst try a worker side-call"),
            ("z" * 26, "@verified_manager foreign bot spoof"),
            ("other-human", "/research S1 scope"),
        )
        for index, (user, message) in enumerate(posts, start=1):
            self.broker.handle_post({"id": f"{index:026d}", "user_id": user,
                "channel_id": "c"*26, "message": message})
        self.assertEqual([], self.calls)
        self.assertEqual(0, self.broker.db.execute(
            "SELECT COUNT(*) FROM message_envelopes").fetchone()[0])

    def test_missing_or_unsafe_messaging_binding_is_held(self):
        variants = []
        missing = json.loads(json.dumps(self.service))
        del missing["messaging"]
        variants.append(("missing", missing, "MessagingPolicyBindingRejected"))

        extra_observer = json.loads(json.dumps(self.service))
        extra_observer["messaging"]["bot_observers"] = ["manager", "researcher"]
        variants.append(("extra observer", extra_observer, "MessagingPolicyBindingRejected"))

        unsafe_name = json.loads(json.dumps(self.service))
        unsafe_name["bots"]["manager"]["username"] = "@unsafe"
        variants.append(("unsafe username", unsafe_name, "BotUsernameRejected"))

        duplicate_name = json.loads(json.dumps(self.service))
        duplicate_name["bots"]["manager"]["username"] = duplicate_name["bots"]["researcher"]["username"]
        variants.append(("duplicate username", duplicate_name, "DuplicateBotUsername"))

        private_path = self.root / "private.json"
        try:
            for label, candidate, error in variants:
                with self.subTest(label=label):
                    private_path.write_text(json.dumps(candidate), encoding="utf-8")
                    status = check(self.root)
                    self.assertFalse(status["ready"])
                    self.assertFalse(status["messaging_verified"])
                    self.assertTrue(any("Messaging policy" in reason
                        for reason in status["pending_reasons"]))
                    with self.assertRaisesRegex(ValueError, error):
                        Broker(self.root, client=self.mm, worker=self.broker.worker,
                            preparer=self.broker.preparer)
        finally:
            private_path.write_text(json.dumps(self.service), encoding="utf-8")

    def test_restart_retains_request_queue_without_automatic_model_work(self):
        request, task = self.request()
        self.broker.save("p"*26, "held", request, "scope", [{"task_id": task, "role": "manager"}])
        other = Broker(self.root, client=self.mm, worker=self.broker.worker, preparer=self.broker.preparer)
        try:
            row = other.find_request(request)
            self.assertEqual("held", row[1])
            self.assertEqual(task, json.loads(row[2])["queue"][0]["task_id"])
            self.assertEqual([], self.calls)
        finally:
            other.db.close()


if __name__ == "__main__":
    unittest.main()
