"""Fail-closed governance for the isolated research-team runtime.

This module is deliberately limited to policy decisions, immutable artifact storage,
and SQLite state.  It does not execute models, Python snippets, shell commands, or
network requests.  A broker must call the methods here before performing any work.
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import re
import sqlite3
import stat
import uuid
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Sequence


ROLE_IDS = ("manager", "researcher", "analyst", "auditor")
WORKER_ROLES = ("researcher", "analyst", "auditor")
SCENARIOS = ("S1", "S2", "S3")
AUDIT_STAGES = ("intermediate", "final")
AUDIT_VERDICTS = ("pass", "reject", "unverifiable")
BROKER_TOOLS = frozenset({"read_text", "write_artifact", "dispatch", "audit", "complete"})
LIMIT_KEYS = (
    "attempts",
    "revisions",
    "audits",
    "seconds",
    "tokens",
    "max_output_tokens",
    "per_call_timeout_seconds",
)
ROLE_KEYS = (
    "profile_name",
    "prompt_path",
    "prompt_sha256",
    "model",
    "provider",
    "allow_model_egress",
    "tools",
    "read_roots",
    "write_roots",
    "call_targets",
    "external_domains",
    "limits",
)
CONFIRMATION_KINDS = frozenset(
    {
        "human_approval",
        "researcher_confirmation",
        "access_verified",
        "exact_version_shared",
        "publication_access_verified",
    }
)
FINAL_CONFIRMATIONS = {
    "S1": ("human_approval", "researcher_confirmation", "access_verified"),
    "S2": ("human_approval", "researcher_confirmation", "access_verified"),
    "S3": (
        "human_approval",
        "researcher_confirmation",
        "exact_version_shared",
        "publication_access_verified",
    ),
}
_HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")
_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_DOMAIN = re.compile(r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")


class PolicyError(RuntimeError):
    """Base policy-engine error."""


class PolicyHold(PolicyError):
    """The operation is held pending explicit configuration or evidence."""


class PolicyViolation(PolicyError):
    """The requested operation violates a configured invariant."""


class BudgetExceeded(PolicyViolation):
    """A request exhausted a configured execution limit and is now failed."""


@dataclass(frozen=True)
class ConfigStatus:
    ready: bool
    pending_reasons: tuple[str, ...]
    errors: tuple[str, ...]

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class ArtifactRef:
    id: str
    version: int
    sha256: str
    task_id: str
    role: str
    scope: str

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class GateDecision:
    status: str
    reasons: tuple[str, ...]
    artifacts: tuple[ArtifactRef, ...]

    @property
    def passed(self) -> bool:
        return self.status == "pass"

    def as_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "reasons": list(self.reasons),
            "artifacts": [item.as_dict() for item in self.artifacts],
        }


def _canonical_json(value: Any) -> str:
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    except (TypeError, ValueError) as exc:
        raise PolicyViolation(f"value is not JSON serializable: {exc}") from exc


def _utc_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _is_reparse(stat_result: os.stat_result) -> bool:
    attributes = getattr(stat_result, "st_file_attributes", 0)
    flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attributes & flag)


def _safe_absolute_path(value: str | os.PathLike[str], *, must_exist: bool = False) -> Path:
    raw = os.fspath(value)
    if not isinstance(raw, str) or not raw.strip():
        raise PolicyViolation("path must be a non-empty string")
    candidate = Path(raw)
    if not candidate.is_absolute():
        raise PolicyViolation(f"path must be absolute: {raw}")
    if any(part == ".." for part in candidate.parts):
        raise PolicyViolation(f"path traversal is not allowed: {raw}")
    if os.name == "nt" and raw.startswith(("\\\\", "//")):
        raise PolicyViolation(f"network paths are not allowed: {raw}")

    absolute = Path(os.path.abspath(raw))
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current = current / part
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or _is_reparse(info):
            raise PolicyViolation(f"symlink or reparse traversal is not allowed: {current}")
    if must_exist and not absolute.exists():
        raise PolicyViolation(f"path does not exist: {absolute}")
    return absolute


def _is_within(path: Path, roots: Iterable[Path]) -> bool:
    for root in roots:
        try:
            if os.path.commonpath((str(path), str(root))) == str(root):
                return True
        except ValueError:
            continue
    return False


def _paths_overlap(first: Path, second: Path) -> bool:
    return _is_within(first, (second,)) or _is_within(second, (first,))


class PolicyEngine:
    """Persistent, fail-closed policy boundary for a four-role research team."""

    _DB_SCHEMA_VERSION = "1"

    def __init__(self, config_path: str | os.PathLike[str], state_path: str | os.PathLike[str]):
        self.config_path = _safe_absolute_path(config_path)
        self.state_path = _safe_absolute_path(state_path)
        if self.config_path == self.state_path:
            raise PolicyViolation("config_path and state_path must be different")
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        _safe_absolute_path(self.state_path.parent, must_exist=True)
        self.artifact_root = self.state_path.parent / f"{self.state_path.stem}.artifacts"
        self.artifact_root.mkdir(parents=False, exist_ok=True)
        _safe_absolute_path(self.artifact_root, must_exist=True)

        self._config: dict[str, Any] = {}
        self._config_digest = ""
        self._load_errors: list[str] = []
        self._load_config()
        self._init_db()

    def _load_config(self) -> None:
        try:
            path = _safe_absolute_path(self.config_path, must_exist=True)
            raw = path.read_bytes()
            loaded = json.loads(raw.decode("utf-8"))
            if not isinstance(loaded, dict):
                self._load_errors.append("config: root must be an object")
                return
            self._config = loaded
            self._config_digest = _sha256_bytes(_canonical_json(loaded).encode("utf-8"))
        except Exception as exc:  # status inspection must not throw for an incomplete template
            self._load_errors.append(f"config: {exc}")

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(str(self.state_path), timeout=30.0)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 30000")
        return connection

    @contextmanager
    def _connection(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    @contextmanager
    def _tx(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _init_db(self) -> None:
        with self._connection() as connection:
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS metadata(
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS requests(
                    id TEXT PRIMARY KEY,
                    scenario TEXT NOT NULL,
                    user_id TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    input_refs_json TEXT NOT NULL,
                    outputs_json TEXT NOT NULL,
                    metadata_json TEXT NOT NULL,
                    policy_hash TEXT NOT NULL,
                    status TEXT NOT NULL,
                    failure_reason TEXT,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS policy_versions(
                    policy_hash TEXT PRIMARY KEY,
                    config_json TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS tasks(
                    id TEXT PRIMARY KEY,
                    request_id TEXT NOT NULL REFERENCES requests(id),
                    actor_role TEXT NOT NULL,
                    target_role TEXT NOT NULL,
                    phase TEXT NOT NULL,
                    audit_stage TEXT,
                    scope TEXT NOT NULL,
                    instructions TEXT NOT NULL,
                    dependencies_json TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS artifacts(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    request_id TEXT NOT NULL REFERENCES requests(id),
                    task_id TEXT NOT NULL REFERENCES tasks(id),
                    role TEXT NOT NULL,
                    name TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    version INTEGER NOT NULL,
                    sha256 TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    storage_name TEXT NOT NULL UNIQUE,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    UNIQUE(request_id, role, name, scope, version)
                );
                CREATE TABLE IF NOT EXISTS audits(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    request_id TEXT NOT NULL REFERENCES requests(id),
                    task_id TEXT NOT NULL REFERENCES tasks(id),
                    role TEXT NOT NULL,
                    artifact_id TEXT NOT NULL,
                    artifact_version INTEGER NOT NULL,
                    artifact_sha256 TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    stage TEXT NOT NULL,
                    verdict TEXT NOT NULL,
                    report TEXT NOT NULL,
                    report_sha256 TEXT NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS confirmations(
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    request_id TEXT NOT NULL REFERENCES requests(id),
                    user_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    artifact_id TEXT NOT NULL,
                    artifact_version INTEGER NOT NULL,
                    artifact_sha256 TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    confirmed INTEGER NOT NULL,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TABLE IF NOT EXISTS budget_usage(
                    request_id TEXT NOT NULL REFERENCES requests(id),
                    role TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    amount INTEGER NOT NULL,
                    PRIMARY KEY(request_id, role, kind)
                );
                CREATE TABLE IF NOT EXISTS budget_reservations(
                    id TEXT PRIMARY KEY,
                    request_id TEXT NOT NULL REFERENCES requests(id),
                    role TEXT NOT NULL,
                    input_bytes INTEGER NOT NULL,
                    output_cap INTEGER NOT NULL,
                    timeout_seconds INTEGER NOT NULL,
                    amounts_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    actual_json TEXT,
                    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
                );
                CREATE TRIGGER IF NOT EXISTS artifacts_no_update
                BEFORE UPDATE ON artifacts BEGIN SELECT RAISE(ABORT, 'artifacts are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS artifacts_no_delete
                BEFORE DELETE ON artifacts BEGIN SELECT RAISE(ABORT, 'artifacts are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS audits_no_update
                BEFORE UPDATE ON audits BEGIN SELECT RAISE(ABORT, 'audits are append-only'); END;
                CREATE TRIGGER IF NOT EXISTS audits_no_delete
                BEFORE DELETE ON audits BEGIN SELECT RAISE(ABORT, 'audits are append-only'); END;
                """
            )
            current = connection.execute("SELECT value FROM metadata WHERE key='schema_version'").fetchone()
            if current is None:
                connection.execute(
                    "INSERT INTO metadata(key,value) VALUES('schema_version',?)",
                    (self._DB_SCHEMA_VERSION,),
                )
            elif current["value"] != self._DB_SCHEMA_VERSION:
                raise PolicyViolation("unsupported policy state schema")

    def read_config(self) -> dict[str, Any]:
        return copy.deepcopy(self._config)

    def validate_config(self, role: str | None = None) -> ConfigStatus:
        errors = list(self._load_errors)
        pending: list[str] = []
        config = self._config

        if role is not None and role not in ROLE_IDS:
            errors.append(f"role: unsupported role {role!r}")
        if not config:
            return ConfigStatus(False, tuple(sorted(set(pending))), tuple(sorted(set(errors))))

        expected_top = {"schema_version", "human", "roles"}
        self._check_keys(config, expected_top, "config", errors)
        if config.get("schema_version") != 1:
            errors.append("config.schema_version: must equal 1")

        human = config.get("human")
        if not isinstance(human, dict):
            errors.append("config.human: must be an object")
        else:
            self._check_keys(human, {"allowed_user_ids"}, "config.human", errors)
            users = human.get("allowed_user_ids")
            if users is None:
                pending.append("config.human.allowed_user_ids: pending")
            elif not self._valid_string_list(users):
                errors.append("config.human.allowed_user_ids: must be a unique string array")

        roles = config.get("roles")
        if not isinstance(roles, dict):
            errors.append("config.roles: must be an object")
        else:
            role_names = set(roles)
            if role_names != set(ROLE_IDS):
                errors.append("config.roles: must contain exactly manager,researcher,analyst,auditor")
            selected = ROLE_IDS if role is None else (role,)
            profile_names: list[str] = []
            for role_id in selected:
                value = roles.get(role_id)
                if not isinstance(value, dict):
                    errors.append(f"config.roles.{role_id}: must be an object")
                    continue
                self._validate_role(role_id, value, pending, errors)
                if isinstance(value.get("profile_name"), str):
                    profile_names.append(value["profile_name"])
            if role is None and len(profile_names) != len(set(profile_names)):
                errors.append("config.roles: profile_name values must be unique")
            self._validate_role_root_separation(roles, errors, selected)

        return ConfigStatus(not errors and not pending, tuple(sorted(set(pending))), tuple(sorted(set(errors))))

    @staticmethod
    def _check_keys(value: Mapping[str, Any], expected: set[str], label: str, errors: list[str]) -> None:
        missing = expected - set(value)
        extra = set(value) - expected
        for key in sorted(missing):
            errors.append(f"{label}.{key}: required field is missing")
        for key in sorted(extra):
            errors.append(f"{label}.{key}: unknown field")

    @staticmethod
    def _valid_string_list(value: Any) -> bool:
        return (
            isinstance(value, list)
            and all(isinstance(item, str) and bool(item.strip()) for item in value)
            and len(value) == len(set(value))
        )

    def _validate_role(
        self, role_id: str, value: Mapping[str, Any], pending: list[str], errors: list[str]
    ) -> None:
        label = f"config.roles.{role_id}"
        self._check_keys(value, set(ROLE_KEYS), label, errors)
        for field in ROLE_KEYS:
            if field in value and value[field] is None:
                pending.append(f"{label}.{field}: pending")

        profile = value.get("profile_name")
        if profile is not None and (not isinstance(profile, str) or not _NAME.fullmatch(profile)):
            errors.append(f"{label}.profile_name: invalid")
        for field in ("model", "provider"):
            item = value.get(field)
            if item is not None and (not isinstance(item, str) or not item.strip()):
                errors.append(f"{label}.{field}: must be a non-empty string")
        egress = value.get("allow_model_egress")
        if egress is not None and not isinstance(egress, bool):
            errors.append(f"{label}.allow_model_egress: must be boolean or null")

        prompt_path = value.get("prompt_path")
        prompt_hash = value.get("prompt_sha256")
        if prompt_hash is not None and (not isinstance(prompt_hash, str) or not _HEX64.fullmatch(prompt_hash)):
            errors.append(f"{label}.prompt_sha256: must be a SHA-256 hex digest")
        if prompt_path is not None:
            if not isinstance(prompt_path, str):
                errors.append(f"{label}.prompt_path: must be an absolute string path")
            else:
                try:
                    checked = _safe_absolute_path(prompt_path, must_exist=True)
                    if not checked.is_file():
                        raise PolicyViolation("prompt path is not a file")
                    if isinstance(prompt_hash, str) and _HEX64.fullmatch(prompt_hash):
                        actual = _sha256_bytes(checked.read_bytes())
                        if actual.lower() != prompt_hash.lower():
                            errors.append(f"{label}.prompt_sha256: prompt digest mismatch")
                except PolicyViolation as exc:
                    errors.append(f"{label}.prompt_path: {exc}")

        tools = value.get("tools")
        if tools is not None:
            if not self._valid_string_list(tools):
                errors.append(f"{label}.tools: must be a unique string array")
            else:
                unsupported = sorted(set(tools) - BROKER_TOOLS)
                if unsupported:
                    errors.append(f"{label}.tools: unsupported broker tools {unsupported}")
                if role_id != "manager" and "dispatch" in tools:
                    errors.append(f"{label}.tools: workers cannot dispatch")
                if role_id == "auditor" and "write_artifact" in tools:
                    errors.append(f"{label}.tools: auditor cannot alter original artifacts")

        for field in ("read_roots", "write_roots"):
            roots = value.get(field)
            if roots is None:
                continue
            if not self._valid_string_list(roots):
                errors.append(f"{label}.{field}: must be a unique string array")
                continue
            for root in roots:
                try:
                    _safe_absolute_path(root)
                except PolicyViolation as exc:
                    errors.append(f"{label}.{field}: {exc}")
        write_roots = value.get("write_roots")
        if isinstance(write_roots, list):
            expected_write_root = self.artifact_root / role_id
            try:
                normalized = {_safe_absolute_path(root) for root in write_roots}
                if normalized != {expected_write_root}:
                    errors.append(
                        f"{label}.write_roots: must contain only the controlled role artifact root {expected_write_root}"
                    )
            except PolicyViolation:
                pass

        targets = value.get("call_targets")
        if targets is not None:
            if not self._valid_string_list(targets) and targets != []:
                errors.append(f"{label}.call_targets: must be a unique role array")
            elif any(target not in WORKER_ROLES for target in targets):
                errors.append(f"{label}.call_targets: contains a non-worker role")
            elif role_id != "manager" and targets:
                errors.append(f"{label}.call_targets: workers cannot delegate")

        domains = value.get("external_domains")
        if domains is not None:
            if not self._valid_string_list(domains) and domains != []:
                errors.append(f"{label}.external_domains: must be a unique domain array")
            elif any(not _DOMAIN.fullmatch(item.lower()) for item in domains):
                errors.append(f"{label}.external_domains: contains an invalid exact domain")

        limits = value.get("limits")
        if limits is not None:
            if not isinstance(limits, dict):
                errors.append(f"{label}.limits: must be an object")
            else:
                self._check_keys(limits, set(LIMIT_KEYS), f"{label}.limits", errors)
                for key in LIMIT_KEYS:
                    amount = limits.get(key)
                    if amount is None:
                        pending.append(f"{label}.limits.{key}: pending")
                    elif isinstance(amount, bool) or not isinstance(amount, int) or amount < 0:
                        errors.append(f"{label}.limits.{key}: must be a non-negative integer or null")

    def _validate_role_root_separation(
        self,
        roles: Mapping[str, Any],
        errors: list[str],
        selected: Sequence[str],
    ) -> None:
        protected: list[Path] = [self.config_path, self.state_path, self.artifact_root]
        for role_id in ROLE_IDS:
            value = roles.get(role_id)
            if not isinstance(value, dict):
                continue
            prompt = value.get("prompt_path")
            if isinstance(prompt, str):
                try:
                    protected.append(_safe_absolute_path(prompt))
                except PolicyViolation:
                    pass
            roots = value.get("write_roots")
            if isinstance(roots, list):
                for root in roots:
                    if isinstance(root, str):
                        try:
                            protected.append(_safe_absolute_path(root))
                        except PolicyViolation:
                            pass
        for role_id in selected:
            value = roles.get(role_id)
            if not isinstance(value, dict) or not isinstance(value.get("read_roots"), list):
                continue
            for raw_root in value["read_roots"]:
                if not isinstance(raw_root, str):
                    continue
                try:
                    read_root = _safe_absolute_path(raw_root)
                except PolicyViolation:
                    continue
                if any(_paths_overlap(read_root, item) for item in protected):
                    errors.append(
                        f"config.roles.{role_id}.read_roots: overlaps protected policy, prompt, state, or artifact storage"
                    )

    def require_ready(self, role: str | None = None) -> dict[str, Any]:
        status = self.validate_config(role)
        if status.errors:
            raise PolicyViolation("invalid policy config: " + "; ".join(status.errors))
        if status.pending_reasons:
            raise PolicyHold("policy config is pending: " + "; ".join(status.pending_reasons))
        if role is None:
            return self.read_config()
        return copy.deepcopy(self._config["roles"][role])

    def _bind_policy(self, connection: sqlite3.Connection) -> None:
        connection.execute(
            "INSERT OR IGNORE INTO policy_versions(policy_hash,config_json) VALUES(?,?)",
            (self._config_digest, _canonical_json(self._config)),
        )

    def _allowed_users(self) -> tuple[str, ...]:
        users = self._config["human"]["allowed_user_ids"]
        return tuple(users)

    def _require_user(self, user_id: str) -> None:
        if not isinstance(user_id, str) or user_id not in self._allowed_users():
            raise PolicyViolation("human user is not in allowed_user_ids")

    def create_request(
        self,
        scenario: str,
        *,
        user_id: str,
        scope: str,
        input_refs: Sequence[Mapping[str, Any]],
        outputs: Sequence[str],
        metadata: Mapping[str, Any] | None = None,
    ) -> str:
        self.require_ready()
        self._require_user(user_id)
        if scenario not in SCENARIOS:
            raise PolicyViolation("scenario must be S1, S2, or S3")
        self._require_scope(scope)
        if not isinstance(input_refs, (list, tuple)):
            raise PolicyViolation("input_refs must be an explicit array")
        if (
            not isinstance(outputs, (list, tuple))
            or not outputs
            or not self._valid_string_list(list(outputs))
        ):
            raise PolicyViolation("outputs must be a non-empty unique string array")
        if metadata is not None and not isinstance(metadata, Mapping):
            raise PolicyViolation("metadata must be an object when supplied")
        request_id = _utc_id("req")
        with self._tx() as connection:
            self._bind_policy(connection)
            connection.execute(
                """INSERT INTO requests(
                    id,scenario,user_id,scope,input_refs_json,outputs_json,metadata_json,policy_hash,status
                ) VALUES(?,?,?,?,?,?,?,?, 'active')""",
                (
                    request_id,
                    scenario,
                    user_id,
                    scope,
                    _canonical_json(list(input_refs)),
                    _canonical_json(list(outputs)),
                    _canonical_json(dict(metadata or {})),
                    self._config_digest,
                ),
            )
        return request_id

    @staticmethod
    def _require_scope(scope: str) -> None:
        if not isinstance(scope, str) or not scope.strip() or len(scope) > 256:
            raise PolicyViolation("scope must be a non-empty string of at most 256 characters")

    def _request_row(self, connection: sqlite3.Connection, request_id: str) -> sqlite3.Row:
        row = connection.execute("SELECT * FROM requests WHERE id=?", (request_id,)).fetchone()
        if row is None:
            raise PolicyViolation("request does not exist")
        if row["policy_hash"] != self._config_digest:
            raise PolicyHold("request is bound to a different policy hash")
        if row["status"] != "active":
            raise PolicyViolation(f"request is not active: {row['status']}")
        return row

    def _coerce_ref(self, value: ArtifactRef | Mapping[str, Any]) -> ArtifactRef:
        if isinstance(value, ArtifactRef):
            return value
        if not isinstance(value, Mapping):
            raise PolicyViolation("artifact reference must be an ArtifactRef or mapping")
        expected = {"id", "version", "sha256", "task_id", "role", "scope"}
        if set(value) != expected:
            raise PolicyViolation("artifact reference fields are not exact")
        try:
            return ArtifactRef(
                id=str(value["id"]),
                version=int(value["version"]),
                sha256=str(value["sha256"]),
                task_id=str(value["task_id"]),
                role=str(value["role"]),
                scope=str(value["scope"]),
            )
        except (TypeError, ValueError) as exc:
            raise PolicyViolation("artifact reference is malformed") from exc

    def _artifact_row(
        self, connection: sqlite3.Connection, ref: ArtifactRef, *, require_latest: bool
    ) -> sqlite3.Row:
        row = connection.execute("SELECT * FROM artifacts WHERE id=?", (ref.id,)).fetchone()
        if row is None:
            raise PolicyViolation("artifact reference does not exist")
        fields = (
            int(row["version"]) == ref.version,
            row["sha256"] == ref.sha256.lower(),
            row["task_id"] == ref.task_id,
            row["role"] == ref.role,
            row["scope"] == ref.scope,
        )
        if not all(fields):
            raise PolicyViolation("artifact reference does not exactly match persisted evidence")
        if require_latest:
            latest = connection.execute(
                """SELECT id FROM artifacts
                   WHERE request_id=? AND role=? AND name=? AND scope=?
                   ORDER BY version DESC LIMIT 1""",
                (row["request_id"], row["role"], row["name"], row["scope"]),
            ).fetchone()
            if latest is None or latest["id"] != row["id"]:
                raise PolicyHold("artifact reference is not the current immutable version")
        return row

    def assign_task(
        self,
        request_id: str,
        *,
        actor_role: str,
        target_role: str,
        scope: str,
        instructions: str,
        dependencies: Sequence[ArtifactRef | Mapping[str, Any]] = (),
        phase: str = "main",
        audit_stage: str | None = None,
    ) -> str:
        self.require_ready("manager")
        if actor_role != "manager":
            raise PolicyViolation("only the manager may dispatch tasks")
        if target_role not in ROLE_IDS:
            raise PolicyViolation("manager may dispatch only canonical roles")
        manager = self._config["roles"]["manager"]
        manager_root_task = target_role == "manager" and phase == "prepare"
        if "dispatch" not in manager["tools"] or (
            not manager_root_task and target_role not in manager["call_targets"]
        ):
            raise PolicyViolation("manager is not configured to dispatch this target role")
        self.require_ready(target_role)
        self._require_scope(scope)
        if not isinstance(instructions, str) or not instructions.strip():
            raise PolicyViolation("task instructions must be non-empty")
        if phase not in ("main", "prepare", "audit"):
            raise PolicyViolation("task phase must be main, prepare, or audit")

        refs = tuple(self._coerce_ref(item) for item in dependencies)
        task_id = _utc_id("task")
        with self._tx() as connection:
            request = self._request_row(connection, request_id)
            if request["scope"] != scope:
                raise PolicyViolation("task scope must exactly match its request scope")
            rows = [self._artifact_row(connection, ref, require_latest=True) for ref in refs]
            if any(row["request_id"] != request_id for row in rows):
                raise PolicyViolation("task dependency belongs to another request")
            if any(row["scope"] != scope for row in rows):
                raise PolicyViolation("task dependency scope does not match task scope")

            if target_role == "researcher" and phase != "main":
                raise PolicyViolation("researcher tasks must use the main phase")
            if target_role == "manager" and not manager_root_task:
                raise PolicyViolation("manager self-tasks are limited to the prepare root/integration phase")
            if target_role == "manager" and refs:
                dependency_roles = {row["role"] for row in rows}
                if dependency_roles != {"researcher", "analyst"}:
                    raise PolicyViolation(
                        "manager integration requires current researcher and analyst artifacts"
                    )
                for row in rows:
                    if not self._audit_passes(connection, row, "intermediate"):
                        raise PolicyHold(
                            "manager integration waits for exact worker intermediate audit passes"
                        )
            if target_role == "analyst":
                if phase == "prepare":
                    if request["scenario"] != "S2" or refs:
                        raise PolicyViolation("only S2 permits a dependency-free read-only analyst prepare task")
                elif phase == "main":
                    if not rows or any(row["role"] != "researcher" for row in rows):
                        raise PolicyViolation("analyst main task requires current researcher artifacts")
                    for row in rows:
                        if not self._audit_passes(connection, row, "intermediate"):
                            raise PolicyHold("analyst task waits for an exact intermediate audit pass")
                else:
                    raise PolicyViolation("analyst task phase is not allowed")
            if target_role == "auditor":
                if phase != "audit" or not rows or audit_stage not in AUDIT_STAGES:
                    raise PolicyViolation(
                        "auditor tasks require audit phase, an explicit audit_stage, and exact artifact dependencies"
                    )
            elif audit_stage is not None:
                raise PolicyViolation("audit_stage is allowed only for auditor tasks")

            connection.execute(
                """INSERT INTO tasks(
                    id,request_id,actor_role,target_role,phase,audit_stage,scope,instructions,dependencies_json
                ) VALUES(?,?,?,?,?,?,?,?,?)""",
                (
                    task_id,
                    request_id,
                    actor_role,
                    target_role,
                    phase,
                    audit_stage,
                    scope,
                    instructions,
                    _canonical_json([ref.as_dict() for ref in refs]),
                ),
            )
        return task_id

    def _role_limit(self, role: str, kind: str) -> int:
        self.require_ready(role)
        value = self._config["roles"][role]["limits"][kind]
        if value is None:
            raise PolicyHold(f"{role}.{kind} is pending")
        return int(value)

    @staticmethod
    def _usage(connection: sqlite3.Connection, request_id: str, role: str, kind: str) -> int:
        row = connection.execute(
            "SELECT amount FROM budget_usage WHERE request_id=? AND role=? AND kind=?",
            (request_id, role, kind),
        ).fetchone()
        return 0 if row is None else int(row["amount"])

    @staticmethod
    def _reserved(connection: sqlite3.Connection, request_id: str, role: str, kind: str) -> int:
        rows = connection.execute(
            "SELECT amounts_json FROM budget_reservations WHERE request_id=? AND role=? AND status='reserved'",
            (request_id, role),
        ).fetchall()
        return sum(int(json.loads(row["amounts_json"]).get(kind, 0)) for row in rows)

    @staticmethod
    def _add_usage(
        connection: sqlite3.Connection, request_id: str, role: str, kind: str, amount: int
    ) -> None:
        connection.execute(
            """INSERT INTO budget_usage(request_id,role,kind,amount) VALUES(?,?,?,?)
               ON CONFLICT(request_id,role,kind) DO UPDATE SET amount=amount+excluded.amount""",
            (request_id, role, kind, amount),
        )

    def _fail_budget(
        self, connection: sqlite3.Connection, request_id: str, reason: str
    ) -> None:
        connection.execute(
            "UPDATE requests SET status='failed', failure_reason=? WHERE id=?", (reason, request_id)
        )
        connection.commit()
        raise BudgetExceeded(reason)

    def _charge_direct(
        self, connection: sqlite3.Connection, request_id: str, role: str, kind: str, amount: int
    ) -> None:
        limit = self._role_limit(role, kind)
        used = self._usage(connection, request_id, role, kind)
        reserved = self._reserved(connection, request_id, role, kind)
        if used + reserved + amount > limit:
            self._fail_budget(connection, request_id, f"{role}.{kind} budget exhausted")
        self._add_usage(connection, request_id, role, kind, amount)

    def reserve_budget(
        self,
        request_id: str,
        role: str,
        *,
        input_text: str,
        max_output_tokens: int | None = None,
        timeout_seconds: int | None = None,
    ) -> str:
        role_config = self.require_ready(role)
        if role_config["allow_model_egress"] is not True:
            raise PolicyHold(f"{role} model egress is not explicitly allowed")
        if not isinstance(input_text, str):
            raise PolicyViolation("input_text must be a string")
        configured_output = int(role_config["limits"]["max_output_tokens"])
        configured_timeout = int(role_config["limits"]["per_call_timeout_seconds"])
        output_cap = configured_output if max_output_tokens is None else max_output_tokens
        timeout = configured_timeout if timeout_seconds is None else timeout_seconds
        if isinstance(output_cap, bool) or not isinstance(output_cap, int) or output_cap < 0:
            raise PolicyViolation("max_output_tokens must be a non-negative integer")
        if isinstance(timeout, bool) or not isinstance(timeout, int) or timeout < 0:
            raise PolicyViolation("timeout_seconds must be a non-negative integer")
        if output_cap > configured_output or timeout > configured_timeout:
            raise PolicyViolation("call cap exceeds the explicit per-call role limit")

        input_bytes = len(input_text.encode("utf-8"))
        amounts = {"attempts": 1, "tokens": input_bytes + output_cap, "seconds": timeout}
        reservation_id = _utc_id("budget")
        with self._tx() as connection:
            self._request_row(connection, request_id)
            for kind, amount in amounts.items():
                limit = self._role_limit(role, kind)
                used = self._usage(connection, request_id, role, kind)
                reserved = self._reserved(connection, request_id, role, kind)
                if used + reserved + amount > limit:
                    self._fail_budget(connection, request_id, f"{role}.{kind} budget exhausted")
            connection.execute(
                """INSERT INTO budget_reservations(
                    id,request_id,role,input_bytes,output_cap,timeout_seconds,amounts_json,status
                ) VALUES(?,?,?,?,?,?,?,'reserved')""",
                (
                    reservation_id,
                    request_id,
                    role,
                    input_bytes,
                    output_cap,
                    timeout,
                    _canonical_json(amounts),
                ),
            )
        return reservation_id

    def consume_budget(
        self, reservation_id: str, *, actual_output_tokens: int | None, elapsed_seconds: float
    ) -> dict[str, int]:
        if actual_output_tokens is not None and (
            isinstance(actual_output_tokens, bool)
            or not isinstance(actual_output_tokens, int)
            or actual_output_tokens < 0
        ):
            raise PolicyViolation("actual_output_tokens must be a non-negative integer")
        if isinstance(elapsed_seconds, bool) or not isinstance(elapsed_seconds, (int, float)) or elapsed_seconds < 0:
            raise PolicyViolation("elapsed_seconds must be non-negative")
        with self._tx() as connection:
            row = connection.execute(
                "SELECT * FROM budget_reservations WHERE id=?", (reservation_id,)
            ).fetchone()
            if row is None or row["status"] != "reserved":
                raise PolicyViolation("budget reservation is missing or no longer active")
            self._request_row(connection, row["request_id"])
            elapsed = int(math.ceil(float(elapsed_seconds)))
            charged_output = int(row["output_cap"]) if actual_output_tokens is None else actual_output_tokens
            if charged_output > int(row["output_cap"]) or elapsed > int(row["timeout_seconds"]):
                self._fail_budget(connection, row["request_id"], "reserved call budget was exceeded")
            actual = {
                "attempts": 1,
                "tokens": int(row["input_bytes"]) + charged_output,
                "seconds": elapsed,
            }
            for kind, amount in actual.items():
                self._add_usage(connection, row["request_id"], row["role"], kind, amount)
            connection.execute(
                "UPDATE budget_reservations SET status='consumed',actual_json=? WHERE id=?",
                (_canonical_json(actual), reservation_id),
            )
        return actual

    def release_budget(self, reservation_id: str) -> None:
        with self._tx() as connection:
            row = connection.execute(
                "SELECT status FROM budget_reservations WHERE id=?", (reservation_id,)
            ).fetchone()
            if row is None or row["status"] != "reserved":
                raise PolicyViolation("budget reservation is missing or no longer active")
            connection.execute(
                "UPDATE budget_reservations SET status='released' WHERE id=?", (reservation_id,)
            )

    def record_artifact(
        self,
        request_id: str,
        task_id: str,
        *,
        role: str,
        name: str,
        scope: str,
        content: bytes | str,
        expected_sha256: str | None = None,
    ) -> ArtifactRef:
        role_config = self.require_ready(role)
        if role == "auditor":
            raise PolicyViolation("auditor cannot alter or replace original artifacts")
        if "write_artifact" not in role_config["tools"]:
            raise PolicyViolation("role is not allowed to write governed artifacts")
        if not _NAME.fullmatch(name):
            raise PolicyViolation("artifact name is invalid")
        self._require_scope(scope)
        if isinstance(content, str):
            payload = content.encode("utf-8")
        elif isinstance(content, bytes):
            payload = content
        else:
            raise PolicyViolation("artifact content must be bytes or text")
        digest = _sha256_bytes(payload)
        if expected_sha256 is not None and (
            not _HEX64.fullmatch(expected_sha256) or expected_sha256.lower() != digest
        ):
            raise PolicyViolation("artifact expected_sha256 does not match exact content")

        artifact_id = _utc_id("artifact")
        role_root = self.artifact_root / role
        configured_roots = tuple(_safe_absolute_path(item) for item in role_config["write_roots"])
        if configured_roots != (role_root,):
            raise PolicyViolation("role artifact storage is not the exact controlled write root")
        role_root.mkdir(parents=False, exist_ok=True)
        _safe_absolute_path(role_root, must_exist=True)
        storage_name = f"{role}/{artifact_id}.blob"
        storage_path = role_root / f"{artifact_id}.blob"
        wrote_file = False
        try:
            with self._tx() as connection:
                self._request_row(connection, request_id)
                task = connection.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
                if task is None or task["request_id"] != request_id:
                    raise PolicyViolation("artifact task does not belong to request")
                if task["target_role"] != role or task["scope"] != scope:
                    raise PolicyViolation("artifact role or scope does not match its task")
                if task["phase"] == "prepare" and role == "analyst":
                    raise PolicyViolation("read-only prepare tasks cannot emit artifacts")
                latest = connection.execute(
                    """SELECT MAX(version) AS version FROM artifacts
                       WHERE request_id=? AND role=? AND name=? AND scope=?""",
                    (request_id, role, name, scope),
                ).fetchone()
                version = 1 if latest["version"] is None else int(latest["version"]) + 1
                if version > 1:
                    self._charge_direct(connection, request_id, role, "revisions", 1)

                _safe_absolute_path(self.artifact_root, must_exist=True)
                with storage_path.open("xb") as handle:
                    handle.write(payload)
                    handle.flush()
                    os.fsync(handle.fileno())
                wrote_file = True
                try:
                    storage_path.chmod(stat.S_IREAD)
                except OSError:
                    pass
                connection.execute(
                    """INSERT INTO artifacts(
                        id,request_id,task_id,role,name,scope,version,sha256,size_bytes,storage_name
                    ) VALUES(?,?,?,?,?,?,?,?,?,?)""",
                    (
                        artifact_id,
                        request_id,
                        task_id,
                        role,
                        name,
                        scope,
                        version,
                        digest,
                        len(payload),
                        storage_name,
                    ),
                )
        except Exception:
            if wrote_file and storage_path.exists():
                try:
                    storage_path.chmod(stat.S_IWRITE | stat.S_IREAD)
                    storage_path.unlink()
                except OSError:
                    pass
            raise
        return ArtifactRef(artifact_id, version, digest, task_id, role, scope)

    def _audit_passes(self, connection: sqlite3.Connection, artifact: sqlite3.Row, stage: str) -> bool:
        row = connection.execute(
            """SELECT verdict FROM audits
               WHERE artifact_id=? AND artifact_version=? AND artifact_sha256=?
                 AND scope=? AND stage=?
               ORDER BY sequence DESC LIMIT 1""",
            (
                artifact["id"],
                artifact["version"],
                artifact["sha256"],
                artifact["scope"],
                stage,
            ),
        ).fetchone()
        return row is not None and row["verdict"] == "pass"

    def record_audit(
        self,
        request_id: str,
        task_id: str,
        *,
        role: str,
        artifact_ref: ArtifactRef | Mapping[str, Any],
        stage: str,
        verdict: str,
        scope: str,
        notes: str = "",
    ) -> str:
        role_config = self.require_ready(role)
        if role != "auditor" or "audit" not in role_config["tools"]:
            raise PolicyViolation("only the configured auditor may record audits")
        if stage not in AUDIT_STAGES or verdict not in AUDIT_VERDICTS:
            raise PolicyViolation("audit stage or verdict is invalid")
        if not isinstance(notes, str):
            raise PolicyViolation("audit report must be text")
        ref = self._coerce_ref(artifact_ref)
        if scope != ref.scope:
            raise PolicyViolation("audit scope must exactly match artifact scope")
        audit_id = _utc_id("audit")
        with self._tx() as connection:
            request = self._request_row(connection, request_id)
            if request["scenario"] == "S2" and stage == "final" and verdict == "pass":
                raise PolicyHold(
                    "S2 final pass is held: independent numeric verifier is not connected"
                )
            artifact = self._artifact_row(connection, ref, require_latest=False)
            if artifact["request_id"] != request_id:
                raise PolicyViolation("audit artifact belongs to another request")
            task = connection.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
            if task is None or task["request_id"] != request_id or task["target_role"] != "auditor":
                raise PolicyViolation("audit task is not a request auditor task")
            if task["audit_stage"] != stage:
                raise PolicyViolation("audit stage was not authorized by the assigned auditor task")
            dependencies = json.loads(task["dependencies_json"])
            if ref.as_dict() not in dependencies:
                raise PolicyViolation("auditor task was not assigned this exact artifact")
            self._charge_direct(connection, request_id, role, "audits", 1)
            connection.execute(
                """INSERT INTO audits(
                    id,request_id,task_id,role,artifact_id,artifact_version,artifact_sha256,
                    scope,stage,verdict,report,report_sha256
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    audit_id,
                    request_id,
                    task_id,
                    role,
                    ref.id,
                    ref.version,
                    ref.sha256.lower(),
                    scope,
                    stage,
                    verdict,
                    notes,
                    _sha256_bytes(notes.encode("utf-8")),
                ),
            )
        return audit_id

    def record_confirmation(
        self,
        request_id: str,
        *,
        user_id: str,
        kind: str,
        artifact_ref: ArtifactRef | Mapping[str, Any],
        scope: str,
        confirmed: bool = True,
    ) -> str:
        self.require_ready()
        self._require_user(user_id)
        if kind not in CONFIRMATION_KINDS:
            raise PolicyViolation("unsupported confirmation kind")
        if not isinstance(confirmed, bool):
            raise PolicyViolation("confirmed must be boolean")
        ref = self._coerce_ref(artifact_ref)
        if scope != ref.scope:
            raise PolicyViolation("confirmation scope must exactly match artifact scope")
        confirmation_id = _utc_id("confirm")
        with self._tx() as connection:
            self._request_row(connection, request_id)
            artifact = self._artifact_row(connection, ref, require_latest=True)
            if artifact["request_id"] != request_id:
                raise PolicyViolation("confirmation artifact belongs to another request")
            connection.execute(
                """INSERT INTO confirmations(
                    id,request_id,user_id,kind,artifact_id,artifact_version,artifact_sha256,scope,confirmed
                ) VALUES(?,?,?,?,?,?,?,?,?)""",
                (
                    confirmation_id,
                    request_id,
                    user_id,
                    kind,
                    ref.id,
                    ref.version,
                    ref.sha256.lower(),
                    scope,
                    1 if confirmed else 0,
                ),
            )
        return confirmation_id

    @staticmethod
    def _confirmation_passes(
        connection: sqlite3.Connection, artifact: sqlite3.Row, kind: str
    ) -> bool:
        row = connection.execute(
            """SELECT confirmed FROM confirmations
               WHERE artifact_id=? AND artifact_version=? AND artifact_sha256=? AND scope=? AND kind=?
               ORDER BY sequence DESC LIMIT 1""",
            (
                artifact["id"],
                artifact["version"],
                artifact["sha256"],
                artifact["scope"],
                kind,
            ),
        ).fetchone()
        return row is not None and bool(row["confirmed"])

    def _current_dependency_rows(
        self, connection: sqlite3.Connection, artifact: sqlite3.Row
    ) -> tuple[sqlite3.Row, ...] | None:
        task = connection.execute("SELECT dependencies_json FROM tasks WHERE id=?", (artifact["task_id"],)).fetchone()
        if task is None:
            return None
        rows: list[sqlite3.Row] = []
        for raw in json.loads(task["dependencies_json"]):
            try:
                rows.append(
                    self._artifact_row(connection, self._coerce_ref(raw), require_latest=True)
                )
            except PolicyError:
                return None
        return tuple(rows)

    def _dependencies_current(self, connection: sqlite3.Connection, artifact: sqlite3.Row) -> bool:
        return self._current_dependency_rows(connection, artifact) is not None

    def _is_manager_integration(
        self, connection: sqlite3.Connection, artifact: sqlite3.Row
    ) -> bool:
        dependencies = self._current_dependency_rows(connection, artifact)
        return (
            dependencies is not None
            and {row["role"] for row in dependencies} == {"researcher", "analyst"}
            and all(self._audit_passes(connection, row, "intermediate") for row in dependencies)
        )

    def gate(self, request_id: str, *, stage: str, scope: str) -> GateDecision:
        if stage not in AUDIT_STAGES:
            raise PolicyViolation("gate stage must be intermediate or final")
        self._require_scope(scope)
        status = self.validate_config()
        if not status.ready:
            reasons = status.errors + status.pending_reasons
            return GateDecision("hold", tuple(reasons), ())
        with self._connection() as connection:
            request = connection.execute("SELECT * FROM requests WHERE id=?", (request_id,)).fetchone()
            if request is None:
                raise PolicyViolation("request does not exist")
            if request["scope"] != scope:
                raise PolicyViolation("gate scope must exactly match its request scope")
            if request["policy_hash"] != self._config_digest:
                return GateDecision("hold", ("request policy hash changed",), ())
            if request["status"] == "failed":
                return GateDecision("failed", (str(request["failure_reason"]),), ())
            role_clause = " AND role='researcher'" if stage == "intermediate" else ""
            rows = connection.execute(
                """SELECT a.* FROM artifacts a
                   JOIN (
                     SELECT request_id,role,name,scope,MAX(version) AS version
                     FROM artifacts WHERE request_id=? AND scope=?"""
                + role_clause
                + """
                     GROUP BY request_id,role,name,scope
                   ) latest
                   ON a.request_id=latest.request_id AND a.role=latest.role
                    AND a.name=latest.name AND a.scope=latest.scope AND a.version=latest.version
                   ORDER BY a.sequence""",
                (request_id, scope),
            ).fetchall()
            if not rows:
                return GateDecision("hold", ("no current artifacts for scope",), ())

            refs = tuple(self._row_ref(row) for row in rows)
            reasons: list[str] = []
            if stage == "final":
                present_roles = {row["role"] for row in rows}
                for required_role in ("researcher", "analyst", "manager"):
                    if required_role not in present_roles:
                        reasons.append(f"missing current {required_role} output")
                if not any(
                    row["role"] == "manager" and self._is_manager_integration(connection, row)
                    for row in rows
                ):
                    reasons.append("missing current manager integration output")
            for row in rows:
                label = f"{row['role']}:{row['name']}:v{row['version']}"
                if not self._dependencies_current(connection, row):
                    reasons.append(f"{label}: dependency version changed")
                stages = ("intermediate",) if stage == "intermediate" else AUDIT_STAGES
                for required_stage in stages:
                    if not self._audit_passes(connection, row, required_stage):
                        reasons.append(f"{label}: missing current {required_stage} audit pass")
                if stage == "final":
                    for kind in FINAL_CONFIRMATIONS.get(request["scenario"], ()):
                        if not self._confirmation_passes(connection, row, kind):
                            reasons.append(f"{label}: missing current {kind}")
            return GateDecision("pass" if not reasons else "hold", tuple(reasons), refs)

    @staticmethod
    def _row_ref(row: sqlite3.Row) -> ArtifactRef:
        return ArtifactRef(
            id=row["id"],
            version=int(row["version"]),
            sha256=row["sha256"],
            task_id=row["task_id"],
            role=row["role"],
            scope=row["scope"],
        )

    def get_request(self, request_id: str) -> dict[str, Any]:
        with self._connection() as connection:
            row = connection.execute("SELECT * FROM requests WHERE id=?", (request_id,)).fetchone()
            if row is None:
                raise PolicyViolation("request does not exist")
            result = dict(row)
            for key in ("input_refs_json", "outputs_json", "metadata_json"):
                result[key[:-5]] = json.loads(result.pop(key))
            return result

    def get_task(self, task_id: str) -> dict[str, Any]:
        with self._connection() as connection:
            row = connection.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
            if row is None:
                raise PolicyViolation("task does not exist")
            result = dict(row)
            result["dependencies"] = json.loads(result.pop("dependencies_json"))
            return result

    def list_audit_records(self, request_id: str, *, role: str) -> list[dict[str, Any]]:
        """Request-isolated prior issues/evidence for revision and re-review."""
        selected = self.require_ready(role)
        if "read_text" not in selected["tools"]:
            raise PolicyViolation("role cannot read request audit records")
        with self._connection() as connection:
            self._request_row(connection, request_id)
            rows = connection.execute(
                "SELECT id,task_id,artifact_id,artifact_version,artifact_sha256,scope,stage,verdict,report,report_sha256 FROM audits WHERE request_id=? ORDER BY sequence",
                (request_id,),
            ).fetchall()
            return [dict(row) for row in rows]

    def audit_history_inputs(self, request_id: str, task_id: str) -> list[dict[str, Any]]:
        """Give the assigned auditor immutable prior versions, never edit access."""
        selected = self.require_ready("auditor")
        if "read_text" not in selected["tools"]:
            raise PolicyViolation("auditor cannot read revision history")
        with self._connection() as connection:
            self._request_row(connection, request_id)
            task = connection.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
            if task is None or task["request_id"] != request_id or task["target_role"] != "auditor":
                raise PolicyViolation("revision history requires an assigned auditor task")
            history = []
            for raw_ref in json.loads(task["dependencies_json"]):
                current = self._artifact_row(connection, self._coerce_ref(raw_ref), require_latest=True)
                rows = connection.execute(
                    "SELECT * FROM artifacts WHERE request_id=? AND role=? AND name=? AND scope=? AND version<? ORDER BY version",
                    (request_id, current["role"], current["name"], current["scope"], current["version"]),
                ).fetchall()
                for row in rows:
                    path = _safe_absolute_path(self.artifact_root / row["storage_name"], must_exist=True)
                    if path.parent != self.artifact_root / row["role"]:
                        raise PolicyViolation("revision history escaped its immutable role root")
                    data = path.read_bytes()
                    if _sha256_bytes(data) != row["sha256"]:
                        raise PolicyViolation("revision history digest mismatch")
                    history.append({"ref": self._row_ref(row).as_dict(), "untrusted_content": data.decode("utf-8")})
            return history

    def list_artifacts(self, request_id: str, *, scope: str | None = None) -> list[ArtifactRef]:
        query = "SELECT * FROM artifacts WHERE request_id=?"
        params: list[Any] = [request_id]
        if scope is not None:
            query += " AND scope=?"
            params.append(scope)
        query += " ORDER BY sequence"
        with self._connection() as connection:
            return [self._row_ref(row) for row in connection.execute(query, params).fetchall()]

    def read_artifact(
        self,
        request_id: str,
        task_id: str,
        *,
        role: str,
        artifact_ref: ArtifactRef | Mapping[str, Any],
    ) -> bytes:
        role_config = self.require_ready(role)
        if "read_text" not in role_config["tools"]:
            raise PolicyViolation("role is not allowed to read artifacts")
        ref = self._coerce_ref(artifact_ref)
        with self._connection() as connection:
            row = self._artifact_row(connection, ref, require_latest=False)
            if row["request_id"] != request_id:
                raise PolicyViolation("artifact belongs to another request")
            task = connection.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
            if task is None or task["request_id"] != request_id or task["target_role"] != role:
                raise PolicyViolation("artifact read is not bound to this role task")
            if ref.as_dict() not in json.loads(task["dependencies_json"]):
                raise PolicyViolation("artifact read was not explicitly assigned as a task dependency")
            path = _safe_absolute_path(self.artifact_root / row["storage_name"], must_exist=True)
            if path.parent != self.artifact_root / row["role"]:
                raise PolicyViolation("artifact storage escaped its controlled root")
            payload = path.read_bytes()
            if _sha256_bytes(payload) != row["sha256"]:
                raise PolicyViolation("immutable artifact content hash mismatch")
            return payload

    def authorize_read(self, role: str, path: str | os.PathLike[str]) -> Path:
        role_config = self.require_ready(role)
        if "read_text" not in role_config["tools"]:
            raise PolicyViolation("role is not allowed to read text")
        candidate = _safe_absolute_path(path, must_exist=True)
        roots = tuple(_safe_absolute_path(root) for root in role_config["read_roots"])
        if not _is_within(candidate, roots):
            raise PolicyViolation("read path is outside the role's configured roots")
        protected = (self.config_path, self.state_path, self.artifact_root)
        if any(_paths_overlap(candidate, item) for item in protected):
            raise PolicyViolation("read path overlaps protected policy or research state")
        return candidate

    def get_budget(self, request_id: str, role: str) -> dict[str, dict[str, int]]:
        self.require_ready(role)
        with self._connection() as connection:
            self._request_row(connection, request_id)
            used = {kind: self._usage(connection, request_id, role, kind) for kind in LIMIT_KEYS[:5]}
            reserved = {
                kind: self._reserved(connection, request_id, role, kind) for kind in LIMIT_KEYS[:5]
            }
            limits = {kind: self._role_limit(role, kind) for kind in LIMIT_KEYS[:5]}
            return {"used": used, "reserved": reserved, "limits": limits}


__all__ = [
    "ArtifactRef",
    "BudgetExceeded",
    "ConfigStatus",
    "GateDecision",
    "PolicyEngine",
    "PolicyError",
    "PolicyHold",
    "PolicyViolation",
    "ROLE_IDS",
]
