"""Offline integration tests for the broker-to-policy research workflow."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from engine.research_team.broker import Broker
from engine.research_team.policy import PolicyHold


class _OfflineMattermost:
    def __init__(self) -> None:
        self.posts: list[tuple[str, str, str]] = []

    def post(self, role: str, root_id: str, message: str) -> None:
        self.posts.append((role, root_id, message))
        return f"{len(self.posts):026d}"


class ResearchFlowTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="hermes-research-flow-")
        self.root = Path(self.temporary.name).resolve()
        self.inputs = self.root.parent / f"{self.root.name}-inputs"
        self.inputs.mkdir()
        (self.inputs / "source.txt").write_text("source", encoding="utf-8")
        artifact_root = self.root / "policy.artifacts"

        tools = {
            "manager": ["read_text", "write_artifact", "dispatch", "complete"],
            "researcher": ["read_text", "write_artifact", "complete"],
            "analyst": ["read_text", "write_artifact", "complete"],
            "auditor": ["read_text", "audit", "complete"],
        }
        roles = {}
        for role in ("manager", "researcher", "analyst", "auditor"):
            prompt = self.root / f"{role}.txt"
            prompt.write_text(f"fixed {role} persona", encoding="utf-8")
            roles[role] = {
                "profile_name": f"research-{role}",
                "prompt_path": str(prompt),
                "prompt_sha256": hashlib.sha256(prompt.read_bytes()).hexdigest(),
                "model": "offline-fixture-model",
                "provider": "offline-fixture-provider",
                "allow_model_egress": True,
                "tools": tools[role],
                "read_roots": [str(self.inputs)],
                "write_roots": [str(artifact_root / role)],
                "call_targets": (
                    ["researcher", "analyst", "auditor"] if role == "manager" else []
                ),
                "external_domains": [],
                "limits": {
                    "attempts": 20,
                    "revisions": 5,
                    "audits": 20,
                    "seconds": 200,
                    "tokens": 500_000,
                    "max_output_tokens": 100,
                    "per_call_timeout_seconds": 10,
                },
            }
        policy = {
            "schema_version": 1,
            "human": {"allowed_user_ids": ["human-fixture"]},
            "roles": roles,
        }
        (self.root / "policy.json").write_text(
            json.dumps(policy, ensure_ascii=False), encoding="utf-8"
        )
        service = {
            "schema_version": 1,
            "hermes_home": str(self.root / "home"),
            "install_dir": str(self.root / "source"),
            "python": str(self.root / "python.exe"),
            "server_url": "http://127.0.0.1:18065",
            "channel_id": "c" * 26,
            "bots": {
                role: {
                    "token": chr(97 + index) * 26,
                    "user_id": chr(102 + index) * 26,
                    "username": f"verified_{role}",
                    "display_name": role,
                }
                for index, role in enumerate(roles)
            },
            "messaging": {
                "reply_in_thread": True,
                "bot_replies_require_mention": True,
                "bot_observers": ["manager"],
            },
        }
        (self.root / "private.json").write_text(
            json.dumps(service, ensure_ascii=False), encoding="utf-8"
        )
        self.client = _OfflineMattermost()
        self.worker_calls = 0

        def waiting_worker(_payload, _timeout, _expected_digest):
            self.worker_calls += 1
            return {
                "ok": True,
                "native_tool_count": 0,
                "text": json.dumps({"message": "waiting", "actions": []}),
            }

        def prepare(payload, _timeout):
            serialized = json.dumps(
                {
                    "system": Path(payload["prompt_path"]).read_text(encoding="utf-8"),
                    "input": payload["input"],
                },
                ensure_ascii=False,
                sort_keys=True,
            )
            encoded = serialized.encode("utf-8")
            return {
                "ok": True,
                "prepared": serialized,
                "prepared_input_sha256": hashlib.sha256(encoded).hexdigest(),
                "prepared_input_bytes": len(encoded),
                "native_tool_count": 0,
                "model_call_count": 0,
            }

        self.broker = Broker(
            self.root,
            client=self.client,
            worker=waiting_worker,
            preparer=prepare,
        )

    def tearDown(self) -> None:
        self.broker.db.close()
        for path in self.root.rglob("*"):
            if path.is_file():
                path.chmod(0o600)
        for path in self.inputs.iterdir():
            path.unlink()
        self.inputs.rmdir()
        self.temporary.cleanup()

    def new_request(self) -> tuple[str, str]:
        request_id = self.broker.policy.create_request(
            "S1",
            user_id="human-fixture",
            scope="flow-scope",
            input_refs=[],
            outputs=["report"],
        )
        manager_task = self.broker.policy.assign_task(
            request_id,
            actor_role="manager",
            target_role="manager",
            scope="flow-scope",
            instructions="Orchestrate the governed workflow.",
            phase="prepare",
        )
        return request_id, manager_task

    def dispatch(
        self,
        request_id: str,
        manager_task: str,
        role: str,
        *,
        dependencies=(),
        phase: str = "main",
        audit_stage: str | None = None,
    ) -> str:
        result = self.broker.action(
            request_id,
            manager_task,
            "manager",
            {
                "tool": "dispatch",
                "role": role,
                "scope": "flow-scope",
                "instructions": f"Perform the governed {role} step.",
                "phase": phase,
                "dependencies": list(dependencies),
                "audit_stage": audit_stage,
            },
        )
        return result["dispatch"]["task_id"]

    def write(self, request_id: str, task_id: str, role: str, name: str, content: str):
        return self.broker.action(
            request_id,
            task_id,
            role,
            {
                "tool": "write_artifact",
                "name": name,
                "scope": "flow-scope",
                "content": content,
            },
        )["artifact_ref"]

    def audit(
        self,
        request_id: str,
        manager_task: str,
        artifact_ref,
        stage: str = "intermediate",
    ) -> None:
        task_id = self.dispatch(
            request_id,
            manager_task,
            "auditor",
            dependencies=[artifact_ref],
            phase="audit",
            audit_stage=stage,
        )
        self.broker.action(
            request_id,
            task_id,
            "auditor",
            {
                "tool": "audit",
                "artifact_ref": artifact_ref,
                "stage": stage,
                "scope": "flow-scope",
                "verdict": "pass",
                "notes": f"offline {stage} verification",
            },
        )

    def build_analysis(self):
        request_id, manager_task = self.new_request()
        research_task = self.dispatch(request_id, manager_task, "researcher")
        research = self.write(
            request_id, research_task, "researcher", "evidence", "research version one"
        )
        self.audit(request_id, manager_task, research)
        analyst_task = self.dispatch(
            request_id, manager_task, "analyst", dependencies=[research]
        )
        analysis = self.write(
            request_id, analyst_task, "analyst", "analysis", "analysis version one"
        )
        return request_id, manager_task, research_task, research, analysis

    def test_intermediate_audit_blocks_then_allows_analyst_dispatch(self) -> None:
        request_id, manager_task = self.new_request()
        research_task = self.dispatch(request_id, manager_task, "researcher")
        research = self.write(
            request_id, research_task, "researcher", "evidence", "research evidence"
        )

        with self.assertRaises(PolicyHold):
            self.dispatch(request_id, manager_task, "analyst", dependencies=[research])

        self.audit(request_id, manager_task, research)
        analyst_task = self.dispatch(
            request_id, manager_task, "analyst", dependencies=[research]
        )
        self.assertEqual(
            b"research evidence",
            self.broker.policy.read_artifact(
                request_id,
                analyst_task,
                role="analyst",
                artifact_ref=research,
            ),
        )
        self.assertEqual(0, self.worker_calls)

    def test_research_revision_invalidates_audits_and_downstream_chain(self) -> None:
        request_id, manager_task, research_task, research_v1, analysis = (
            self.build_analysis()
        )
        self.audit(request_id, manager_task, analysis)
        integration_task = self.dispatch(
            request_id,
            manager_task,
            "manager",
            dependencies=[research_v1, analysis],
            phase="prepare",
        )
        self.write(
            request_id,
            integration_task,
            "manager",
            "report",
            "integrated version one",
        )

        research_v2 = self.write(
            request_id, research_task, "researcher", "evidence", "research version two"
        )
        self.assertEqual(2, research_v2["version"])
        intermediate = self.broker.policy.gate(
            request_id, stage="intermediate", scope="flow-scope"
        )
        self.assertEqual("hold", intermediate.status)
        self.assertTrue(
            any("researcher:evidence:v2" in reason for reason in intermediate.reasons)
        )
        final = self.broker.policy.gate(request_id, stage="final", scope="flow-scope")
        self.assertEqual("hold", final.status)
        self.assertTrue(any("dependency version changed" in reason for reason in final.reasons))
        self.assertIn("missing current manager integration output", final.reasons)

        with self.assertRaises(PolicyHold):
            self.dispatch(
                request_id, manager_task, "analyst", dependencies=[research_v1]
            )
        self.assertEqual(0, self.worker_calls)

    def test_worker_error_consumes_reserved_worst_case_budget(self) -> None:
        request_id, manager_task = self.new_request()

        def failing_worker(_payload, _timeout, _expected_digest):
            raise RuntimeError("offline failure")

        self.broker.worker = failing_worker
        with self.assertRaises(RuntimeError):
            self.broker.turn(request_id, "manager", {"task_id": manager_task})
        budget = self.broker.policy.get_budget(request_id, "manager")
        self.assertEqual(2, budget["used"]["attempts"])
        self.assertEqual(0, budget["reserved"]["attempts"])
        self.assertGreaterEqual(budget["used"]["tokens"], 100)

    def test_root_nested_and_resume_replies_keep_the_original_thread(self) -> None:
        def submit(post_id: str, scope: str, root_id: str | None = None) -> None:
            post = {
                "id": post_id,
                "user_id": "human-fixture",
                "channel_id": "c" * 26,
                "message": "/research " + json.dumps({
                    "scenario": "S1",
                    "scope": scope,
                    "input_refs": [],
                    "outputs": ["report"],
                }),
            }
            if root_id is not None:
                post["root_id"] = root_id
            self.broker.handle_post(post)

        root_post = "p" * 26
        before = len(self.client.posts)
        submit(root_post, "root request")
        root_replies = self.client.posts[before:]
        self.assertGreaterEqual(len(root_replies), 2)
        self.assertEqual({root_post}, {root for _, root, _ in root_replies})
        root_row = self.broker.db.execute(
            "SELECT state,payload FROM posts WHERE id=?", (root_post,)
        ).fetchone()
        self.assertEqual("held", root_row[0])
        root_request = json.loads(root_row[1])["request_id"]

        nested_post = "q" * 26
        nested_root = "r" * 26
        before = len(self.client.posts)
        submit(nested_post, "nested request", nested_root)
        nested_replies = self.client.posts[before:]
        self.assertGreaterEqual(len(nested_replies), 2)
        self.assertEqual({nested_root}, {root for _, root, _ in nested_replies})

        # Resuming from an unrelated command thread cannot move the saved
        # request; all model/status output remains under its original root.
        before = len(self.client.posts)
        self.broker.handle_post({
            "id": "s" * 26,
            "root_id": "t" * 26,
            "user_id": "human-fixture",
            "channel_id": "c" * 26,
            "message": f"/research-resume {root_request}",
        })
        resumed_replies = self.client.posts[before:]
        self.assertGreaterEqual(len(resumed_replies), 2)
        self.assertEqual({root_post}, {root for _, root, _ in resumed_replies})
        self.assertEqual(3, self.worker_calls)

    def test_manager_worker_round_trip_binds_mentions_envelopes_and_observation(self) -> None:
        captured = []
        manager_turn = 0
        researcher_turn = 0

        def routed_worker(payload, _timeout, _expected_digest):
            nonlocal manager_turn, researcher_turn
            captured.append(payload)
            role = payload["role"]
            actions = []
            if role == "manager":
                manager_turn += 1
                if manager_turn == 1:
                    actions = [{
                        "tool": "dispatch",
                        "role": "researcher",
                        "scope": "flow-scope",
                        "instructions": "Collect evidence.",
                        "phase": "main",
                        "dependencies": [],
                    }]
                elif manager_turn == 2:
                    actions = [{
                        "tool": "dispatch",
                        "role": "researcher",
                        "scope": "flow-scope",
                        "instructions": "Collect an independent second result.",
                        "phase": "main",
                        "dependencies": [],
                    }]
            else:
                researcher_turn += 1
            message = {
                ("manager", 1): "dispatch one @verified_auditor",
                ("manager", 2): "dispatch two @verified_researcher",
                ("manager", 3): "manager received both results",
                ("researcher", 1): "research result one @verified_analyst",
                ("researcher", 2): "research result two @verified_analyst",
            }[(role, manager_turn if role == "manager" else researcher_turn)]
            return {
                "ok": True,
                "native_tool_count": 0,
                "text": json.dumps({"message": message, "actions": actions}),
            }

        self.broker.worker = routed_worker
        post_id = "v" * 26
        thread_root = "w" * 26
        self.broker.handle_post({
            "id": post_id,
            "root_id": thread_root,
            "user_id": "human-fixture",
            "channel_id": "c" * 26,
            "message": "/research " + json.dumps({
                "scenario": "S1",
                "scope": "flow-scope",
                "input_refs": [],
                "outputs": ["report"],
            }),
        })

        self.assertEqual(
            ["manager", "researcher", "manager", "researcher", "manager"],
            [payload["role"] for payload in captured],
            self.client.posts,
        )
        self.assertTrue(self.client.posts)
        self.assertEqual({thread_root}, {root for _, root, _ in self.client.posts})

        researcher_context = captured[1]["input"]["context"]
        second_researcher_context = captured[3]["input"]["context"]
        second_manager = captured[2]["input"]["context"]
        third_manager = captured[4]["input"]["context"]
        self.assertEqual("researcher", second_manager["task"]["worker_result"]["role"])
        self.assertEqual("researcher", third_manager["task"]["worker_result"]["role"])
        self.assertNotIn("_delivery_envelope_id", researcher_context["task"])
        self.assertNotIn("return_task", researcher_context["task"])
        self.assertEqual(
            [("manager", "researcher", "task")],
            [(item["source_role"], item["target_role"], item["kind"])
             for item in researcher_context["verified_messages"]],
        )
        self.assertEqual(
            [("manager", "researcher", "task")],
            [(item["source_role"], item["target_role"], item["kind"])
             for item in second_researcher_context["verified_messages"]],
        )
        # The second worker sees only its manager assignment. A prior worker result
        # becomes observable only to the later manager turn.
        self.assertFalse(any(item["source_role"] == "researcher"
            for item in second_researcher_context["verified_messages"]))
        self.assertEqual(
            [("researcher", "manager", "bot_result")],
            [(item["source_role"], item["target_role"], item["kind"])
             for item in third_manager["verified_messages"]],
        )

        columns = [item[1] for item in self.broker.db.execute(
            "PRAGMA table_info(message_envelopes)")]
        envelopes = [dict(zip(columns, row)) for row in self.broker.db.execute(
            "SELECT * FROM message_envelopes ORDER BY created_at,id")]
        task_envelopes = [item for item in envelopes if item["kind"] == "task"]
        result_envelopes = [item for item in envelopes if item["kind"] == "bot_result"]
        self.assertEqual(2, len(task_envelopes))
        self.assertEqual(2, len(result_envelopes))
        self.assertTrue(all(item["state"] == "delivered" and
            item["thread_root_id"] == thread_root for item in envelopes))
        self.assertTrue(all((item["source_role"], item["target_role"],
            item["message"].split()[0]) ==
            ("manager", "researcher", "@verified_researcher")
            for item in task_envelopes))
        self.assertTrue(all((item["source_role"], item["target_role"],
            item["message"].split()[0]) ==
            ("researcher", "manager", "@verified_manager")
            for item in result_envelopes))
        # Model-authored @text is neutralized; the only real bot mentions are
        # broker-owned task/result envelopes bound above.
        status_messages = [item["message"] for item in envelopes
            if item["kind"] == "bot_status"]
        self.assertTrue(any("＠verified_auditor" in message for message in status_messages))
        self.assertTrue(all("@verified_" not in message for message in status_messages))

    def test_mixed_complete_cannot_write_and_interrupted_turn_is_not_replayed(self) -> None:
        request_id, manager_task = self.new_request()

        def mixed_completion_worker(_payload, _timeout, _expected_digest):
            self.worker_calls += 1
            return {
                "ok": True,
                "native_tool_count": 0,
                "text": json.dumps(
                    {
                        "message": "attempt mixed completion",
                        "actions": [
                            {"tool": "complete", "scope": "flow-scope"},
                            {
                                "tool": "write_artifact",
                                "name": "report",
                                "scope": "flow-scope",
                                "content": "must never be written",
                            },
                        ],
                    }
                ),
            }

        self.broker.worker = mixed_completion_worker
        post_id = "p" * 26
        queue = [
            {
                "task_id": manager_task,
                "role": "manager",
                "scope": "flow-scope",
                "instructions": "Orchestrate the governed workflow.",
                "phase": "prepare",
            }
        ]
        self.broker.save(post_id, "running", request_id, "flow-scope", queue)
        queue[0]["_delivery_envelope_id"] = self.broker._record_human_source(
            {
                "id": post_id,
                "user_id": "human-fixture",
                "message": "/research fixture",
            },
            request_id,
            manager_task,
            post_id,
        )
        with self.assertRaisesRegex(ValueError, "CompleteMustBeTheOnlyAction"):
            self.broker.execute(post_id, request_id, "flow-scope", queue)
        self.assertEqual([], self.broker.policy.list_artifacts(request_id))
        self.assertEqual("running", self.broker.find_request(request_id)[1])

        restarted = Broker(
            self.root,
            client=self.client,
            worker=self.broker.worker,
            preparer=self.broker.preparer,
        )
        try:
            self.assertEqual(
                "interrupted_requires_review", restarted.find_request(request_id)[1]
            )
            restarted.handle_post(
                {
                    "id": "r" * 26,
                    "user_id": "human-fixture",
                    "channel_id": "c" * 26,
                    "message": f"/research-resume {request_id}",
                }
            )
            self.assertEqual(1, self.worker_calls)
            self.assertTrue(
                any("중복 여부를 확인" in message for _, _, message in self.client.posts)
            )
        finally:
            restarted.db.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
