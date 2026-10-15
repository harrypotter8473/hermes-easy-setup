#!/usr/bin/env python3
"""Fail-closed, one-shot Hermes model worker for the governed research broker.

The broker writes exactly one UTF-8 JSON object to stdin and receives exactly
one UTF-8 JSON object on stdout.  This process never exposes Hermes tools to the
model.  Model text is required to be a JSON object, but interpretation and all
tool/action execution remain the broker's responsibility.

Required stdin keys (no additional keys are accepted):
    install_dir, hermes_home, profile_name, role, prompt_path,
    prompt_sha256, model, provider, max_output_tokens, timeout_seconds, input

Run with the selected Hermes Python interpreter using ``-I -S -B``.  The
worker adds only the selected install tree and that interpreter's site-packages
to sys.path, then verifies the supported AIAgent surface before use.
"""

from __future__ import annotations

import contextlib
import hashlib
import hmac
import inspect
import json
import os
from pathlib import Path
import platform
import re
import sys
import threading
import types
from typing import Any, Callable, Dict, Iterable, Mapping, Optional, Tuple, Type


_REQUEST_KEYS = frozenset(
    {
        "install_dir",
        "hermes_home",
        "profile_name",
        "role",
        "prompt_path",
        "prompt_sha256",
        "model",
        "provider",
        "max_output_tokens",
        "timeout_seconds",
        "input",
    }
)
_ROLES = frozenset({"manager", "researcher", "analyst", "auditor"})
_PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
_PROVIDER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
_MODEL_RE = re.compile(r"^[^\x00-\x1f\x7f]{1,256}$")
_SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
_MAX_STDIN_BYTES = 1_048_576
_MAX_PROMPT_BYTES = 524_288
_MAX_INPUT_BYTES = 524_288
_MAX_OUTPUT_TOKENS = 32_768
_MAX_TIMEOUT_SECONDS = 600
_OFFICIAL_CODEX_PROVIDER = "openai-codex"
_OFFICIAL_CODEX_BASE_URL = "https://chatgpt.com/backend-api/codex"
_REQUIRED_AGENT_PARAMETERS = frozenset(
    {
        "provider",
        "requested_provider",
        "model",
        "max_iterations",
        "enabled_toolsets",
        "ephemeral_system_prompt",
        "max_tokens",
        "skip_context_files",
        "load_soul_identity",
        "skip_memory",
        "skip_background_review",
        "session_db",
        "run_budget_seconds",
        "fallback_model",
        "checkpoints_enabled",
        "pass_session_id",
    }
)


