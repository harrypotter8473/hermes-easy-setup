"""Offline native-profile isolation tests; no Hermes or credential loading."""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from ruamel.yaml import YAML
import ruamel.yaml

from engine.research_team import profile_config


class ProfileConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.packages_temp = tempfile.TemporaryDirectory(prefix="research-yaml-package-")
        cls.source = Path(cls.packages_temp.name) / "source"
        target = cls.source / "venv" / "Lib" / "site-packages" / "ruamel" / "yaml"
        target.parent.mkdir(parents=True)
        shutil.copytree(Path(ruamel.yaml.__file__).parent, target,
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        # Importing the native installation would cause this test to fail.
        (cls.source / "hermes_bootstrap.py").write_text("raise RuntimeError('NativeImportForbidden')\n")
        (cls.source / "run_agent.py").write_text("raise RuntimeError('NativeImportForbidden')\n")

    @classmethod
    def tearDownClass(cls):
        cls.packages_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="research-profile-isolation-")
        self.root = Path(self.temp.name)
        self.profile = self.root / "profiles" / "research-lead"
        self.profile.mkdir(parents=True)
        self.config = self.profile / "config.yaml"

    def tearDown(self):
        self.temp.cleanup()

    def run_cli(self, *, source=None, profile=None, expected=0):
        completed = subprocess.run(
            [sys.executable, "-I", "-S", "-B", str(Path(profile_config.__file__)),
             "--source", str(source or self.source), "--profile", str(profile or self.profile)],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(completed.returncode, expected, completed.stdout + completed.stderr)
        self.assertEqual(completed.stderr, "")
        self.assertNotIn("credential-fixture", completed.stdout)
        return json.loads(completed.stdout)

    def test_roundtrip_keeps_unrelated_values_comments_and_credentials(self):
        original = (
            '# Keep this research profile comment\r\n'
            'model:\r\n  default: "selected-model" # retain this quote\r\n'
            'custom:\r\n  prompt: |\r\n    first line\r\n    second line\r\n'
            '  values: [1, true, null, "off"]\r\n'
            'platforms:\r\n  mattermost:\r\n    enabled: true\r\n'
            '    token: credential-fixture\r\n    url: http://127.0.0.1:18065\r\n'
            '  custom_adapter:\r\n    enabled: true\r\n    token: credential-fixture-custom\r\n'
        )
        self.config.write_bytes(original.encode("utf-8"))
        (self.profile / ".env").write_bytes(b"MATTERMOST_TOKEN=credential-fixture-env\r\n")
        (self.profile / "auth.json").write_bytes(b'{"key":"credential-fixture-auth"}')
        before = YAML(typ="safe").load(original)
        result = self.run_cli()
        self.assertTrue(result["isolated"])
        self.assertTrue(result["changed"])
        self.assertEqual(result["platforms_disabled"], 20)
        raw = self.config.read_bytes()
        after = YAML(typ="safe").load(raw.decode())
        for name in profile_config.PLATFORMS:
            self.assertIs(after["platforms"][name]["enabled"], False)
        self.assertIs(after["platforms"]["custom_adapter"]["enabled"], False)
        expected = copy.deepcopy(before)
        for name in (*profile_config.PLATFORMS, "custom_adapter"):
            expected["platforms"].setdefault(name, {})["enabled"] = False
        self.assertEqual(after, expected)
        self.assertIn(b"# Keep this research profile comment\r\n", raw)
        self.assertIn(b'"selected-model" # retain this quote', raw)
        self.assertEqual((self.profile / ".env").read_bytes(), b"MATTERMOST_TOKEN=credential-fixture-env\r\n")
        self.assertEqual((self.profile / "auth.json").read_bytes(), b'{"key":"credential-fixture-auth"}')
        second = self.run_cli()
        self.assertFalse(second["changed"])
        self.assertEqual(self.config.read_bytes(), raw)
        self.assertEqual(list(self.profile.glob(".research-config-*.tmp")), [])

    def test_missing_config_initializes_only_platform_flags(self):
        result = self.run_cli()
        self.assertTrue(result["changed"])
        parsed = YAML(typ="safe").load(self.config.read_text())
        self.assertEqual(set(parsed), {"platforms"})
        self.assertEqual(set(parsed["platforms"]), set(profile_config.PLATFORMS))

    def test_bom_is_preserved(self):
        self.config.write_bytes(b"\xef\xbb\xbfmodel: keep\n")
        self.run_cli()
        self.assertTrue(self.config.read_bytes().startswith(b"\xef\xbb\xbf"))

    def test_malformed_duplicate_tag_alias_and_invalid_structure_never_overwrite(self):
        samples = [
            'platforms: [\n',
            'model: one\nmodel: two\n',
            'value: !!python/object/apply:os.system [echo forbidden]\n',
            'shared: &same {enabled: true}\nplatforms: {mattermost: *same}\n',
            'platforms: {mattermost: !custom {enabled: true}}\n',
            'platforms: null\n',
            'platforms: {mattermost: true}\n',
            '- not-a-config-mapping\n',
        ]
        for text in samples:
            with self.subTest(text=text):
                self.config.write_text(text, encoding="utf-8")
                before = self.config.read_bytes()
                result = self.run_cli(expected=2)
                self.assertFalse(result["isolated"])
                self.assertEqual(self.config.read_bytes(), before)
                self.assertEqual(list(self.profile.glob(".research-config-*.tmp")), [])

    def test_size_and_encoding_limit_preserve_file(self):
        for value in (b"#" * (profile_config.MAX_BYTES + 1), b"model: \xff\xfe"):
            self.config.write_bytes(value)
            self.run_cli(expected=2)
            self.assertEqual(self.config.read_bytes(), value)

    def test_relative_personal_and_nonexistent_paths_are_rejected(self):
        self.config.write_text("model: keep\n")
        self.run_cli(source=Path("relative-source"), expected=2)
        personal = self.root / "profiles" / "default"
        personal.mkdir()
        self.run_cli(profile=personal, expected=2)
        self.run_cli(profile=self.root / "missing", expected=2)
        self.assertEqual(self.config.read_text(), "model: keep\n")

    def test_reparse_attribute_is_rejected(self):
        self.config.write_text("model: keep\n")
        actual_lstat = Path.lstat

        def marked(path):
            info = actual_lstat(path)
            if path == self.profile:
                return SimpleNamespace(st_mode=info.st_mode, st_file_attributes=0x400)
            return info

        with mock.patch.object(Path, "lstat", marked):
            with self.assertRaisesRegex(profile_config.ProfileConfigError, "LinkedPathRejected"):
                profile_config.safe_path(self.config, kind="file")

    def test_symlink_rejected_before_loading_or_writing(self):
        real = self.root / "real.yaml"
        real.write_text("model: keep\n")
        try:
            self.config.symlink_to(real)
        except OSError:
            self.skipTest("This Windows account cannot create symlinks")
        self.run_cli(expected=2)
        self.assertEqual(real.read_text(), "model: keep\n")

    def test_hardlinked_config_rejected(self):
        real = self.root / "real.yaml"
        real.write_text("model: keep\n")
        try:
            os.link(real, self.config)
        except OSError:
            self.skipTest("Hardlinks unavailable on this filesystem")
        self.run_cli(expected=2)
        self.assertEqual(real.read_text(), "model: keep\n")

    def test_concurrent_user_edit_is_not_overwritten(self):
        self.config.write_text("model: before\n")
        actual_mkstemp = tempfile.mkstemp

        def racing_temp(*args, **kwargs):
            answer = actual_mkstemp(*args, **kwargs)
            self.config.write_text("model: concurrent-edit\n")
            return answer

        yaml = YAML(typ="rt", pure=True)
        yaml.allow_duplicate_keys = False
        with mock.patch.object(profile_config, "load_yaml", return_value=yaml), \
                mock.patch.object(profile_config.tempfile, "mkstemp", side_effect=racing_temp):
            with self.assertRaisesRegex(profile_config.ProfileConfigError, "ConfigChangedDuringUpdate"):
                profile_config.isolate(self.source, self.profile)
        self.assertEqual(self.config.read_text(), "model: concurrent-edit\n")
        self.assertEqual(list(self.profile.glob(".research-config-*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
