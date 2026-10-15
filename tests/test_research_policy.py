from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

from engine.research_team.policy import (
    BudgetExceeded,
    PolicyEngine,
    PolicyHold,
    PolicyViolation,
)


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class ResearchPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="hermes-research-policy-")
        self.root = Path(self.temp.name).resolve()
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        self.prompts = self.root / "prompts"
        self.prompts.mkdir()
        self.config_path = self.root / "policy.json"
        self.state_path = self.root / "policy.sqlite3"
        self.artifact_root = self.root / "policy.artifacts"
        self.config = self.make_config()
        self.write_config(self.config)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def make_config(self) -> dict:
        role_tools = {
            "manager": ["read_text", "write_artifact", "dispatch", "complete"],
            "researcher": ["read_text", "write_artifact", "complete"],
            "analyst": ["read_text", "write_artifact", "complete"],
            "auditor": ["read_text", "audit", "complete"],
        }
        roles = {}
        for role in ("manager", "researcher", "analyst", "auditor"):
            prompt = self.prompts / f"{role}.txt"
            prompt_bytes = f"fixed prompt for {role}\n".encode("utf-8")
            prompt.write_bytes(prompt_bytes)
            write_root = self.artifact_root / role
            roles[role] = {
                "profile_name": f"research-{role}",
                "prompt_path": str(prompt),
                "prompt_sha256": digest(prompt_bytes),
                "model": f"fixture-model-{role}",
                "provider": "fixture-external-provider",
                "allow_model_egress": True,
                "tools": role_tools[role],
                "read_roots": [str(self.inputs)],
                "write_roots": [str(write_root)],
                "call_targets": ["researcher", "analyst", "auditor"] if role == "manager" else [],
                "external_domains": [],
                "limits": {
                    "attempts": 8,
                    "revisions": 4,
                    "audits": 12,
                    "seconds": 120,
                    "tokens": 10000,
                    "max_output_tokens": 20,
                    "per_call_timeout_seconds": 10,
                },
            }
        return {
            "schema_version": 1,
            "human": {"allowed_user_ids": ["human-fixture"]},
            "roles": roles,
        }

    def write_config(self, value: dict) -> None:
        self.config_path.write_text(
            json.dumps(value, ensure_ascii=False, sort_keys=True), encoding="utf-8"
        )

    def new_request(self, engine: PolicyEngine, scenario: str = "S1") -> str:
        return engine.create_request(
            scenario,
            user_id="human-fixture",
            scope="fixture-scope",
            input_refs=[{"id": "input-fixture", "version": "provided-v1"}],
            outputs=["report"],
            metadata={"test": True},
        )

    def assign_researcher(self, engine: PolicyEngine, request_id: str) -> str:
        return engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="researcher",
            scope="fixture-scope",
            instructions="Produce cited source material.",
        )

    def audit(
        self,
        engine: PolicyEngine,
        request_id: str,
        artifact,
        stages=("intermediate",),
    ) -> str:
        task = ""
        for stage in stages:
            task = engine.assign_task(
                request_id,
                actor_role="manager",
                target_role="auditor",
                scope="fixture-scope",
                instructions="Audit only the supplied immutable artifact.",
                dependencies=[artifact],
                phase="audit",
                audit_stage=stage,
            )
            engine.record_audit(
                request_id,
                task,
                role="auditor",
                artifact_ref=artifact,
                stage=stage,
                verdict="pass",
                scope="fixture-scope",
                notes=f"fixture {stage} audit",
            )
        return task

    def confirm_final(self, engine: PolicyEngine, request_id: str, artifacts, scenario="S1") -> None:
        kinds = ["human_approval", "researcher_confirmation"]
        if scenario in ("S1", "S2"):
            kinds.append("access_verified")
        else:
            kinds.extend(["exact_version_shared", "publication_access_verified"])
        for artifact in artifacts:
            for kind in kinds:
                engine.record_confirmation(
                    request_id,
                    user_id="human-fixture",
                    kind=kind,
                    artifact_ref=artifact,
                    scope="fixture-scope",
                )

    def test_incomplete_template_is_pending_without_constructor_failure(self) -> None:
        self.config["roles"]["manager"]["model"] = None
        self.config["roles"]["manager"]["limits"]["tokens"] = None
        self.write_config(self.config)
        engine = PolicyEngine(self.config_path, self.state_path)
        status = engine.validate_config("manager")
        self.assertFalse(status.ready)
        self.assertEqual((), status.errors)
        self.assertTrue(any("model: pending" in reason for reason in status.pending_reasons))
        self.assertTrue(any("limits.tokens: pending" in reason for reason in status.pending_reasons))
        with self.assertRaises(PolicyHold):
            engine.require_ready("manager")

    def test_schema_rejects_unrestricted_tools_and_worker_delegation(self) -> None:
        self.config["roles"]["researcher"]["tools"].append("python")
        self.config["roles"]["researcher"]["call_targets"] = ["analyst"]
        self.write_config(self.config)
        engine = PolicyEngine(self.config_path, self.state_path)
        status = engine.validate_config("researcher")
        self.assertFalse(status.ready)
        self.assertTrue(any("unsupported broker tools" in error for error in status.errors))
        self.assertTrue(any("workers cannot delegate" in error for error in status.errors))
        with self.assertRaises(PolicyViolation):
            engine.require_ready("researcher")

    def test_manager_only_dispatch_and_root_task(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        with self.assertRaises(PolicyViolation):
            engine.create_request(
                "S1",
                user_id="human-fixture",
                scope="fixture-scope",
                input_refs=[],
                outputs="not-an-array",
            )
        request_id = self.new_request(engine)
        with self.assertRaises(PolicyViolation):
            engine.assign_task(
                request_id,
                actor_role="researcher",
                target_role="analyst",
                scope="fixture-scope",
                instructions="Workers must not delegate.",
            )
        root_task = engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="manager",
            scope="fixture-scope",
            instructions="Create the root integration output.",
            phase="prepare",
        )
        root_artifact = engine.record_artifact(
            request_id,
            root_task,
            role="manager",
            name="root-output",
            scope="fixture-scope",
            content="manager integration",
        )
        self.assertEqual("manager", root_artifact.role)
        self.assertEqual("prepare", engine.get_task(root_task)["phase"])

    def test_dependency_free_manager_root_cannot_bypass_final_integration(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        root_task = engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="manager",
            scope="fixture-scope",
            instructions="Create the root orchestration context.",
            phase="prepare",
        )
        root_output = engine.record_artifact(
            request_id,
            root_task,
            role="manager",
            name="report",
            scope="fixture-scope",
            content="dependency-free manager output",
        )
        research_task = self.assign_researcher(engine, request_id)
        research = engine.record_artifact(
            request_id,
            research_task,
            role="researcher",
            name="evidence",
            scope="fixture-scope",
            content="research evidence",
        )
        self.audit(engine, request_id, research, ("intermediate", "final"))
        analyst_task = engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="analyst",
            scope="fixture-scope",
            instructions="Analyze the audited evidence.",
            dependencies=[research],
        )
        analysis = engine.record_artifact(
            request_id,
            analyst_task,
            role="analyst",
            name="analysis",
            scope="fixture-scope",
            content="analysis",
        )
        self.audit(engine, request_id, analysis, ("intermediate", "final"))
        self.audit(engine, request_id, root_output, ("intermediate", "final"))
        self.confirm_final(engine, request_id, (research, analysis, root_output))

        decision = engine.gate(request_id, stage="final", scope="fixture-scope")
        self.assertEqual("hold", decision.status)
        self.assertIn("missing current manager integration output", decision.reasons)

    def test_budget_reserves_conservative_worst_case_and_exhaustion_fails_request(self) -> None:
        limits = self.config["roles"]["researcher"]["limits"]
        limits.update(
            {
                "attempts": 1,
                "seconds": 2,
                "tokens": 4,
                "max_output_tokens": 2,
                "per_call_timeout_seconds": 2,
            }
        )
        self.write_config(self.config)
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        reservation = engine.reserve_budget(
            request_id,
            "researcher",
            input_text="é",
            max_output_tokens=2,
            timeout_seconds=2,
        )
        budget = engine.get_budget(request_id, "researcher")
        self.assertEqual(1, budget["reserved"]["attempts"])
        self.assertEqual(4, budget["reserved"]["tokens"])
        with self.assertRaises(BudgetExceeded):
            engine.reserve_budget(
                request_id,
                "researcher",
                input_text="",
                max_output_tokens=0,
                timeout_seconds=0,
            )
        self.assertEqual("failed", engine.get_request(request_id)["status"])
        with self.assertRaises(PolicyViolation):
            engine.consume_budget(reservation, actual_output_tokens=1, elapsed_seconds=1)

    def test_budget_consumption_charges_actual_but_never_more_than_reservation(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        reservation = engine.reserve_budget(
            request_id,
            "researcher",
            input_text="한",
            max_output_tokens=5,
            timeout_seconds=4,
        )
        before = engine.get_budget(request_id, "researcher")
        self.assertEqual(8, before["reserved"]["tokens"])
        actual = engine.consume_budget(
            reservation, actual_output_tokens=2, elapsed_seconds=1.1
        )
        self.assertEqual({"attempts": 1, "tokens": 5, "seconds": 2}, actual)
        after = engine.get_budget(request_id, "researcher")
        self.assertEqual(0, after["reserved"]["tokens"])
        self.assertEqual(5, after["used"]["tokens"])

    def test_model_call_holds_without_explicit_egress_permission(self) -> None:
        self.config["roles"]["researcher"]["allow_model_egress"] = False
        self.write_config(self.config)
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        with self.assertRaises(PolicyHold):
            engine.reserve_budget(request_id, "researcher", input_text="fixture")

    def test_audit_dependency_gate_confirmations_revision_and_persistence(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        research_task = self.assign_researcher(engine, request_id)
        research_v1 = engine.record_artifact(
            request_id,
            research_task,
            role="researcher",
            name="evidence",
            scope="fixture-scope",
            content="evidence version one",
        )
        with self.assertRaises(PolicyHold):
            engine.assign_task(
                request_id,
                actor_role="manager",
                target_role="analyst",
                scope="fixture-scope",
                instructions="Analyze unaudited evidence.",
                dependencies=[research_v1],
            )

        self.audit(engine, request_id, research_v1, ("intermediate",))
        self.assertTrue(
            engine.gate(request_id, stage="intermediate", scope="fixture-scope").passed
        )
        analyst_task = engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="analyst",
            scope="fixture-scope",
            instructions="Analyze only the audited researcher artifact.",
            dependencies=[research_v1],
        )
        analysis_v1 = engine.record_artifact(
            request_id,
            analyst_task,
            role="analyst",
            name="analysis",
            scope="fixture-scope",
            content="analysis version one",
        )
        research_v1_read_task = self.audit(engine, request_id, research_v1, ("final",))
        self.audit(engine, request_id, analysis_v1, ("intermediate", "final"))
        manager_task = engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="manager",
            scope="fixture-scope",
            instructions="Integrate the audited worker outputs.",
            dependencies=[research_v1, analysis_v1],
            phase="prepare",
        )
        manager_v1 = engine.record_artifact(
            request_id,
            manager_task,
            role="manager",
            name="report",
            scope="fixture-scope",
            content="integrated report version one",
        )
        self.audit(engine, request_id, manager_v1, ("intermediate", "final"))
        held = engine.gate(request_id, stage="final", scope="fixture-scope")
        self.assertEqual("hold", held.status)
        self.assertTrue(any("human_approval" in reason for reason in held.reasons))
        reviewed = engine.reviewed_report_gate(request_id, scope="fixture-scope")
        self.assertTrue(reviewed.passed)
        with sqlite3.connect(self.state_path) as connection:
            self.assertEqual(0, connection.execute("SELECT COUNT(*) FROM confirmations").fetchone()[0])
        connection.close()
        self.confirm_final(engine, request_id, (research_v1, analysis_v1, manager_v1))
        self.assertTrue(engine.gate(request_id, stage="final", scope="fixture-scope").passed)

        research_v2 = engine.record_artifact(
            request_id,
            research_task,
            role="researcher",
            name="evidence",
            scope="fixture-scope",
            content="evidence version two",
        )
        self.assertEqual(2, research_v2.version)
        revised = engine.gate(request_id, stage="final", scope="fixture-scope")
        self.assertEqual("hold", revised.status)
        self.assertTrue(any("dependency version changed" in reason for reason in revised.reasons))
        self.assertTrue(any("researcher:evidence:v2" in reason for reason in revised.reasons))
        self.assertFalse(engine.reviewed_report_gate(request_id, scope="fixture-scope").passed)

        research_v2_read_task = engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="auditor",
            scope="fixture-scope",
            instructions="Read only the revised immutable artifact.",
            dependencies=[research_v2],
            phase="audit",
            audit_stage="intermediate",
        )

        reopened = PolicyEngine(self.config_path, self.state_path)
        artifacts = reopened.list_artifacts(request_id, scope="fixture-scope")
        self.assertEqual([1, 1, 1, 2], [artifact.version for artifact in artifacts])
        self.assertEqual(
            b"evidence version one",
            reopened.read_artifact(
                request_id,
                research_v1_read_task,
                role="auditor",
                artifact_ref=research_v1,
            ),
        )
        self.assertEqual(
            b"evidence version two",
            reopened.read_artifact(
                request_id,
                research_v2_read_task,
                role="auditor",
                artifact_ref=research_v2,
            ),
        )

    def test_auditor_cannot_emit_or_modify_original_artifacts(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        research_task = self.assign_researcher(engine, request_id)
        artifact = engine.record_artifact(
            request_id,
            research_task,
            role="researcher",
            name="source",
            scope="fixture-scope",
            content="original",
        )
        auditor_task = engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="auditor",
            scope="fixture-scope",
            instructions="Audit without changing source.",
            dependencies=[artifact],
            phase="audit",
            audit_stage="intermediate",
        )
        with self.assertRaises(PolicyViolation):
            engine.record_artifact(
                request_id,
                auditor_task,
                role="auditor",
                name="source",
                scope="fixture-scope",
                content="changed",
            )
        engine.record_audit(
            request_id,
            auditor_task,
            role="auditor",
            artifact_ref=artifact,
            stage="intermediate",
            verdict="pass",
            scope="fixture-scope",
            notes="separate append-only report",
        )
        self.assertEqual(
            b"original",
            engine.read_artifact(
                request_id,
                auditor_task,
                role="auditor",
                artifact_ref=artifact,
            ),
        )

    def test_reject_and_unverifiable_audits_never_pass_a_gate(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        research_task = self.assign_researcher(engine, request_id)
        artifact = engine.record_artifact(
            request_id,
            research_task,
            role="researcher",
            name="evidence",
            scope="fixture-scope",
            content="untrusted evidence",
        )

        for verdict in ("reject", "unverifiable"):
            audit_task = engine.assign_task(
                request_id,
                actor_role="manager",
                target_role="auditor",
                scope="fixture-scope",
                instructions=f"Record the {verdict} audit result.",
                dependencies=[artifact],
                phase="audit",
                audit_stage="intermediate",
            )
            engine.record_audit(
                request_id,
                audit_task,
                role="auditor",
                artifact_ref=artifact,
                stage="intermediate",
                verdict=verdict,
                scope="fixture-scope",
                notes=verdict,
            )
            decision = engine.gate(
                request_id, stage="intermediate", scope="fixture-scope"
            )
            self.assertEqual("hold", decision.status)
            self.assertTrue(any("missing current intermediate audit pass" in item for item in decision.reasons))

        with self.assertRaises(PolicyViolation):
            engine.record_audit(
                request_id,
                audit_task,
                role="auditor",
                artifact_ref=artifact,
                stage="intermediate",
                verdict="fail",
                scope="fixture-scope",
            )

    def test_s2_prepare_is_read_only_and_s3_requires_share_and_publication_access(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine, "S2")
        prepare = engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="analyst",
            scope="fixture-scope",
            instructions="Prepare an S2 plan using read-only access.",
            phase="prepare",
        )
        with self.assertRaises(PolicyViolation):
            engine.record_artifact(
                request_id,
                prepare,
                role="analyst",
                name="bypass",
                scope="fixture-scope",
                content="must not be written",
            )

        s3 = self.new_request(engine, "S3")
        task = self.assign_researcher(engine, s3)
        artifact = engine.record_artifact(
            s3,
            task,
            role="researcher",
            name="publication",
            scope="fixture-scope",
            content="publication exact version",
        )
        self.audit(engine, s3, artifact, ("intermediate", "final"))
        for kind in ("human_approval", "researcher_confirmation", "exact_version_shared"):
            engine.record_confirmation(
                s3,
                user_id="human-fixture",
                kind=kind,
                artifact_ref=artifact,
                scope="fixture-scope",
            )
        decision = engine.gate(s3, stage="final", scope="fixture-scope")
        self.assertEqual("hold", decision.status)
        self.assertTrue(any("publication_access_verified" in reason for reason in decision.reasons))

    def test_s2_final_pass_requires_connected_independent_numeric_verifier(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine, "S2")
        task = self.assign_researcher(engine, request_id)
        artifact = engine.record_artifact(
            request_id,
            task,
            role="researcher",
            name="numeric-result",
            scope="fixture-scope",
            content="numeric result awaiting independent calculation",
        )
        audit_task = engine.assign_task(
            request_id,
            actor_role="manager",
            target_role="auditor",
            scope="fixture-scope",
            instructions="Audit the supplied numeric result without claiming unavailable verification.",
            dependencies=[artifact],
            phase="audit",
            audit_stage="final",
        )

        with self.assertRaisesRegex(PolicyHold, "independent numeric verifier is not connected"):
            engine.record_audit(
                request_id,
                audit_task,
                role="auditor",
                artifact_ref=artifact,
                stage="final",
                verdict="pass",
                scope="fixture-scope",
                notes="static review alone must not pass S2 final numeric output",
            )

        reject_id = engine.record_audit(
            request_id,
            audit_task,
            role="auditor",
            artifact_ref=artifact,
            stage="final",
            verdict="reject",
            scope="fixture-scope",
            notes="independent calculation is unavailable",
        )
        unverifiable_id = engine.record_audit(
            request_id,
            audit_task,
            role="auditor",
            artifact_ref=artifact,
            stage="final",
            verdict="unverifiable",
            scope="fixture-scope",
            notes="numeric result remains unverifiable",
        )
        self.assertTrue(reject_id.startswith("audit_"))
        self.assertTrue(unverifiable_id.startswith("audit_"))

    def test_human_confirmation_and_exact_scope_are_fail_closed(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        with self.assertRaises(PolicyViolation):
            engine.assign_task(
                request_id,
                actor_role="manager",
                target_role="researcher",
                scope="substituted-scope",
                instructions="A task cannot substitute the request scope.",
            )
        with self.assertRaises(PolicyViolation):
            engine.gate(request_id, stage="final", scope="substituted-scope")
        task = self.assign_researcher(engine, request_id)
        artifact = engine.record_artifact(
            request_id,
            task,
            role="researcher",
            name="evidence",
            scope="fixture-scope",
            content="content",
        )
        with self.assertRaises(PolicyViolation):
            engine.record_confirmation(
                request_id,
                user_id="manager-agent",
                kind="human_approval",
                artifact_ref=artifact,
                scope="fixture-scope",
            )
        with self.assertRaises(PolicyViolation):
            engine.record_confirmation(
                request_id,
                user_id="human-fixture",
                kind="human_approval",
                artifact_ref=artifact,
                scope="other-scope",
            )

    def test_read_path_is_root_bounded_and_reparse_safe(self) -> None:
        allowed = self.inputs / "allowed.txt"
        allowed.write_text("allowed", encoding="utf-8")
        outside = self.root / "outside.txt"
        outside.write_text("outside", encoding="utf-8")
        engine = PolicyEngine(self.config_path, self.state_path)
        self.assertEqual(allowed, engine.authorize_read("researcher", allowed))
        with self.assertRaises(PolicyViolation):
            engine.authorize_read("researcher", outside)

        link = self.inputs / "linked.txt"
        try:
            os.symlink(outside, link)
        except (OSError, NotImplementedError):
            self.skipTest("symlink creation is unavailable on this Windows host")
        with self.assertRaises(PolicyViolation):
            engine.authorize_read("researcher", link)

    def test_artifacts_use_controlled_role_roots_and_broad_reads_are_rejected(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        task = self.assign_researcher(engine, request_id)
        artifact = engine.record_artifact(
            request_id,
            task,
            role="researcher",
            name="controlled",
            scope="fixture-scope",
            content="controlled content",
        )
        connection = sqlite3.connect(self.state_path)
        try:
            row = connection.execute(
                "SELECT storage_name FROM artifacts WHERE id=?", (artifact.id,)
            ).fetchone()
        finally:
            connection.close()
        self.assertIsNotNone(row)
        stored = self.artifact_root / row[0]
        self.assertTrue(stored.is_file())
        self.assertEqual(self.artifact_root / "researcher", stored.parent)

        self.config["roles"]["researcher"]["write_roots"] = [
            str(self.root / "arbitrary-writes")
        ]
        self.config["roles"]["researcher"]["read_roots"] = [str(self.root)]
        self.write_config(self.config)
        invalid = PolicyEngine(self.config_path, self.state_path)
        status = invalid.validate_config("researcher")
        self.assertFalse(status.ready)
        self.assertTrue(any("controlled role artifact root" in item for item in status.errors))
        self.assertTrue(any("overlaps protected" in item for item in status.errors))

    def test_policy_hash_change_holds_existing_state_instead_of_migrating(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        self.config["roles"]["manager"]["provider"] = "changed-external-provider"
        self.write_config(self.config)
        changed = PolicyEngine(self.config_path, self.state_path)
        status = changed.validate_config()
        self.assertTrue(status.ready)
        changed.require_ready()
        decision = changed.gate(request_id, stage="final", scope="fixture-scope")
        self.assertEqual("hold", decision.status)
        self.assertTrue(any("policy hash changed" in reason for reason in decision.reasons))
        with self.assertRaises(PolicyHold):
            changed.assign_task(
                request_id,
                actor_role="manager",
                target_role="researcher",
                scope="fixture-scope",
                instructions="Old requests must not silently migrate.",
            )
        new_request = self.new_request(changed)
        self.assertNotEqual(request_id, new_request)
        self.assertEqual("active", changed.get_request(new_request)["status"])

    def test_reviewer_receives_immutable_history_and_prior_issue_records(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        task = self.assign_researcher(engine, request_id)
        first = engine.record_artifact(request_id, task, role="researcher", name="evidence", scope="fixture-scope", content="original v1")
        self.audit(engine, request_id, first)
        second = engine.record_artifact(request_id, task, role="researcher", name="evidence", scope="fixture-scope", content="revised v2")
        audit_task = engine.assign_task(request_id, actor_role="manager", target_role="auditor", scope="fixture-scope", instructions="Recheck original issues and revisions", dependencies=[second], phase="audit", audit_stage="intermediate")
        reopened = PolicyEngine(self.config_path, self.state_path)
        history = reopened.audit_history_inputs(request_id, audit_task)
        self.assertEqual(first.as_dict(), history[0]["ref"])
        self.assertEqual("original v1", history[0]["untrusted_content"])
        records = reopened.list_audit_records(request_id, role="manager")
        self.assertEqual(first.id, records[0]["artifact_id"])
        with self.assertRaises(PolicyViolation):
            reopened.audit_history_inputs(self.new_request(reopened), audit_task)

    def test_artifact_and_audit_tables_are_append_only(self) -> None:
        engine = PolicyEngine(self.config_path, self.state_path)
        request_id = self.new_request(engine)
        task = self.assign_researcher(engine, request_id)
        artifact = engine.record_artifact(
            request_id,
            task,
            role="researcher",
            name="immutable",
            scope="fixture-scope",
            content="immutable content",
        )
        self.audit(engine, request_id, artifact)
        connection = sqlite3.connect(self.state_path)
        try:
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute("UPDATE artifacts SET sha256='x' WHERE id=?", (artifact.id,))
            connection.rollback()
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute("DELETE FROM audits")
        finally:
            connection.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