class WorkerError(Exception):
    """Expected failure with a stable, non-secret public error."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.public_message = message


class _DiscardText:
    """Bounded-by-discard stdout target for noisy imported libraries."""

    encoding = "utf-8"

    def write(self, value: object) -> int:
        return len(str(value))

    def flush(self) -> None:
        return None

    def isatty(self) -> bool:
        return False


def _reject_duplicate_keys(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise WorkerError("INVALID_JSON", "JSON contains a duplicate object key.")
        result[key] = value
    return result


def _load_json_bytes(raw: bytes) -> Any:
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise WorkerError("INVALID_ENCODING", "Input must be UTF-8 JSON.") from exc
    try:
        return json.loads(text, object_pairs_hook=_reject_duplicate_keys)
    except WorkerError:
        raise
    except (json.JSONDecodeError, RecursionError) as exc:
        raise WorkerError("INVALID_JSON", "Input is not a valid JSON object.") from exc


def _require_plain_int(value: Any, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise WorkerError("INVALID_REQUEST", f"{name} must be an integer.")
    if value < minimum or value > maximum:
        raise WorkerError(
            "INVALID_REQUEST", f"{name} must be between {minimum} and {maximum}."
        )
    return value


def _require_string(value: Any, name: str, maximum: int = 4096) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise WorkerError("INVALID_REQUEST", f"{name} must be a non-empty string.")
    if "\x00" in value:
        raise WorkerError("INVALID_REQUEST", f"{name} contains a NUL character.")
    return value


def _path_has_reparse_component(path: Path) -> bool:
    """Return true for a symlink/junction/reparse component, without following it."""

    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        try:
            stat_result = os.stat(str(current), follow_symlinks=False)
        except OSError as exc:
            raise WorkerError("UNSAFE_PATH", "A selected path cannot be inspected safely.") from exc
        if os.path.islink(str(current)):
            return True
        attributes = getattr(stat_result, "st_file_attributes", 0)
        reparse_flag = getattr(__import__("stat"), "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        if attributes & reparse_flag:
            return True
    return False


def _safe_existing_path(value: Any, name: str, *, directory: bool) -> Path:
    raw = _require_string(value, name)
    path = Path(raw)
    if not path.is_absolute() or str(path).startswith(("\\\\", "//")):
        raise WorkerError("UNSAFE_PATH", f"{name} must be a local absolute path.")
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise WorkerError("UNSAFE_PATH", f"{name} does not exist or cannot be resolved.") from exc
    if _path_has_reparse_component(path):
        raise WorkerError("UNSAFE_PATH", f"{name} must not contain a reparse point.")
    if directory and not resolved.is_dir():
        raise WorkerError("UNSAFE_PATH", f"{name} must be a directory.")
    if not directory and not resolved.is_file():
        raise WorkerError("UNSAFE_PATH", f"{name} must be a regular file.")
    return resolved


def _same_path(left: Path, right: Path) -> bool:
    return os.path.normcase(str(left)) == os.path.normcase(str(right))


def _validate_request(raw_request: Any) -> Dict[str, Any]:
    if not isinstance(raw_request, dict):
        raise WorkerError("INVALID_REQUEST", "The request must be a JSON object.")
    keys = frozenset(raw_request.keys())
    if keys != _REQUEST_KEYS:
        missing = sorted(_REQUEST_KEYS - keys)
        extra = sorted(keys - _REQUEST_KEYS)
        detail = []
        if missing:
            detail.append("missing=" + ",".join(missing))
        if extra:
            detail.append("extra=" + ",".join(extra))
        raise WorkerError("INVALID_REQUEST", "Request keys do not match the worker contract (" + "; ".join(detail) + ").")

    hermes_home = _safe_existing_path(raw_request["hermes_home"], "hermes_home", directory=True)
    install_dir = _safe_existing_path(raw_request["install_dir"], "install_dir", directory=True)
    expected_install = (hermes_home / "hermes-agent").resolve(strict=False)
    if not _same_path(install_dir, expected_install):
        raise WorkerError("UNSAFE_PATH", "install_dir must be exactly hermes_home/hermes-agent.")
    if not (install_dir / "run_agent.py").is_file():
        raise WorkerError("HERMES_API_INCOMPATIBLE", "The selected install has no run_agent.py.")

    profile_name = _require_string(raw_request["profile_name"], "profile_name", 64)
    if not _PROFILE_RE.fullmatch(profile_name) or profile_name == "default":
        raise WorkerError("INVALID_REQUEST", "profile_name must name an explicit lowercase research profile.")
    profile_home = _safe_existing_path(
        str(hermes_home / "profiles" / profile_name), "profile home", directory=True
    )
    expected_profile_home = (hermes_home / "profiles" / profile_name).resolve(strict=False)
    if not _same_path(profile_home, expected_profile_home):
        raise WorkerError("UNSAFE_PATH", "The selected profile escapes hermes_home/profiles.")

    role = _require_string(raw_request["role"], "role", 32)
    if role not in _ROLES:
        raise WorkerError("INVALID_REQUEST", "role is not one of the four governed roles.")

    prompt_path = _safe_existing_path(raw_request["prompt_path"], "prompt_path", directory=False)
    expected_hash = _require_string(raw_request["prompt_sha256"], "prompt_sha256", 64)
    if not _SHA256_RE.fullmatch(expected_hash):
        raise WorkerError("INVALID_REQUEST", "prompt_sha256 must be a SHA-256 hex digest.")
    try:
        prompt_bytes = prompt_path.read_bytes()
    except OSError as exc:
        raise WorkerError("PROMPT_READ_FAILED", "The persona prompt could not be read.") from exc
    if not prompt_bytes or len(prompt_bytes) > _MAX_PROMPT_BYTES:
        raise WorkerError("INVALID_PROMPT", "The persona prompt size is invalid.")
    actual_hash = hashlib.sha256(prompt_bytes).hexdigest()
    if not hmac.compare_digest(actual_hash, expected_hash.lower()):
        raise WorkerError("PROMPT_HASH_MISMATCH", "The persona prompt hash does not match governance.")
    try:
        prompt_text = prompt_bytes.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise WorkerError("INVALID_PROMPT", "The persona prompt must be UTF-8 text.") from exc
    if not prompt_text or "\x00" in prompt_text:
        raise WorkerError("INVALID_PROMPT", "The persona prompt text is invalid.")

    provider = _require_string(raw_request["provider"], "provider", 64)
    if not _PROVIDER_RE.fullmatch(provider):
        raise WorkerError("INVALID_REQUEST", "provider has an invalid identifier.")
    if provider != _OFFICIAL_CODEX_PROVIDER:
        raise WorkerError(
            "PROVIDER_UNSUPPORTED",
            "The governed research worker supports only the official openai-codex provider.",
        )
    model = _require_string(raw_request["model"], "model", 256)
    if not _MODEL_RE.fullmatch(model) or model != model.strip():
        raise WorkerError("INVALID_REQUEST", "model has an invalid identifier.")

    max_output_tokens = _require_plain_int(
        raw_request["max_output_tokens"], "max_output_tokens", 1, _MAX_OUTPUT_TOKENS
    )
    timeout_seconds = _require_plain_int(
        raw_request["timeout_seconds"], "timeout_seconds", 1, _MAX_TIMEOUT_SECONDS
    )

    protocol_input = raw_request["input"]
    if not isinstance(protocol_input, dict):
        raise WorkerError("INVALID_REQUEST", "input must be a JSON object.")
    try:
        user_message = json.dumps(
            protocol_input, ensure_ascii=False, separators=(",", ":"), sort_keys=True
        )
    except (TypeError, ValueError, RecursionError) as exc:
        raise WorkerError("INVALID_REQUEST", "input is not a serializable JSON object.") from exc
    if len(user_message.encode("utf-8")) > _MAX_INPUT_BYTES:
        raise WorkerError("INVALID_REQUEST", "input exceeds the worker size limit.")

    return {
        "install_dir": install_dir,
        "hermes_home": hermes_home,
        "profile_name": profile_name,
        "profile_home": profile_home,
        "role": role,
        "prompt_path": prompt_path,
        "prompt_sha256": actual_hash,
        "prompt_text": prompt_text,
        "provider": provider,
        "model": model,
        "max_output_tokens": max_output_tokens,
        "timeout_seconds": timeout_seconds,
        "user_message": user_message,
    }


def _site_packages_for_selected_python(install_dir: Path) -> Path:
    executable = Path(sys.executable).resolve(strict=True)
    venv_root = executable.parent.parent
    candidates = [
        venv_root / "Lib" / "site-packages",
        venv_root / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages",
        install_dir / "venv" / "Lib" / "site-packages",
        install_dir / ".venv" / "Lib" / "site-packages",
    ]
    existing = []
    for candidate in candidates:
        try:
            if candidate.is_dir():
                resolved = candidate.resolve(strict=True)
                if not _path_has_reparse_component(candidate):
                    existing.append(resolved)
        except (OSError, WorkerError):
            continue
    if not existing:
        raise WorkerError(
            "HERMES_API_INCOMPATIBLE",
            "The selected Python has no inspectable Hermes site-packages directory.",
        )
    return existing[0]


def _prepare_environment(request: Mapping[str, Any]) -> None:
    # Direct AIAgent calls infer profile identity from HERMES_HOME.  Bind it to
    # the explicit named profile before importing any Hermes module.
    os.environ["HERMES_HOME"] = str(request["profile_home"])
    os.environ["HERMES_PROFILE"] = str(request["profile_name"])
    os.environ["HERMES_PROFILE_NAME"] = str(request["profile_name"])
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    os.environ["NO_COLOR"] = "1"

    # The embedded Windows Python used by Hermes shells out to ``ver`` from
    # platform.system().  The worker already knows the host from os.name; avoid
    # that child process before the offline audit guard is installed.
    if os.name == "nt":
        platform.system = lambda: "Windows"  # type: ignore[assignment]

    # Inherited dispatcher/delegation state can cause Hermes to add kanban or
    # child-agent behavior even when an empty toolset was requested.
    exact_drops = {
        "HERMES_CONFIG",
        "HERMES_ENV",
        "HERMES_ENABLE_PROJECT_PLUGINS",
        "HERMES_YOLO_MODE",
    }
    prefix_drops = (
        "HERMES_KANBAN_",
        "HERMES_DISPATCHER_",
        "HERMES_DELEGATE_",
        "HERMES_DELEGATED_",
    )
    for key in list(os.environ):
        if key in exact_drops or key.startswith(prefix_drops):
            os.environ.pop(key, None)


def _import_agent_class(request: Mapping[str, Any]) -> Type[Any]:
    if not (sys.flags.isolated and sys.flags.no_site and sys.flags.dont_write_bytecode):
        raise WorkerError(
            "UNSAFE_LAUNCH",
            "The worker must be launched with the selected Python using -I -S -B.",
        )
    if "run_agent" in sys.modules or "model_tools" in sys.modules:
        raise WorkerError("HERMES_API_INCOMPATIBLE", "Hermes was imported before isolation was established.")

    install_dir = request["install_dir"]
    site_packages = _site_packages_for_selected_python(install_dir)
    sys.path.insert(0, str(site_packages))
    sys.path.insert(0, str(install_dir))

    try:
        # run_agent imports hermes_bootstrap for CLI dependency repair and PM
        # activation.  A governed worker already runs the explicitly selected
        # interpreter/site-packages and must never let an import acquire install
        # locks or repair/update the user's checkout.
        bootstrap_stub = types.ModuleType("hermes_bootstrap")

        def _governed_create_connection(
            address: Tuple[str, int],
            timeout: Optional[float],
            source_address: Optional[Tuple[str, int]] = None,
            socket_options: Iterable[Tuple[Any, ...]] = (),
        ) -> Any:
            # The real bootstrap module also performs dependency repair and
            # launch hand-off at import time, so importing it is forbidden.
            # Newer Hermes transports import this one stdlib networking helper;
            # provide the same callable surface without those bootstrap side
            # effects.  Offline check/prepare still block the socket audit
            # events before this function can connect.
            import socket

            sock = socket.create_connection(address, timeout, source_address)
            try:
                for option in socket_options:
                    sock.setsockopt(*option)
            except BaseException:
                sock.close()
                raise
            return sock

        bootstrap_stub._happy_eyeballs_create_connection = _governed_create_connection
        sys.modules["hermes_bootstrap"] = bootstrap_stub

        # Replace both discovery surfaces before run_agent is imported.  An
        # empty model_tools module avoids discover_builtin_tools(), whose cache
        # write and imports are both unnecessary when tools are forbidden.
        model_tools_stub = types.ModuleType("model_tools")
        model_tools_stub.get_tool_definitions = lambda **_kwargs: []
        model_tools_stub.get_toolset_for_tool = lambda *_args, **_kwargs: None

        def _blocked_tool_call(*_args: Any, **_kwargs: Any) -> Any:
            raise WorkerError("NATIVE_TOOL_CALL_BLOCKED", "A Hermes native tool call was blocked.")

        model_tools_stub.handle_function_call = _blocked_tool_call
        model_tools_stub.check_toolset_requirements = lambda *_args, **_kwargs: False
        model_tools_stub.get_all_tool_names = lambda: []
        model_tools_stub.get_available_toolsets = lambda: []
        sys.modules["model_tools"] = model_tools_stub

        plugins_stub = types.ModuleType("hermes_cli.plugins")

        def _plugins_disabled(*_args: Any, **_kwargs: Any) -> None:
            return None

        class _EmptyPluginManager:
            _plugins: Dict[str, Any] = {}

            def __getattr__(self, _name: str) -> Any:
                return _plugins_disabled

        plugins_stub.discover_plugins = _plugins_disabled
        plugins_stub._ensure_plugins_discovered = _plugins_disabled
        plugins_stub.render_system_prompt_sections = lambda *_args, **_kwargs: ()
        plugins_stub.format_system_prompt_sections = lambda *_args, **_kwargs: ""
        plugins_stub.get_plugin_context_engine = lambda *_args, **_kwargs: None
        plugins_stub.get_plugin_auxiliary_tasks = lambda *_args, **_kwargs: ()
        plugins_stub.get_plugin_error_classification = lambda *_args, **_kwargs: None
        plugins_stub.get_pre_verify_continue_message = lambda *_args, **_kwargs: None
        plugins_stub.get_plugin_manager = lambda: _EmptyPluginManager()
        plugins_stub.invoke_hook = lambda *_args, **_kwargs: []
        plugins_stub.has_hook = lambda *_args, **_kwargs: False
        plugins_stub.set_thread_tool_whitelist = _plugins_disabled
        plugins_stub.clear_thread_tool_whitelist = _plugins_disabled
        plugins_stub._dispatch_pre_tool_call_hooks = _blocked_tool_call
        plugins_stub.VALID_HOOKS = frozenset()
        plugins_stub.SHELL_UNSUPPORTED_HOOKS = frozenset()
        plugins_stub.MAX_SYSTEM_PROMPT_SECTION_CHARS = 0
        plugins_stub.PLUGIN_SECTIONS_START = ""
        plugins_stub.PLUGIN_SECTIONS_END = ""
        plugins_stub.__getattr__ = lambda _name: _plugins_disabled
        sys.modules["hermes_cli.plugins"] = plugins_stub

        # Stamp-backed releases can otherwise run version discovery while
        # importing run_agent. Pin that API to the install stamp. The pinned
        # v2026.8.19 source predates hermes_cli.version_info and exposes a
        # static hermes_cli.__version__ instead, so it needs no substitute.
        version_info_path = install_dir / "hermes_cli" / "version_info.py"
        if version_info_path.is_file():
            try:
                stamp_raw = json.loads(
                    (install_dir / "install-stamp.json").read_text(encoding="utf-8-sig")
                )
            except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise WorkerError(
                    "HERMES_API_INCOMPATIBLE", "The selected Hermes install stamp is unavailable."
                ) from exc
            base_version = str(stamp_raw.get("baseVersion") or "").strip()
            display_version = str(stamp_raw.get("displayVersion") or base_version).strip()
            if not base_version or len(base_version) > 64 or len(display_version) > 128:
                raise WorkerError(
                    "HERMES_API_INCOMPATIBLE", "The selected Hermes install stamp is invalid."
                )
            from hermes_cli import version_info as version_info_module

            safe_version_info = types.SimpleNamespace(
                base_version=base_version,
                derived_version=display_version,
                display_version=display_version,
                commit_date=stamp_raw.get("commitDate"),
            )
            version_info_module.get_version_info = lambda: safe_version_info

        from run_agent import AIAgent

        # Agent construction otherwise creates rotating files below the
        # selected profile even for --prepare.  Worker diagnostics must remain
        # on the process boundary and must not mutate the preserved profile.
        import hermes_logging

        hermes_logging.setup_logging = lambda *_args, **_kwargs: None
        hermes_logging.setup_verbose_logging = lambda *_args, **_kwargs: None
    except Exception as exc:
        raise WorkerError(
            "HERMES_API_INCOMPATIBLE", "The selected Hermes AIAgent API could not be imported."
        ) from exc

    try:
        parameters = frozenset(inspect.signature(AIAgent.__init__).parameters)
    except (TypeError, ValueError) as exc:
        raise WorkerError("HERMES_API_INCOMPATIBLE", "The AIAgent signature is not inspectable.") from exc
    missing = sorted(_REQUIRED_AGENT_PARAMETERS - parameters)
    if missing:
        raise WorkerError(
            "HERMES_API_INCOMPATIBLE",
            "The selected Hermes version lacks required governed-worker APIs: " + ", ".join(missing),
        )
    required_methods = (
        "close",
        "_interruptible_api_call",
        "_get_transport",
        "_create_openai_client",
        "_create_request_openai_client",
        "_ensure_primary_openai_client",
    )
    missing_methods = [name for name in required_methods if not callable(getattr(AIAgent, name, None))]
    if missing_methods:
        raise WorkerError(
            "HERMES_API_INCOMPATIBLE",
            "The selected Hermes version lacks required governed-worker methods: "
            + ", ".join(missing_methods),
        )
    return AIAgent


def _assert_no_native_tools(agent: Any) -> None:
    if not hasattr(agent, "tools") or not hasattr(agent, "valid_tool_names"):
        raise WorkerError("HERMES_API_INCOMPATIBLE", "Hermes does not expose auditable tool state.")
    if bool(getattr(agent, "tools")) or bool(getattr(agent, "valid_tool_names")):
        raise WorkerError("NATIVE_TOOLS_PRESENT", "Hermes exposed native tools; the model call was blocked.")


def _assert_json_model_reply(text: Any) -> str:
    if not isinstance(text, str):
        raise WorkerError("INVALID_MODEL_OUTPUT", "Hermes returned a non-text response.")
    if not text or len(text.encode("utf-8")) > 8_388_608:
        raise WorkerError("INVALID_MODEL_OUTPUT", "The model response size is invalid.")
    try:
        parsed = json.loads(text, object_pairs_hook=_reject_duplicate_keys)
    except WorkerError as exc:
        raise WorkerError("MODEL_OUTPUT_NOT_JSON", "The model response contains duplicate JSON keys.") from exc
    except (json.JSONDecodeError, RecursionError) as exc:
        raise WorkerError("MODEL_OUTPUT_NOT_JSON", "The model response is not one strict JSON object.") from exc
    if not isinstance(parsed, dict):
        raise WorkerError("MODEL_OUTPUT_NOT_JSON", "The model response must be a JSON object.")
    return text


def _logical_prepared_input(system_text: str, user_text: str) -> bytes:
    return json.dumps(
        {
            "messages": [{"role": "user", "content": user_text}],
            "system": system_text,
        },
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def _single_wire_text(value: Any) -> Optional[str]:
    """Return one plain text payload, rejecting multimodal or composite input."""

    if isinstance(value, str):
        return value
    if not isinstance(value, list) or len(value) != 1 or not isinstance(value[0], dict):
        return None
    part = value[0]
    if part.get("type") not in {"text", "input_text"}:
        return None
    text = part.get("text")
    return text if isinstance(text, str) else None


def _count_text_occurrences(value: Any, needle: str) -> int:
    if isinstance(value, str):
        return value.count(needle)
    if isinstance(value, dict):
        return sum(_count_text_occurrences(item, needle) for item in value.values())
    if isinstance(value, (list, tuple)):
        return sum(_count_text_occurrences(item, needle) for item in value)
    return 0


def _normalized_codex_endpoint(value: Any) -> str:
    """Normalize only the single trailing slash the OpenAI client adds."""

    endpoint = str(value or "")
    return endpoint[:-1] if endpoint.endswith("/") else endpoint


def _assert_official_codex_endpoint(value: Any) -> None:
    if _normalized_codex_endpoint(value) != _OFFICIAL_CODEX_BASE_URL:
        raise WorkerError(
            "MODEL_ENDPOINT_UNTRUSTED",
            "Hermes did not resolve the official ChatGPT Codex endpoint.",
        )


def _assert_zero_sdk_retries(client: Any) -> None:
    retries = getattr(client, "max_retries", None)
    if isinstance(retries, bool) or not isinstance(retries, int) or retries != 0:
        raise WorkerError(
            "HERMES_API_INCOMPATIBLE",
            "Hermes did not expose an OpenAI SDK client with retries disabled.",
        )


def _assert_official_codex_route(agent: Any, request: Mapping[str, Any]) -> None:
    if request["provider"] != _OFFICIAL_CODEX_PROVIDER:
        raise WorkerError("PROVIDER_UNSUPPORTED", "Only openai-codex is supported.")
    if getattr(agent, "provider", None) != _OFFICIAL_CODEX_PROVIDER:
        raise WorkerError("MODEL_ROUTE_CHANGED", "Hermes changed the governed provider.")
    if getattr(agent, "requested_provider", None) != _OFFICIAL_CODEX_PROVIDER:
        raise WorkerError("MODEL_ROUTE_CHANGED", "Hermes changed the requested provider.")
    if getattr(agent, "api_mode", None) != "codex_responses":
        raise WorkerError(
            "HERMES_API_MODE_UNSUPPORTED",
            "The official provider did not resolve to the Codex Responses transport.",
        )
    _assert_official_codex_endpoint(getattr(agent, "base_url", None))
    client_kwargs = getattr(agent, "_client_kwargs", None)
    if not isinstance(client_kwargs, dict):
        raise WorkerError("HERMES_API_INCOMPATIBLE", "Hermes client settings are not inspectable.")
    _assert_official_codex_endpoint(client_kwargs.get("base_url"))
    configured_retries = client_kwargs.get("max_retries")
    if configured_retries is not None and (
        isinstance(configured_retries, bool)
        or not isinstance(configured_retries, int)
        or configured_retries != 0
    ):
        raise WorkerError(
            "HERMES_API_INCOMPATIBLE",
            "Hermes configured transport-level model retries.",
        )


class _PhysicalModelCallFence:
    """Fence every OpenAI SDK send surface to exactly one physical request."""

    def __init__(self, send_validator: Optional[Callable[[Mapping[str, Any]], None]] = None) -> None:
        self._lock = threading.Lock()
        self._physical_calls = 0
        self._wrapped_clients = []
        self._send_validator = send_validator

    @property
    def physical_calls(self) -> int:
        with self._lock:
            return self._physical_calls

    def _claim(self, route: str) -> None:
        with self._lock:
            if self._physical_calls >= 1:
                raise WorkerError(
                    "MODEL_RETRY_BLOCKED",
                    "Hermes attempted a second physical model request.",
                )
            if route != "responses.create":
                raise WorkerError(
                    "MODEL_ROUTE_CHANGED",
                    "Hermes attempted a non-Codex model request.",
                )
            self._physical_calls += 1

    def wrap_client(self, client: Any) -> Any:
        if client is None:
            raise WorkerError("HERMES_API_INCOMPATIBLE", "Hermes did not expose its OpenAI client.")
        _assert_official_codex_endpoint(getattr(client, "base_url", None))
        _assert_zero_sdk_retries(client)
        if any(existing is client for existing in self._wrapped_clients):
            return client

        response_resource = getattr(client, "responses", None)
        response_create = getattr(response_resource, "create", None)
        if not callable(response_create):
            raise WorkerError(
                "HERMES_API_INCOMPATIBLE", "The Codex client has no Responses create method."
            )
        chat_resource = getattr(client, "chat", None)
        chat_completions = getattr(chat_resource, "completions", None)

        for route, owner in (
            ("responses.create", response_resource),
            ("chat.completions.create", chat_completions),
        ):
            original = getattr(owner, "create", None)
            if owner is None or not callable(original):
                if route == "responses.create":
                    raise WorkerError(
                        "HERMES_API_INCOMPATIBLE", "The Codex client send method is unavailable."
                    )
                continue

            def _guarded_create(
                *args: Any,
                __original: Any = original,
                __route: str = route,
                **kwargs: Any,
            ) -> Any:
                if __route == "responses.create" and self._send_validator is not None:
                    self._send_validator(kwargs)
                self._claim(__route)
                return __original(*args, **kwargs)

            try:
                setattr(owner, "create", _guarded_create)
            except Exception as exc:
                raise WorkerError(
                    "HERMES_API_INCOMPATIBLE",
                    "The OpenAI SDK model-call boundary cannot be fenced.",
                ) from exc
            if getattr(owner, "create", None) is not _guarded_create:
                raise WorkerError(
                    "HERMES_API_INCOMPATIBLE",
                    "The OpenAI SDK model-call fence could not be verified.",
                )
            if route == "responses.create" and getattr(client, "responses", None) is not owner:
                raise WorkerError(
                    "HERMES_API_INCOMPATIBLE",
                    "The OpenAI SDK Responses boundary is not stable enough to fence.",
                )
            if route == "chat.completions.create" and (
                getattr(getattr(client, "chat", None), "completions", None) is not owner
            ):
                raise WorkerError(
                    "HERMES_API_INCOMPATIBLE",
                    "The OpenAI SDK Chat boundary is not stable enough to fence.",
                )

        # Retain the closures and client for the complete request lifetime.
        self._wrapped_clients.append(client)
        return client


def _install_physical_call_fence(
    agent: Any,
    request: Mapping[str, Any],
    expected_prepare_sha256: str,
) -> _PhysicalModelCallFence:
    def _validate_actual_send(actual_kwargs: Mapping[str, Any]) -> None:
        if not isinstance(actual_kwargs, dict):
            raise WorkerError(
                "HERMES_API_INCOMPATIBLE", "The OpenAI SDK received an invalid model request."
            )
        # Hermes may move the bulk input to extra_body to bypass the SDK's
        # expensive TypedDict transform. The SDK merges extra_body last, so
        # validate those exact effective wire values, including any override.
        extra_body = actual_kwargs.get("extra_body")
        if extra_body is not None and not isinstance(extra_body, dict):
            raise WorkerError(
                "MODEL_INPUT_CHANGED", "Hermes produced an invalid OpenAI extra_body."
            )
        effective_kwargs = {
            key: value for key, value in actual_kwargs.items() if key != "extra_body"
        }
        if isinstance(extra_body, dict):
            effective_kwargs.update(extra_body)
        _assert_and_normalize_wire_input(
            effective_kwargs, request, "codex_responses", expected_prepare_sha256
        )

    fence = _PhysicalModelCallFence(_validate_actual_send)
    fence.wrap_client(getattr(agent, "client", None))

    # Hermes creates request-scoped clients after the worker's final policy
    # check. Fence both the low-level factory and cache-returning wrappers so a
    # fresh or reused client cannot bypass the same process-wide call counter.
    for name in (
        "_create_openai_client",
        "_create_request_openai_client",
        "_ensure_primary_openai_client",
    ):
        original = getattr(agent, name, None)
        if not callable(original):
            raise WorkerError(
                "HERMES_API_INCOMPATIBLE", "Hermes lacks a fenceable OpenAI client factory."
            )

        def _guarded_factory(
            *args: Any,
            __original: Any = original,
            **kwargs: Any,
        ) -> Any:
            return fence.wrap_client(__original(*args, **kwargs))

        try:
            setattr(agent, name, _guarded_factory)
        except Exception as exc:
            raise WorkerError(
                "HERMES_API_INCOMPATIBLE", "Hermes client creation cannot be fenced."
            ) from exc
        if getattr(agent, name, None) is not _guarded_factory:
            raise WorkerError(
                "HERMES_API_INCOMPATIBLE", "Hermes client factory fence could not be verified."
            )
    return fence


def _assert_and_normalize_wire_input(
    api_kwargs: Any,
    request: Mapping[str, Any],
    api_mode: str,
    expected_prepare_sha256: str,
) -> None:
    """Validate the final pre-network payload against the broker-reserved prompt."""

    if not isinstance(api_kwargs, dict):
        raise WorkerError("HERMES_API_INCOMPATIBLE", "Hermes produced an invalid model request.")
    if api_kwargs.get("model") != request["model"]:
        raise WorkerError("MODEL_ROUTE_CHANGED", "Hermes changed the governed model before the call.")
    if api_kwargs.get("tools") not in (None, [], ()):
        raise WorkerError("NATIVE_TOOLS_PRESENT", "Hermes added tools to the model request.")
    for key in ("tool_choice", "parallel_tool_calls"):
        if key in api_kwargs:
            raise WorkerError("NATIVE_TOOLS_PRESENT", "Hermes added tool controls to the model request.")

    system_text: Optional[str] = None
    user_text: Optional[str] = None
    if api_mode == "chat_completions":
        messages = api_kwargs.get("messages")
        if not isinstance(messages, list) or len(messages) != 2:
            raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the governed message count.")
        first, second = messages
        if not isinstance(first, dict) or first.get("role") not in {"system", "developer"}:
            raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the governed system message.")
        if not isinstance(second, dict) or second.get("role") != "user":
            raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the governed user message.")
        system_text = _single_wire_text(first.get("content"))
        user_text = _single_wire_text(second.get("content"))
    elif api_mode == "anthropic_messages":
        messages = api_kwargs.get("messages")
        if not isinstance(messages, list) or len(messages) != 1:
            raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the governed message count.")
        only = messages[0]
        if not isinstance(only, dict) or only.get("role") != "user":
            raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the governed user message.")
        system_text = _single_wire_text(api_kwargs.get("system"))
        user_text = _single_wire_text(only.get("content"))
    elif api_mode == "codex_responses":
        instructions = api_kwargs.get("instructions")
        if instructions != request["prompt_text"]:
            raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the governed system message.")
        if api_kwargs.get("store") is not False:
            raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the no-store model request.")
        inputs = api_kwargs.get("input")
        if not isinstance(inputs, list) or len(inputs) != 1:
            raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the governed message count.")
        only = inputs[0]
        if not isinstance(only, dict) or only.get("role") != "user":
            raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the governed user message.")
        system_text = api_kwargs.get("instructions")
        user_text = _single_wire_text(only.get("content"))
    else:
        raise WorkerError(
            "HERMES_API_MODE_UNSUPPORTED",
            "The selected Hermes provider does not use a governed one-call API path.",
        )

    if system_text != request["prompt_text"] or user_text != request["user_message"]:
        raise WorkerError("MODEL_INPUT_CHANGED", "Hermes changed the broker-reserved model input.")
    if _count_text_occurrences(api_kwargs, request["prompt_text"]) != 1:
        raise WorkerError("MODEL_INPUT_CHANGED", "The persona must appear exactly once in the model request.")
    actual_prepared = _logical_prepared_input(system_text, user_text)
    actual_digest = hashlib.sha256(actual_prepared).hexdigest()
    if not hmac.compare_digest(actual_digest, expected_prepare_sha256.lower()):
        raise WorkerError(
            "PREPARED_INPUT_MISMATCH",
            "The final model input differs from the broker-reserved input.",
        )

    output_keys = ("max_tokens", "max_completion_tokens", "max_output_tokens")
    configured_limits = [(key, api_kwargs[key]) for key in output_keys if key in api_kwargs]
    if len(configured_limits) != 1:
        raise WorkerError("OUTPUT_LIMIT_UNVERIFIED", "Hermes did not expose one output-token limit.")
    limit = configured_limits[0][1]
    if (
        isinstance(limit, bool)
        or not isinstance(limit, int)
        or limit < 1
        or limit > request["max_output_tokens"]
    ):
        raise WorkerError("OUTPUT_LIMIT_UNVERIFIED", "Hermes changed the output-token limit.")


def _new_agent(request: Mapping[str, Any], agent_class: Type[Any]) -> Any:
    return agent_class(
        provider=request["provider"],
        requested_provider=request["provider"],
        model=request["model"],
        max_iterations=1,
        enabled_toolsets=[],
        disabled_toolsets=[],
        save_trajectories=False,
        verbose_logging=False,
        quiet_mode=True,
        ephemeral_system_prompt=None,
        max_tokens=request["max_output_tokens"],
        request_overrides={},
        prefill_messages=[],
        platform="cli",
        skip_context_files=True,
        load_soul_identity=False,
        skip_memory=True,
        skip_background_review=True,
        session_db=None,
        run_budget_seconds=float(request["timeout_seconds"]),
        fallback_model=None,
        checkpoints_enabled=False,
        pass_session_id=False,
    )


def _prepare_agent_input(agent: Any, request: Mapping[str, Any]) -> bytes:
    _assert_no_native_tools(agent)
    if getattr(agent, "ephemeral_system_prompt", None) is not None:
        raise WorkerError("HERMES_API_INCOMPATIBLE", "Hermes added an unexpected ephemeral prompt.")
    if getattr(agent, "max_iterations", None) != 1:
        raise WorkerError("HERMES_API_INCOMPATIBLE", "Hermes did not enforce one model iteration.")

    # Dedicated workers use the verified persona file as the complete cached
    # system message.  This preserves every character, including a final
    # newline; Hermes' ephemeral append path calls .strip() and cannot provide
    # that byte-for-byte property.  With context/SOUL/memory/plugins disabled,
    # no native Hermes system prose is admitted.
    effective_system = request["prompt_text"]
    agent._cached_system_prompt = effective_system
    agent._cached_system_prompt_static = effective_system
    return _logical_prepared_input(effective_system, request["user_message"])


def _build_direct_api_kwargs(agent: Any, request: Mapping[str, Any]) -> Dict[str, Any]:
    """Build one exact, tool-free request without Hermes' conversation machinery."""

    mode = str(getattr(agent, "api_mode", ""))
    if request["provider"] != _OFFICIAL_CODEX_PROVIDER or mode != "codex_responses":
        raise WorkerError(
            "HERMES_API_MODE_UNSUPPORTED",
            "The selected Hermes provider does not use the governed Codex Responses path.",
        )
    return {
        "model": request["model"],
        "instructions": request["prompt_text"],
        "input": [
            {
                "role": "user",
                "content": [{"type": "input_text", "text": request["user_message"]}],
            }
        ],
        "store": False,
        "max_output_tokens": request["max_output_tokens"],
        "timeout": float(request["timeout_seconds"]),
    }


