"""Offline security-boundary tests for the governed Hermes model worker.

No test in this module imports a live Hermes install, reads auth state, opens a
socket, or starts a model request.  The real worker validation and physical
call-fence code is exercised around deliberately small in-memory SDK fakes.
"""

from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import socket
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from engine.research_team import hermes_worker as worker


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PROMPTS = {
    "manager": (
        "manager.txt",
        9542,
        "d8cae97e9d90b1210ff909e025db4a547ff7f8ad2ed45b95d1a4699c84e0c1b7",
    ),
    "researcher": (
        "researcher.txt",
        9353,
        "637045d63eb06ea6f8fe04f8f714059b67b93368c3ac13dd78015ce5a82e7582",
    ),
    "analyst": (
        "analyst.txt",
        10210,
        "8dca29efba1a7671db9445122268874dbdafa2c66e03f455aa512f589bc2409b",
    ),
    "auditor": (
        "auditor.txt",
        10685,
        "ea80c9823ff57d30676f24c71def6f26c40f103f37484a530bc2a86b5a84be3b",
    ),
}


class _FakeCreateResource:
    def __init__(self, response=None) -> None:
        self.calls = []
        self.response = response or SimpleNamespace(
            usage=SimpleNamespace(output_tokens=7),
            output_text='{"message":"ok","actions":[]}',
        )

    def create(self, *args, **kwargs):
        self.calls.append((args, kwargs))
        return self.response


class _FakeClient:
    def __init__(
        self,
        *,
        base_url: str = worker._OFFICIAL_CODEX_BASE_URL,
        max_retries: int = 0,
    ) -> None:
        self.base_url = base_url
        self.max_retries = max_retries
        self.responses = _FakeCreateResource()
        self.chat = SimpleNamespace(completions=_FakeCreateResource())


class _FakeTransport:
    def normalize_response(self, response):
        return SimpleNamespace(content=response.output_text, tool_calls=[])


class _FakeAgent:
    endpoint = worker._OFFICIAL_CODEX_BASE_URL
    sdk_retries = 0
    exposed_tools = ()
    constructed = 0
    instances = []

    def __init__(self, **kwargs) -> None:
        type(self).constructed += 1
        type(self).instances.append(self)
        self.model = kwargs["model"]
        self.provider = kwargs["provider"].lower()
        self.requested_provider = kwargs["requested_provider"].lower()
        self.api_mode = "codex_responses"
        self.base_url = type(self).endpoint
        self._client_kwargs = {
            "base_url": type(self).endpoint,
            "max_retries": type(self).sdk_retries,
        }
        self.client = _FakeClient(
            base_url=type(self).endpoint,
            max_retries=type(self).sdk_retries,
        )
        self.tools = list(type(self).exposed_tools)
        self.valid_tool_names = {
            str(entry.get("name", "tool")) if isinstance(entry, dict) else str(entry)
            for entry in self.tools
        }
        self.ephemeral_system_prompt = kwargs["ephemeral_system_prompt"]
        self.max_iterations = kwargs["max_iterations"]
        self.closed = False

    def _create_openai_client(self):
        return self.client

    def _create_request_openai_client(self):
        return self.client

    def _ensure_primary_openai_client(self):
        return self.client

    def _interruptible_api_call(self, api_kwargs):
        return self.client.responses.create(**api_kwargs)

    def _get_transport(self):
        return _FakeTransport()

    def close(self):
        self.closed = True


class ResearchWorkerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="hermes-worker-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.hermes_home = self.root / "home"
        self.install_dir = self.hermes_home / "hermes-agent"
        self.install_dir.mkdir(parents=True)
        (self.install_dir / "run_agent.py").write_text("# fixture\n", encoding="utf-8")
        (self.hermes_home / "profiles").mkdir()
        _FakeAgent.constructed = 0
        _FakeAgent.instances = []

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def request(self, role: str = "manager") -> dict:
        profile_name = f"research-{role}"
        profile_home = self.hermes_home / "profiles" / profile_name
        profile_home.mkdir(exist_ok=True)
        filename, _length, digest = PROMPTS[role]
        return {
            "install_dir": str(self.install_dir),
            "hermes_home": str(self.hermes_home),
            "profile_name": profile_name,
            "role": role,
            "prompt_path": str(PROJECT_ROOT / "assets" / "research-prompts" / filename),
            "prompt_sha256": digest,
            "model": "gpt-5.6-terra",
            "provider": "openai-codex",
            "max_output_tokens": 1234,
            "timeout_seconds": 30,
            "input": {"question": "원문 그대로 조사", "attempt": 1},
        }

    @staticmethod
    def assert_worker_error(context, code: str) -> None:
        if context.exception.code != code:
            raise AssertionError(
                f"expected WorkerError {code}, got {context.exception.code}"
            )

    def prepared_digest(self, request: dict) -> str:
        return worker._prepare_request(request)["prepared_input_sha256"]

    def test_all_four_personas_are_byte_exact_crlf_and_not_duplicated(self) -> None:
        for role, (filename, expected_length, expected_digest) in PROMPTS.items():
            with self.subTest(role=role):
                path = PROJECT_ROOT / "assets" / "research-prompts" / filename
                raw = path.read_bytes()
                self.assertEqual(expected_length, len(raw))
                self.assertEqual(expected_digest, hashlib.sha256(raw).hexdigest())
                self.assertTrue(raw.endswith(b"\r\n"))
                self.assertNotIn(b"\n", raw.replace(b"\r\n", b""))

                result = worker._prepare_request(self.request(role))
                prepared = json.loads(result["prepared"])
                expected_text = raw.decode("utf-8-sig")
                self.assertEqual(expected_text, prepared["system"])
                self.assertEqual(1, prepared["system"].count("[공통 운영규칙]"))
                self.assertEqual(0, result["native_tool_count"])
                self.assertEqual(0, result["model_call_count"])
                self.assertEqual(
                    expected_digest,
                    worker._validate_request(self.request(role))["prompt_sha256"],
                )

    def test_prepare_is_pure_and_never_constructs_or_imports_agent_or_network(self) -> None:
        request = self.request()

        class _ConstructionBomb:
            def __init__(self, **_kwargs):
                raise AssertionError("prepare constructed AIAgent")

        with (
            mock.patch.object(worker, "_import_agent_class", side_effect=AssertionError("imported")),
            mock.patch.object(worker, "_prepare_environment", side_effect=AssertionError("mutated env")),
            mock.patch.object(socket, "create_connection", side_effect=AssertionError("network")),
        ):
            result = worker._prepare_request(request, agent_class=_ConstructionBomb)
        self.assertTrue(result["ok"])
        self.assertEqual(0, result["model_call_count"])

    def test_mismatched_prepared_digest_is_denied_before_physical_send(self) -> None:
        request = self.request()
        with self.assertRaises(worker.WorkerError) as raised:
            worker._execute_request(request, "0" * 64, agent_class=_FakeAgent)
        self.assert_worker_error(raised, "PREPARED_INPUT_MISMATCH")
        self.assertEqual(1, _FakeAgent.constructed)
        self.assertEqual(0, len(_FakeAgent.instances[0].client.responses.calls))

    def test_native_tools_are_denied_in_agent_state_and_final_wire(self) -> None:
        class _ToolAgent(_FakeAgent):
            exposed_tools = ({"name": "terminal"},)

        request = self.request()
        with self.assertRaises(worker.WorkerError) as raised:
            worker._execute_request(
                request, self.prepared_digest(request), agent_class=_ToolAgent
            )
        self.assert_worker_error(raised, "NATIVE_TOOLS_PRESENT")

        validated = worker._validate_request(request)
        kwargs = worker._build_direct_api_kwargs(
            SimpleNamespace(api_mode="codex_responses"), validated
        )
        kwargs["tools"] = [{"type": "function", "name": "terminal"}]
        with self.assertRaises(worker.WorkerError) as wire_raised:
            worker._assert_and_normalize_wire_input(
                kwargs,
                validated,
                "codex_responses",
                self.prepared_digest(request),
            )
        self.assert_worker_error(wire_raised, "NATIVE_TOOLS_PRESENT")

    def test_custom_provider_and_nonofficial_codex_endpoint_are_denied(self) -> None:
        custom = self.request()
        custom["provider"] = "custom-openai"
        with self.assertRaises(worker.WorkerError) as provider_raised:
            worker._prepare_request(custom)
        self.assert_worker_error(provider_raised, "PROVIDER_UNSUPPORTED")

        class _ForeignEndpointAgent(_FakeAgent):
            endpoint = worker._OFFICIAL_CODEX_BASE_URL + ".attacker.example"

        request = self.request()
        with self.assertRaises(worker.WorkerError) as endpoint_raised:
            worker._execute_request(
                request,
                self.prepared_digest(request),
                agent_class=_ForeignEndpointAgent,
            )
        self.assert_worker_error(endpoint_raised, "MODEL_ENDPOINT_UNTRUSTED")

    def test_actual_wire_rejects_persona_model_and_token_limit_changes(self) -> None:
        request = self.request()
        validated = worker._validate_request(request)
        expected_digest = self.prepared_digest(request)
        base = worker._build_direct_api_kwargs(
            SimpleNamespace(api_mode="codex_responses"), validated
        )
        mutations = (
            ("persona", lambda value: value.__setitem__("instructions", value["instructions"] + "\nextra"), "MODEL_INPUT_CHANGED"),
            ("model", lambda value: value.__setitem__("model", "unapproved-model"), "MODEL_ROUTE_CHANGED"),
            ("token-limit", lambda value: value.__setitem__("max_output_tokens", validated["max_output_tokens"] + 1), "OUTPUT_LIMIT_UNVERIFIED"),
            ("output-format", lambda value: value.__setitem__("text", {"format": {"type": "text"}}), "OUTPUT_FORMAT_UNVERIFIED"),
        )
        for name, mutate, expected_code in mutations:
            with self.subTest(mutation=name):
                kwargs = copy.deepcopy(base)
                mutate(kwargs)
                with self.assertRaises(worker.WorkerError) as raised:
                    worker._assert_and_normalize_wire_input(
                        kwargs, validated, "codex_responses", expected_digest
                    )
                self.assert_worker_error(raised, expected_code)

    def test_sdk_send_fence_rejects_effective_extra_body_overrides_pre_send(self) -> None:
        request = self.request()
        validated = worker._validate_request(request)
        expected_digest = self.prepared_digest(request)
        mutations = (
            ("persona", {"instructions": validated["prompt_text"] + "\nextra"}, "MODEL_INPUT_CHANGED"),
            ("model", {"model": "unapproved-model"}, "MODEL_ROUTE_CHANGED"),
            ("token-limit", {"max_output_tokens": validated["max_output_tokens"] + 1}, "OUTPUT_LIMIT_UNVERIFIED"),
            ("native-tools", {"tools": [{"type": "function", "name": "terminal"}]}, "NATIVE_TOOLS_PRESENT"),
            ("store", {"store": True}, "MODEL_INPUT_CHANGED"),
            ("output-format", {"text": {"format": {"type": "json_object"}}}, "OUTPUT_FORMAT_UNVERIFIED"),
        )
        for name, overrides, expected_code in mutations:
            with self.subTest(mutation=name):
                agent = worker._new_agent(validated, _FakeAgent)
                fence = worker._install_physical_call_fence(
                    agent, validated, expected_digest
                )
                kwargs = worker._build_direct_api_kwargs(agent, validated)
                kwargs["extra_body"] = overrides
                with self.assertRaises(worker.WorkerError) as raised:
                    agent.client.responses.create(**kwargs)
                self.assert_worker_error(raised, expected_code)
                self.assertEqual(0, fence.physical_calls)
                self.assertEqual(0, len(agent.client.responses.calls))

        agent = worker._new_agent(validated, _FakeAgent)
        fence = worker._install_physical_call_fence(agent, validated, expected_digest)
        missing_limit = worker._build_direct_api_kwargs(agent, validated)
        missing_limit.pop("max_output_tokens")
        with self.assertRaises(worker.WorkerError) as missing_raised:
            agent.client.responses.create(**missing_limit)
        self.assert_worker_error(missing_raised, "OUTPUT_LIMIT_UNVERIFIED")
        self.assertEqual(0, fence.physical_calls)
        self.assertEqual(0, len(agent.client.responses.calls))

        # The supported Hermes transport may move the governed fields into
        # extra_body.  Their exact values are admitted once, then the same
        # process-wide fence blocks every subsequent physical attempt.
        agent = worker._new_agent(validated, _FakeAgent)
        fence = worker._install_physical_call_fence(agent, validated, expected_digest)
        exact = worker._build_direct_api_kwargs(agent, validated)
        moved = {
            "model": exact.pop("model"),
            "extra_body": exact,
        }
        agent.client.responses.create(**moved)
        self.assertEqual(1, fence.physical_calls)
        self.assertEqual(1, len(agent.client.responses.calls))
        with self.assertRaises(worker.WorkerError) as second:
            agent.client.responses.create(**moved)
        self.assert_worker_error(second, "MODEL_RETRY_BLOCKED")
        self.assertEqual(1, len(agent.client.responses.calls))

    def test_real_physical_fence_allows_one_response_call_and_blocks_second(self) -> None:
        client = _FakeClient(max_retries=0)
        fence = worker._PhysicalModelCallFence()
        self.assertIs(client, fence.wrap_client(client))
        first = client.responses.create(model="fixture")
        self.assertIsNotNone(first)
        self.assertEqual(1, fence.physical_calls)
        with self.assertRaises(worker.WorkerError) as raised:
            client.responses.create(model="fixture")
        self.assert_worker_error(raised, "MODEL_RETRY_BLOCKED")
        self.assertEqual(1, len(client.responses.calls))

        retrying_client = _FakeClient(max_retries=1)
        with self.assertRaises(worker.WorkerError) as retry_raised:
            worker._PhysicalModelCallFence().wrap_client(retrying_client)
        self.assert_worker_error(retry_raised, "HERMES_API_INCOMPATIBLE")
        self.assertEqual(0, len(retrying_client.responses.calls))

    def test_direct_run_uses_real_fence_and_reports_one_physical_call(self) -> None:
        request = self.request()
        result = worker._execute_request(
            request, self.prepared_digest(request), agent_class=_FakeAgent
        )
        self.assertTrue(result["ok"])
        self.assertEqual(1, result["model_call_count"])
        self.assertEqual(0, result["native_tool_count"])
        self.assertEqual(7, result["output_tokens"])
        self.assertTrue(result["usage_reported"])

    def test_unknown_usage_returns_none_instead_of_inventing_tokens(self) -> None:
        for response in (
            SimpleNamespace(usage=None),
            SimpleNamespace(usage=SimpleNamespace(total_tokens=91)),
            {"usage": {"output_tokens": "unknown"}},
            {"usage": {"completion_tokens": True}},
        ):
            with self.subTest(response=response):
                self.assertEqual((None, False), worker._reported_output_tokens(response))

    def test_strict_response_schema_matches_stage_and_is_in_reserved_input(self):
        request = self.request("researcher")
        scope = "긴 한국어 요청 범위를 바꾸지 마세요.\n\n1. 원문\t확인\r\n2. 감사"
        request["input"] = {"context": {"automatic_workflow": {"scope": scope, "output_name": "researcher", "allowed_actions": ["search_web", "read_web", "write_artifact"]}}}
        validated = worker._validate_request(request)
        kwargs = worker._build_direct_api_kwargs(SimpleNamespace(api_mode="codex_responses"), validated)
        output = kwargs["text"]["format"]
        self.assertEqual("json_schema", output["type"])
        self.assertIs(True, output["strict"])
        schema = output["schema"]
        self.assertEqual(["message", "actions"], schema["required"])
        self.assertIs(False, schema["additionalProperties"])
        self.assertEqual(1, schema["properties"]["actions"]["minItems"])
        actions = schema["properties"]["actions"]["items"]["anyOf"]
        self.assertEqual({"search_web", "read_web", "write_artifact"},
                         {item["properties"]["tool"]["enum"][0] for item in actions})
        self.assertTrue(all(set(item["required"]) == set(item["properties"]) for item in actions))
        write = next(item for item in actions if item["properties"]["tool"]["enum"] == ["write_artifact"])
        self.assertEqual(["researcher"], write["properties"]["name"]["enum"])
        self.assertEqual(["scope_" + hashlib.sha256(scope.encode("utf-8")).hexdigest()], write["properties"]["scope"]["enum"])
        prepared = json.loads(worker._prepare_request(request)["prepared"])
        self.assertEqual(kwargs["text"], prepared["output_format"])
        self.assertEqual(validated["prompt_text"], prepared["system"])
        self.assertEqual(scope, json.loads(prepared["messages"][0]["content"])["context"]["automatic_workflow"]["scope"])
        self.assertNotIn("tools", kwargs)

    def test_manager_planning_schema_requires_zero_actions_and_role_cannot_gain_dispatch(self):
        for role, allowed in (("manager", []), ("researcher", ["dispatch"])):
            request = self.request(role)
            request["input"] = {"context": {"automatic_workflow": {"scope": "scope", "allowed_actions": allowed}}}
            output = worker._response_text_format(worker._validate_request(request))
            self.assertEqual(0, output["format"]["schema"]["properties"]["actions"]["maxItems"])

    def test_audit_schema_binds_each_exact_dependency_and_assigned_stage(self):
        request = self.request("auditor")
        refs = [{"id": "artifact_" + str(index) * 32, "version": index + 1, "sha256": str(index) * 64,
                 "task_id": "task_" + str(index) * 32, "role": role, "scope": "원래 범위"}
                for index, role in enumerate(("researcher", "analyst", "manager"))]
        request["input"] = {"context": {"automatic_workflow": {"scope": "원래 범위", "allowed_actions": ["audit"]},
                                        "task": {"audit_stage": "final", "dependencies": refs}}}
        schema = worker._response_text_format(worker._validate_request(request))["format"]["schema"]
        action = schema["properties"]["actions"]["items"]
        self.assertEqual(["final"], action["properties"]["stage"]["enum"])
        token = "scope_" + hashlib.sha256("원래 범위".encode("utf-8")).hexdigest()
        self.assertEqual([token], action["properties"]["scope"]["enum"])
        bound = action["properties"]["artifact_ref"]["anyOf"]
        self.assertEqual(3, len(bound))
        for original, item in zip(refs, bound):
            self.assertEqual({**original, "scope": token}, {name: value["enum"][0] for name, value in item["properties"].items()})
        request["input"]["context"]["task"]["dependencies"][0]["scope"] = "변경된 범위"
        with self.assertRaises(worker.WorkerError):
            worker._response_text_format(worker._validate_request(request))

    def test_exact_standalone_json_fence_is_accepted_but_no_prose_or_repair(self):
        value = '{"message":"ok","actions":[]}'
        self.assertEqual(value, worker._assert_json_model_reply("```json\n" + value + "\n```"))
        self.assertEqual(value, worker._assert_json_model_reply("```\n" + value + "\n```"))
        for text in ("Here is the result:\n" + value, value + "\nDone", "```json\n" + value,
                     '{"message":"partial', '{"message":"ok","message":"duplicate","actions":[]}',
                     '{"message":"ok","actions":[{"value":NaN}]}', '{"message":"ok","actions":[]} {}'):
            with self.subTest(shape=text[:12]), self.assertRaises(worker.WorkerError):
                worker._assert_json_model_reply(text)

    def test_incomplete_or_refused_output_is_classified_without_accepting_partial_actions(self):
        agent = SimpleNamespace(_get_transport=lambda: _FakeTransport())
        for status, reason, code in (("incomplete", "max_output_tokens", "MODEL_OUTPUT_TRUNCATED"),
                                     ("incomplete", None, "MODEL_OUTPUT_INCOMPLETE"),
                                     ("incomplete", "content_filter", "MODEL_OUTPUT_REFUSED"),
                                     ("failed", None, "MODEL_RESPONSE_FAILED")):
            response = SimpleNamespace(status=status, incomplete_details={"reason": reason},
                output_text='{"message":"SECRET_PROSE","actions":[]}', output=[])
            with self.subTest(status=status, reason=reason), self.assertRaises(worker.WorkerError) as raised:
                worker._normalize_direct_response(agent, response)
            self.assert_worker_error(raised, code)
            self.assertNotIn("SECRET_PROSE", json.dumps(raised.exception.diagnostics))
            self.assertGreater(raised.exception.diagnostics["output_characters"], 0)

    def test_json_failure_has_shape_only_diagnostics_and_no_automatic_model_retry(self):
        class BadJSONAgent(_FakeAgent):
            def _interruptible_api_call(self, kwargs):
                self.client.responses.response = SimpleNamespace(status="completed", output=[],
                    output_text='{"message":"SECRET_PROSE", "actions":[')
                return super()._interruptible_api_call(kwargs)

        request = self.request()
        with self.assertRaises(worker.WorkerError) as raised:
            worker._execute_request(request, self.prepared_digest(request), agent_class=BadJSONAgent)
        self.assert_worker_error(raised, "MODEL_OUTPUT_NOT_JSON")
        metadata = raised.exception.diagnostics
        self.assertEqual(1, metadata["model_call_count"])
        self.assertTrue(metadata["starts_with_object"])
        self.assertEqual("completed", metadata["response_status"])
        self.assertIn("json_error_column", metadata)
        self.assertNotIn("SECRET_PROSE", json.dumps(metadata))
        self.assertEqual(1, len(BadJSONAgent.instances[-1].client.responses.calls))

    def test_provider_failures_are_classified_without_leaking_body_or_hidden_retries(self):
        for status, body_code, expected in (
            (400, "invalid_json_schema", "MODEL_PROTOCOL_REJECTED"),
            (401, "invalid_api_key", "MODEL_AUTH_REJECTED"),
            (429, "rate_limit_exceeded", "MODEL_RATE_LIMITED"),
            (429, "insufficient_quota", "MODEL_QUOTA_EXCEEDED"),
            (503, "unavailable", "MODEL_TRANSIENT_ERROR"),
        ):
            class ProviderException(Exception):
                status_code = status
                body = {"error": {"code": body_code, "message": "PRIVATE_CREDENTIAL"}}
            class FailingAgent(_FakeAgent):
                def __init__(self, **kwargs):
                    super().__init__(**kwargs)
                    def fail(**kwargs):
                        raise ProviderException("PRIVATE_CREDENTIAL")
                    self.client.responses.create = fail
            request = self.request()
            with self.subTest(status=status, body_code=body_code), self.assertRaises(worker.WorkerError) as raised:
                worker._execute_request(request, self.prepared_digest(request), agent_class=FailingAgent)
            self.assert_worker_error(raised, expected)
            self.assertEqual(status, raised.exception.diagnostics["http_status"])
            self.assertNotIn("PRIVATE_CREDENTIAL", str(raised.exception) + json.dumps(raised.exception.diagnostics))


if __name__ == "__main__":
    unittest.main()
