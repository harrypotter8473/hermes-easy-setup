"""Disable research-profile native adapters without bootstrapping Hermes.

The installer verifies ownership and backs up the profile before invoking this
helper with the selected Hermes Python. No credentials, auth, plugins, network,
or native Hermes module is loaded here.
"""
from __future__ import annotations

import argparse
from collections.abc import Mapping
import contextlib
import hashlib
import importlib
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile


PLATFORMS = (
    "mattermost", "telegram", "discord", "slack", "whatsapp", "signal",
    "matrix", "email", "sms", "homeassistant", "dingtalk", "feishu", "wecom",
    "wecom_callback", "weixin", "bluebubbles", "qqbot", "yuanbao", "relay",
)
MAX_BYTES = 2_000_000
STANDARD_TAGS = {"tag:yaml.org,2002:" + name for name in
                 ("map", "seq", "str", "null", "bool", "int", "float", "timestamp")}


class ProfileConfigError(ValueError):
    pass


def safe_path(value, *, kind=None, missing=False):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts or str(path).startswith("\\\\"):
        raise ProfileConfigError("AbsoluteLocalPathRequired")
    for item in reversed((path, *path.parents)):
        try:
            info = item.lstat()
        except FileNotFoundError:
            if item == path and missing:
                return path
            raise ProfileConfigError("PathMissing") from None
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise ProfileConfigError("LinkedPathRejected")
        if item != path and not stat.S_ISDIR(info.st_mode):
            raise ProfileConfigError("ParentPathRejected")
    if kind == "directory" and not path.is_dir():
        raise ProfileConfigError("DirectoryRequired")
    if kind == "file" and (not path.is_file() or path.stat().st_nlink != 1):
        raise ProfileConfigError("RegularUnlinkedFileRequired")
    return path


def load_yaml(source):
    """Use only the selected installation's pure-Python roundtrip YAML package."""
    source = safe_path(source, kind="directory")
    packages = safe_path(source / "venv" / "Lib" / "site-packages", kind="directory")
    package = safe_path(packages / "ruamel" / "yaml" / "__init__.py", kind="file")
    sys.path.insert(0, str(packages))
    module = importlib.import_module("ruamel.yaml")
    origin = safe_path(module.__file__, kind="file")
    if os.path.normcase(str(origin)) != os.path.normcase(str(package)):
        raise ProfileConfigError("YamlPackageOriginRejected")
    yaml = module.YAML(typ="rt", pure=True)
    yaml.preserve_quotes = True
    yaml.allow_duplicate_keys = False
    yaml.width = 4096
    return yaml


def parse_document(yaml, text):
    # Anchors/aliases can share mutable nodes across otherwise unrelated config
    # fields. Reject them instead of accidentally changing both aliases.
    try:
        for token in yaml.scan(text):
            if type(token).__name__ in {"AliasToken", "AnchorToken"}:
                raise ProfileConfigError("YamlAliasRejected")
        node = yaml.compose(text)
        pending = [(node, 0)] if node is not None else []
        count = 0
        while pending:
            current, depth = pending.pop()
            count += 1
            if count > 20_000 or depth > 64:
                raise ProfileConfigError("YamlComplexityRejected")
            if current.tag not in STANDARD_TAGS:
                raise ProfileConfigError("YamlTagRejected")
            if current.id == "mapping":
                pending.extend((child, depth + 1) for pair in current.value for child in pair)
            elif current.id == "sequence":
                pending.extend((child, depth + 1) for child in current.value)
        document = yaml.load(text)
    except ProfileConfigError:
        raise
    except Exception:
        raise ProfileConfigError("YamlParseRejected") from None
    if document is None:
        document = {}
    if not isinstance(document, Mapping):
        raise ProfileConfigError("YamlRootMappingRequired")
    return document


def read_config(path):
    safe_path(path, kind="file", missing=True)
    if not path.exists():
        return None
    with path.open("rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_BYTES:
            raise ProfileConfigError("ConfigFileRejected")
        raw = stream.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ProfileConfigError("ConfigTooLarge")
    return raw


def isolate(source, profile):
    source = safe_path(source, kind="directory")
    profile = safe_path(profile, kind="directory")
    # This implementation is deliberately scoped to wizard-owned profile names;
    # ownership and identity are checked by the PowerShell installer.
    if profile.parent.name != "profiles" or profile.name not in {
            "research-lead", "research-scout", "research-worker", "research-reviewer"}:
        raise ProfileConfigError("ResearchProfileRequired")
    config = profile / "config.yaml"
    before = read_config(config)
    try:
        text = (before or b"").decode("utf-8-sig", errors="strict")
    except UnicodeError:
        raise ProfileConfigError("ConfigEncodingRejected") from None
    yaml = load_yaml(source)
    document = parse_document(yaml, text)
    platforms = document.get("platforms")
    if platforms is None and "platforms" not in document:
        platforms = {}
        document["platforms"] = platforms
    if not isinstance(platforms, Mapping):
        raise ProfileConfigError("PlatformMappingRequired")
    if any(not isinstance(name, str) or not name or any(ord(c) < 32 for c in name)
           for name in platforms):
        raise ProfileConfigError("PlatformNameRejected")
    names = list(dict.fromkeys((*PLATFORMS, *platforms)))
    for name in names:
        if name in platforms and not isinstance(platforms[name], Mapping):
            raise ProfileConfigError("PlatformEntryRejected")
    changed = False
    for name in names:
        if name not in platforms:
            platforms[name] = {}
        if platforms[name].get("enabled") is not False:
            platforms[name]["enabled"] = False
            changed = True
    if not changed:
        return {"isolated": True, "changed": False, "platforms_disabled": len(names)}
    output = io.StringIO()
    yaml.dump(document, output)
    rendered = output.getvalue()
    if parse_document(yaml, rendered) != document:
        raise ProfileConfigError("YamlRoundtripRejected")
    if before and b"\r\n" in before:
        rendered = rendered.replace("\r\n", "\n").replace("\n", "\r\n")
    encoded = rendered.encode("utf-8-sig" if before and before.startswith(b"\xef\xbb\xbf") else "utf-8")
    if len(encoded) > MAX_BYTES:
        raise ProfileConfigError("ConfigTooLarge")
    temporary = None
    try:
        safe_path(profile, kind="directory")
        descriptor, name = tempfile.mkstemp(prefix=".research-config-", suffix=".tmp", dir=profile)
        temporary = Path(name)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        safe_path(profile, kind="directory")
        if read_config(config) != before:
            raise ProfileConfigError("ConfigChangedDuringUpdate")
        safe_path(temporary, kind="file")
        os.replace(temporary, config)
        temporary = None
        if hashlib.sha256(read_config(config) or b"").digest() != hashlib.sha256(encoded).digest():
            raise ProfileConfigError("ConfigWriteNotVerified")
    finally:
        if temporary is not None and temporary.exists():
            safe_path(temporary, kind="file")
            temporary.unlink()
    return {"isolated": True, "changed": True, "platforms_disabled": len(names)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = isolate(args.source, args.profile)
    except ProfileConfigError as error:
        result = {"isolated": False, "error": str(error)}
    except Exception:
        result = {"isolated": False, "error": "ProfileIsolationFailed"}
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result["isolated"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