def _normalize_direct_response(agent: Any, response: Any) -> str:
    transport = agent._get_transport()
    normalize = getattr(transport, "normalize_response", None)
    if not callable(normalize):
        raise WorkerError("HERMES_API_INCOMPATIBLE", "Hermes has no response normalizer.")
    normalized = normalize(response)
    if getattr(normalized, "tool_calls", None):
        raise WorkerError("NATIVE_TOOL_CALL_BLOCKED", "The model returned a forbidden native tool call.")
    return _assert_json_model_reply(getattr(normalized, "content", None))


def _reported_output_tokens(response: Any) -> Tuple[Optional[int], bool]:
    usage = getattr(response, "usage", None)
    if usage is None and isinstance(response, dict):
        usage = response.get("usage")
    for name in ("output_tokens", "completion_tokens"):
        value = usage.get(name) if isinstance(usage, dict) else getattr(usage, name, None)
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            return value, True
    return None, False


def _close_agent(agent: Optional[Any]) -> None:
    if agent is not None:
        try:
            agent.close()
        except Exception:
            pass


def _run_agent(
    request: Mapping[str, Any],
    agent_class: Type[Any],
    expected_prepare_sha256: str,
) -> Dict[str, Any]:
    agent: Optional[Any] = None
    try:
        agent = _new_agent(request, agent_class)
        if getattr(agent, "model", None) != request["model"]:
            raise WorkerError("MODEL_ROUTE_CHANGED", "Hermes changed the governed model during setup.")
        if getattr(agent, "provider", None) != request["provider"].lower():
            raise WorkerError("MODEL_ROUTE_CHANGED", "Hermes changed the governed provider during setup.")
        if getattr(agent, "requested_provider", None) != request["provider"].lower():
            raise WorkerError("MODEL_ROUTE_CHANGED", "Hermes changed the requested provider during setup.")
        prepared_input = _prepare_agent_input(agent, request)
        prepared_sha256 = hashlib.sha256(prepared_input).hexdigest()
        if not hmac.compare_digest(prepared_sha256, expected_prepare_sha256.lower()):
            raise WorkerError(
                "PREPARED_INPUT_MISMATCH",
                "The immutable model input differs from the broker-reserved input.",
            )

        # Do not enter AIAgent.chat(): its middleware, dynamic prompt/context,
        # empty-response recovery, iteration summary and fallback paths can all
        # change the reserved input or issue another request.  Construct one
        # exact, tool-free payload and invoke the native non-streaming seam once.
        agent._fallback_chain = []
        agent._fallback_model = None
        _assert_official_codex_route(agent, request)
        api_kwargs = _build_direct_api_kwargs(agent, request)
        _assert_no_native_tools(agent)
        _assert_and_normalize_wire_input(
            api_kwargs, request, str(getattr(agent, "api_mode", "")), expected_prepare_sha256
        )
        physical_fence = _install_physical_call_fence(
            agent, request, expected_prepare_sha256
        )
        response = agent._interruptible_api_call(api_kwargs)
        physical_calls = physical_fence.physical_calls
        if physical_calls != 1:
            raise WorkerError(
                "MODEL_CALL_COUNT_INVALID",
                "Hermes did not make exactly one fenced physical model request.",
            )
        _assert_no_native_tools(agent)
        text = _normalize_direct_response(agent, response)
        output_tokens, usage_reported = _reported_output_tokens(response)
        return {
            "ok": True,
            "text": text,
            "output_tokens": output_tokens,
            "usage_reported": usage_reported,
            "role": request["role"],
            "profile_name": request["profile_name"],
            "model": request["model"],
            "provider": request["provider"],
            "native_tool_count": 0,
            "native_base_prompt_bytes": 0,
            "model_call_count": physical_calls,
            "prepared_input_bytes": len(prepared_input),
            "prepared_input_sha256": prepared_sha256,
        }
    except WorkerError:
        raise
    except Exception as exc:
        # Provider exceptions may contain credentials or response bodies.  Do
        # not forward the exception text across the worker boundary.
        raise WorkerError("HERMES_CALL_FAILED", "The governed Hermes model call failed.") from exc
    finally:
        _close_agent(agent)


