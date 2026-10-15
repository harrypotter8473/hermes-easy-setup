"""Regression tests for multiline user tasks and bounded orchestration recovery."""
import copy
import hashlib
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from engine.research_team.broker import Broker
from engine.research_team.workflow import AutomaticReportWorkflow
from engine.research_team.policy import BudgetExceeded


class RetryTests(unittest.TestCase):
    def state(self):
        return {"version": 1, "request_id": "req_" + "1"*32, "post_id": "p"*26,
                "scope": "연구 보고서\n\n공개 자료 3개\t확인", "objective": "report",
                "stage": "research", "task": {"role": "researcher", "task_id": "task_1"},
                "root_task": {"task_id": "task_0"}, "status": "running", "model_retries": 0,
                "role_runs": {}, "completed_stages": [], "stage_actions": [],
                "search_evidence": [], "read_evidence": []}

    def flow(self, state):
        broker = SimpleNamespace(event=Mock(), reply=Mock(), save=Mock(), turn=Mock(), action=Mock(),
                                 _neutralize_mentions=lambda message: message)
        flow = object.__new__(AutomaticReportWorkflow)
        flow.broker = broker
        flow.save = Mock()
        flow.load = Mock(return_value=state)
        flow._context = Mock(return_value={"automatic_workflow": {"allowed_actions": ["search_web"]}})
        return flow

    def test_wire_scope_restores_exact_multiline_scope_and_rejects_forgery(self):
        scope = self.state()["scope"]
        token = "scope_" + hashlib.sha256(scope.encode("utf-8")).hexdigest()
        context = {"automatic_workflow": {"scope": scope}}
        answer = {"actions": [{"tool": "audit", "scope": token,
                  "artifact_ref": {"id": "unchanged", "version": 2, "scope": token}}]}
        Broker.restore_automatic_scope(answer, context)
        self.assertEqual(scope, answer["actions"][0]["scope"])
        self.assertEqual(scope, answer["actions"][0]["artifact_ref"]["scope"])
        self.assertEqual("unchanged", answer["actions"][0]["artifact_ref"]["id"])
        for forged in (scope, "scope_" + "0"*64, "other"):
            with self.subTest(forged=forged), self.assertRaises(ValueError):
                Broker.restore_automatic_scope({"actions": [{"tool": "write_artifact", "scope": forged}]}, context)

    def test_research_schema_only_offers_actions_supported_by_observed_evidence(self):
        state = self.state()
        state.update(plan="plan", revision_notes={}, previous_outputs={})
        flow = object.__new__(AutomaticReportWorkflow)
        flow.broker = SimpleNamespace(task_context=lambda *args: {},
            policy=SimpleNamespace(list_web_evidence=lambda request_id: []))
        self.assertEqual(["search_web"], flow._context(state)["automatic_workflow"]["allowed_actions"])
        with self.assertRaises(ValueError):
            flow._validate_actions(state, {"message": "invented report", "actions": [{"tool": "write_artifact"}]})
        state["search_evidence"] = ["search"]
        self.assertNotIn("write_artifact", flow._context(state)["automatic_workflow"]["allowed_actions"])
        state["read_evidence"] = ["read1"]
        self.assertIn("write_artifact", flow._context(state)["automatic_workflow"]["allowed_actions"])
        state["read_evidence"] = ["read1", "read2", "read3"]
        self.assertEqual(["write_artifact"], flow._context(state)["automatic_workflow"]["allowed_actions"])

    @patch("engine.research_team.workflow.time.sleep")
    def test_budget_exhaustion_is_persisted_as_failed_and_never_auto_restarted(self, sleep):
        state = self.state()
        flow = self.flow(state)
        flow.broker.turn.side_effect = BudgetExceeded("tokens exhausted")
        self.assertEqual("failed", flow.run(state["request_id"])["status"])
        self.assertEqual(1, flow.broker.turn.call_count)
        self.assertTrue(any(call.args[1] == "failed" for call in flow.broker.save.call_args_list))
        with self.assertRaises(ValueError):
            flow.run(state["request_id"])
        sleep.assert_not_called()

    @patch("engine.research_team.workflow.time.sleep")
    def test_transient_failures_retry_three_times_without_executing_actions(self, sleep):
        state = self.state()
        flow = self.flow(state)
        flow.broker.turn.side_effect = RuntimeError("HermesWorker_MODEL_TRANSIENT_ERROR")
        result = flow.run(state["request_id"])
        self.assertEqual("held", result["status"])
        self.assertEqual(4, flow.broker.turn.call_count)
        self.assertEqual([2, 5, 10], [call.args[0] for call in sleep.call_args_list])
        flow.broker.action.assert_not_called()
        notices = [call.args[2] for call in flow.broker.reply.call_args_list]
        self.assertEqual(3, sum("자동 재시도합니다" in msg for msg in notices))
        self.assertIn("3회", notices[-1])

    @patch("engine.research_team.workflow.time.sleep")
    def test_permanent_auth_quota_and_protocol_errors_do_not_blindly_retry(self, sleep):
        for code in ("MODEL_AUTH_REJECTED", "MODEL_QUOTA_EXCEEDED", "MODEL_PROTOCOL_REJECTED", "MODEL_OUTPUT_REFUSED"):
            state = self.state()
            flow = self.flow(state)
            flow.broker.turn.side_effect = RuntimeError("HermesWorker_" + code)
            flow.run(state["request_id"])
            self.assertEqual(1, flow.broker.turn.call_count)
            self.assertEqual("held", state["status"])
            flow.broker.action.assert_not_called()
        sleep.assert_not_called()

    @patch("engine.research_team.workflow.time.sleep")
    def test_format_failure_supplies_feedback_and_success_resets_counter(self, sleep):
        class StageAdvanced(Exception):
            pass
        state = self.state()
        state["stage"] = "plan"
        state["task"]["role"] = "manager"
        flow = self.flow(state)
        contexts = []
        flow._context = lambda value: contexts.append(copy.deepcopy(value.get("retry_feedback"))) or {"automatic_workflow": {"allowed_actions": []}}
        flow.broker.turn.side_effect = [RuntimeError("HermesWorker_MODEL_OUTPUT_NOT_JSON"),
                                      {"message": "분업 계획", "actions": []}]
        flow._advance = Mock(side_effect=StageAdvanced)
        with self.assertRaises(StageAdvanced):
            flow.run(state["request_id"])
        self.assertEqual(2, flow.broker.turn.call_count)
        self.assertTrue(any(item and item["error_code"].endswith("MODEL_OUTPUT_NOT_JSON") for item in contexts))
        self.assertEqual(0, state["model_retries"])
        self.assertNotIn("retry_feedback", state)
        self.assertTrue(any("재시도가 성공" in call.args[2] for call in flow.broker.reply.call_args_list))
        flow.broker.action.assert_not_called()


if __name__ == "__main__":
    unittest.main()
