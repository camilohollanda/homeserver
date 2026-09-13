"""Offline validation for the dedicated runner bootstrap (no GitHub writes)."""

import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


class RunnerInstallerTest(unittest.TestCase):
    def run_script(self, script="install.sh", **overrides):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("REVIEW_") and k != "REMOTE_HOST"}
        env["REVIEW_GITHUB_URL"] = "https://github.com/example-org/example-repo"
        env.update(overrides)
        return subprocess.run(["bash", str(HERE / script), "--dry-run"],
                              env=env, text=True, capture_output=True, timeout=10)

    def test_preview_has_a_dedicated_account_and_never_prints_tokens(self):
        result = self.run_script(REVIEW_RUNNER_TOKEN="must-not-be-printed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("User=review-runner", result.stdout)
        self.assertIn("NoNewPrivileges=true", result.stdout)
        self.assertIn("127.0.0.1:11434", result.stdout)
        self.assertNotIn("must-not-be-printed", result.stdout + result.stderr)

    def test_named_instance_has_its_own_account_paths_and_label(self):
        result = self.run_script(REVIEW_INSTANCE="werify")
        self.assertEqual(result.returncode, 0, result.stderr)
        for expected in (
            "runner: server-code-review-werify", "User=review-runner-werify\n",
            "Group=review-runner-werify\n",
            "WorkingDirectory=/opt/code-review-runner-werify/runner\n",
            "ExecStart=/opt/code-review-runner-werify/runner/run.sh\n",
            "Environment=HOME=/var/lib/code-review-runner-werify\n",
            "StateDirectory=code-review-runner-werify\n",
            "/etc/systemd/system/code-review-runner-werify.service",
            "code-review-werify",
        ):
            self.assertIn(expected, result.stdout)
        self.assertNotIn("/opt/code-review-runner/", result.stdout)
        self.assertNotIn("User=review-runner\n", result.stdout)
        self.assertIn("127.0.0.1:11434", result.stdout)

    def test_unnamed_instance_preserves_existing_identity_and_paths(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        for expected in (
            "runner: server-code-review\n", "User=review-runner\n",
            "WorkingDirectory=/opt/code-review-runner/runner\n",
            "StateDirectory=code-review-runner\n",
            "/etc/systemd/system/code-review-runner.service",
        ):
            self.assertIn(expected, result.stdout)

    def test_invalid_instance_is_rejected_before_network_access(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("ssh", "gh"):
                tool = Path(tmp) / name
                tool.write_text("#!/bin/sh\necho unexpected-network >&2\nexit 0\n")
                tool.chmod(0o755)
            for instance in ("../miora", "a/b", "x\nUser=root", "Werify", "-x", "x" * 17):
                with self.subTest(instance=instance):
                    env = {k: v for k, v in os.environ.items()
                           if not k.startswith("REVIEW_") and k != "REMOTE_HOST"}
                    env.update(REVIEW_INSTANCE=instance,
                               REVIEW_GITHUB_URL="https://github.com/org/repo",
                               PATH=tmp + os.pathsep + os.environ["PATH"])
                    result = subprocess.run(["bash", str(HERE / "setup.sh")],
                                            env=env, text=True, capture_output=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("invalid REVIEW_INSTANCE", result.stderr)
                    self.assertNotIn("unexpected-network", result.stderr)

    def test_setup_probes_selected_instance_and_forwards_it_over_ssh(self):
        for registered in (False, True):
            with self.subTest(registered=registered), tempfile.TemporaryDirectory() as tmp:
                folder = Path(tmp)
                ssh = folder / "ssh"
                ssh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["RUNNER_TEST_DIR"])
with (root / "ssh.jsonl").open("a") as output:
    output.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[-2:] == ["bash", "-s"]:
    (root / "payload").write_text(sys.stdin.read())
elif "test" in sys.argv:
    # An existing Miora registration must not suppress a new Werify token.
    if sys.argv[-1] == "/opt/code-review-runner/runner/.runner":
        sys.exit(0)
    sys.exit(0 if os.environ["RUNNER_TEST_REGISTERED"] == "yes" else 1)
''')
                gh = folder / "gh"
                gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ["RUNNER_TEST_DIR"])
(root / "gh.json").write_text(json.dumps(sys.argv[1:]))
print("test-registration-token")
''')
                ssh.chmod(0o755)
                gh.chmod(0o755)
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith("REVIEW_") and k != "REMOTE_HOST"}
                env.update(REVIEW_INSTANCE="werify", REVIEW_SSH="fake-host",
                           REVIEW_GITHUB_URL="https://github.com/prem-prakash/werify",
                           RUNNER_TEST_DIR=tmp, RUNNER_TEST_REGISTERED="yes" if registered else "no",
                           PATH=tmp + os.pathsep + os.environ["PATH"])
                result = subprocess.run(["bash", str(HERE / "setup.sh")],
                                        env=env, text=True, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                calls = [json.loads(line) for line in (folder / "ssh.jsonl").read_text().splitlines()]
                probes = [call[-1] for call in calls if "test" in call]
                self.assertEqual(probes, ["/opt/code-review-runner-werify/runner/.runner"])
                self.assertIn("export REVIEW_INSTANCE=werify\n", (folder / "payload").read_text())
                self.assertNotIn("test-registration-token", result.stdout + result.stderr)
                self.assertEqual((folder / "gh.json").exists(), not registered)
                if not registered:
                    self.assertIn("repos/prem-prakash/werify/actions/runners/registration-token",
                                  json.loads((folder / "gh.json").read_text()))

    def test_only_github_org_or_repo_urls_are_accepted(self):
        for url in ("", "http://github.com/org", "https://evil.test/org",
                    "https://github.com/org/repo/pull/1", "https://github.com/org\nBAD=x"):
            with self.subTest(url=url):
                result = self.run_script(REVIEW_GITHUB_URL=url)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Error:", result.stderr)
        for url in ("https://github.com/org", "https://github.com/org/repo"):
            self.assertEqual(self.run_script(REVIEW_GITHUB_URL=url).returncode, 0)

    def test_runner_version_change_requires_a_checksum(self):
        result = self.run_script(REVIEW_RUNNER_VERSION="99.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("SHA256", result.stderr)

    def test_invalid_configuration_is_rejected(self):
        for settings in ({"REVIEW_RUNNER_NAME": "x\nUser=root"},
                         {"REVIEW_OLLAMA_PORT": "0"},
                         {"REVIEW_OLLAMA_PORT": "65536"}):
            with self.subTest(settings=settings):
                self.assertNotEqual(self.run_script(**settings).returncode, 0)

    def test_setup_preview_never_calls_ssh_or_github(self):
        with tempfile.TemporaryDirectory() as tmp:
            for name in ("ssh", "gh"):
                tool = Path(tmp) / name
                tool.write_text("#!/bin/sh\necho unexpected-network >&2\nexit 99\n")
                tool.chmod(0o755)
            result = self.run_script(script="setup.sh", PATH=tmp + os.pathsep + os.environ["PATH"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("unexpected-network", result.stderr)

    def test_reregistration_refuses_a_different_scope_or_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".runner"
            path.write_text(json.dumps({"gitHubUrl": "https://github.com/Example-Org/App/",
                                        "agentName": "server-code-review"}))
            before = path.read_bytes()
            for scope, name, success in (
                ("https://github.com/example-org/app", "server-code-review", True),
                ("https://github.com/example-org/other", "server-code-review", False),
                ("https://github.com/example-org/app", "another-runner", False),
            ):
                with self.subTest(scope=scope, name=name):
                    result = subprocess.run([
                        "bash", "-c", 'source "$1"; check_registration "$2" "$3" "$4"',
                        "test", str(HERE / "install.sh"), str(path), scope, name,
                    ], text=True, capture_output=True)
                    self.assertEqual(result.returncode == 0, success, result.stderr)
                    self.assertEqual(path.read_bytes(), before)

    def test_dotnet_bom_metadata_reuses_registration(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / ".runner"
            path.write_text(json.dumps({"gitHubUrl": "https://github.com/Cawser/miora",
                                        "agentName": "server-code-review"}), encoding="utf-8-sig")
            before = path.read_bytes()
            result = subprocess.run([
                "bash", "-c", 'source "$1"; check_registration "$2" "$3" "$4"',
                "test", str(HERE / "install.sh"), str(path),
                "https://github.com/Cawser/miora", "server-code-review",
            ], text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