def _execute_request(
    raw_request: Any,
    expected_prepare_sha256: str,
    agent_class: Optional[Type[Any]] = None,
) -> Dict[str, Any]:
    """Validate and execute one request; agent_class is injectable for offline tests."""

    request = _validate_request(raw_request)
    _prepare_environment(request)
    selected_class = agent_class if agent_class is not None else _import_agent_class(request)
    return _run_agent(request, selected_class, expected_prepare_sha256)


def _prepare_request(raw_request: Any, agent_class: Optional[Type[Any]] = None) -> Dict[str, Any]:
    """Build the exact immutable system/user input without making a model call."""

    request = _validate_request(raw_request)
    # Preparation is intentionally pure: importing or constructing Hermes here
    # could read/refresh OAuth state before the broker has reserved the exact
    # request budget.  The run phase independently verifies this serialization
    # against the final pre-network kwargs and checks the live tool/client state.
    prepared_input = _logical_prepared_input(request["prompt_text"], request["user_message"])
    return {
        "ok": True,
        "prepared": prepared_input.decode("utf-8"),
        "prepared_input_bytes": len(prepared_input),
        "prepared_input_sha256": hashlib.sha256(prepared_input).hexdigest(),
        "role": request["role"],
        "profile_name": request["profile_name"],
        "model": request["model"],
        "provider": request["provider"],
        "native_tool_count": 0,
        "native_base_prompt_bytes": 0,
        "model_call_count": 0,
    }


def _write_stdout(payload: Mapping[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()


def _install_offline_audit_guard() -> None:
    """Deny network and child processes in check/prepare invocations."""

    def _guard(event: str, _args: Tuple[Any, ...]) -> None:
        if event in {
            "socket.connect",
            "socket.connect_ex",
            "socket.bind",
            "socket.getaddrinfo",
            "subprocess.Popen",
            "os.system",
            "os.posix_spawn",
            "os.posix_spawnp",
        }:
            raise WorkerError(
                "OFFLINE_PREPARE_VIOLATION",
                "Hermes attempted network or subprocess activity during offline preparation.",
            )

    sys.addaudithook(_guard)


def _check_api(raw_request: Any) -> Dict[str, Any]:
    """Import-only compatibility check: no AIAgent construction or model call."""

    request = _validate_request(raw_request)
    _prepare_environment(request)
    agent_class = _import_agent_class(request)
    return {
        "ok": True,
        "compatible": True,
        "check": "import-only",
        "agent_class": agent_class.__name__,
        "role": request["role"],
        "profile_name": request["profile_name"],
        "model_call_count": 0,
    }


def main() -> int:
    try:
        raw = sys.stdin.buffer.read(_MAX_STDIN_BYTES + 1)
        if not raw or len(raw) > _MAX_STDIN_BYTES:
            raise WorkerError("INVALID_REQUEST", "stdin is empty or exceeds the worker size limit.")
        request = _load_json_bytes(raw)
        args = sys.argv[1:]
        mode: str
        expected_prepare_sha256: Optional[str] = None
        if args == ["--check-api"]:
            mode = "check"
        elif args == ["--prepare"]:
            mode = "prepare"
        elif len(args) == 2 and args[0] == "--expected-prepare-sha256" and _SHA256_RE.fullmatch(args[1]):
            mode = "run"
            expected_prepare_sha256 = args[1].lower()
        else:
            raise WorkerError(
                "INVALID_ARGUMENT",
                "Use --check-api, --prepare, or --expected-prepare-sha256 <sha256>.",
            )
        # Reserve stdout exclusively for the worker protocol.  Hermes/library
        # status prints are discarded rather than mixed with the JSON result.
        with contextlib.redirect_stdout(_DiscardText()):
            if mode == "check":
                _install_offline_audit_guard()
                result = _check_api(request)
            elif mode == "prepare":
                _install_offline_audit_guard()
                result = _prepare_request(request)
            else:
                result = _execute_request(request, expected_prepare_sha256 or "")
        _write_stdout(result)
        return 0
    except WorkerError as exc:
        _write_stdout({"ok": False, "error": {"code": exc.code, "message": exc.public_message}})
        return 2
    except Exception:
        _write_stdout(
            {
                "ok": False,
                "error": {
                    "code": "WORKER_INTERNAL_ERROR",
                    "message": "The governed Hermes worker failed safely.",
                },
            }
        )
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
