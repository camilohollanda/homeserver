"""Offline checks for the native Ollama installer's public CLI contract."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent


class InstallerTest(unittest.TestCase):
    def run_script(self, script="install.sh", args=("--dry-run",), **overrides):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("OLLAMA_") and k != "REMOTE_HOST"}
        env.update(overrides)
        return subprocess.run(["bash", str(HERE / script), *args], env=env,
                              text=True, capture_output=True, timeout=10)

    def test_simulation_renders_local_api_and_single_request_service(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OLLAMA_HOST=127.0.0.1:11434", result.stdout)
        self.assertIn("OLLAMA_MODELS=/dados/ollama/models", result.stdout)
        self.assertIn("OLLAMA_NUM_PARALLEL=1", result.stdout)
        self.assertIn("OLLAMA_NO_CLOUD=1", result.stdout)
        self.assertIn("User=ollama", result.stdout)

    def test_settings_reach_the_rendered_service(self):
        result = self.run_script(OLLAMA_PORT="11435", OLLAMA_CONTEXT_LENGTH="8192",
                                 OLLAMA_DATA_MOUNT="/mnt/models",
                                 OLLAMA_MODELS="/mnt/models/ollama/models")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OLLAMA_HOST=127.0.0.1:11435", result.stdout)
        self.assertIn("OLLAMA_CONTEXT_LENGTH=8192", result.stdout)
        self.assertIn("RequiresMountsFor=/mnt/models", result.stdout)

    def test_unpinned_version_or_model_is_rejected(self):
        for settings in ({"OLLAMA_VERSION": "99.0.0"},
                         {"OLLAMA_MODEL": "qwen2.5-coder:14b"}):
            with self.subTest(settings=settings):
                result = self.run_script(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("SHA256", result.stderr)

    def test_invalid_paths_and_limits_fail_before_installation(self):
        cases = [
            {"OLLAMA_PORT": "0"}, {"OLLAMA_PORT": "65536"},
            {"OLLAMA_CONTEXT_LENGTH": "0"},
            {"OLLAMA_NUM_PARALLEL": "2"},
            {"OLLAMA_DATA_MOUNT": "/"},
            {"OLLAMA_MODELS": "/var/lib/models"},
            {"OLLAMA_MODELS": "/dados/../etc"},
            {"OLLAMA_MODELS": "/dados/models\nUser=root"},
            {"OLLAMA_VERIFY_GPU": "maybe"},
        ]
        for settings in cases:
            with self.subTest(settings=settings):
                result = self.run_script(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Error:", result.stderr)

    def test_setup_simulation_never_connects_to_ssh(self):
        with tempfile.TemporaryDirectory() as tmp:
            ssh = Path(tmp) / "ssh"
            ssh.write_text("#!/bin/sh\necho unexpected-ssh >&2\nexit 99\n")
            ssh.chmod(0o755)
            result = self.run_script(script="setup.sh", OLLAMA_SSH="invalid@example",
                                     PATH=tmp + os.pathsep + os.environ["PATH"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("unexpected-ssh", result.stderr)
            self.assertIn("invalid@example", result.stdout)

    def test_unknown_arguments_do_not_start_installation(self):
        for script in ("install.sh", "setup.sh"):
            with self.subTest(script=script):
                result = self.run_script(script=script, args=("--unknown",))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Error:", result.stderr)

    def test_stdin_dry_run_uses_the_same_entry_point(self):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("OLLAMA_") and k != "REMOTE_HOST"}
        result = subprocess.run(["bash", "-s", "--", "--dry-run"],
                                input=(HERE / "install.sh").read_text(),
                                env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("OLLAMA_HOST=127.0.0.1:11434", result.stdout)


class SafetyCheckTest(unittest.TestCase):
    """Run production guards with real directories and fake host observations."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.mount = self.root / "dados"
        self.mount.mkdir()
        self.models = self.mount / "ollama" / "models"
        self.service = self.root / "ollama.service"
        self.service.write_text("# Managed by external/cawser/ollama/install.sh\n")
        self.listeners = self.root / "listeners"
        self.listeners.write_text("")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("OLLAMA_") and k != "REMOTE_HOST"}
        self.env.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        OLLAMA_DATA_MOUNT=str(self.mount),
                        OLLAMA_MODELS=str(self.models), OLLAMA_PORT="11434",
                        SERVICE=str(self.service), MAIN_PID="1234",
                        LISTENERS_FILE=str(self.listeners), ACTIVE_STATUS="0",
                        MOUNT_STATUS="0", API="http://127.0.0.1:11434")
        # macOS ships BSD realpath; use the real GNU implementation there.
        realpath = shutil.which("grealpath") or shutil.which("realpath")
        self.assertIsNotNone(realpath, "GNU realpath is required for these checks")
        (self.bin / "realpath").symlink_to(realpath)
        self.command("mountpoint", '''[[ "$1" == -q && "$2" == "$OLLAMA_DATA_MOUNT" ]] || exit 90
exit "$MOUNT_STATUS"
''')
        self.command("ss", '''[[ "$*" == '-H -lntp sport = :11434' ]] || exit 90
cat "$LISTENERS_FILE"
''')
        self.command("systemctl", '''case "$*" in
  'show ollama.service -p FragmentPath --value') printf '%s\\n' "$SERVICE" ;;
  'show ollama.service -p MainPID --value') printf '%s\\n' "$MAIN_PID" ;;
  'is-active --quiet ollama.service') exit "$ACTIVE_STATUS" ;;
  *) exit 90 ;;
esac
''')

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
        path.chmod(0o755)

    def run_check(self, body, **overrides):
        env = self.env | overrides
        # --dry-run makes this safe even before the sourceable guard exists.
        return subprocess.run(["bash", "-c", 'source "$1" --dry-run\n' + body,
                               "bash", str(HERE / "install.sh")], env=env,
                              text=True, capture_output=True, timeout=10)

    def listener(self, pid=1234, address="127.0.0.1"):
        return (f'LISTEN 0 4096 {address}:11434 0.0.0.0:* '
                f'users:(("ollama",pid={pid},fd=3))\n')

    def test_sourcing_defines_checks_without_running_the_installer(self):
        result = self.run_check("printf 'sourced\\n'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "sourced\n")

    def test_missing_mount_is_rejected(self):
        result = self.run_check("check_model_storage", MOUNT_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not mounted", result.stderr)

    def test_symlink_ancestor_cannot_redirect_model_storage(self):
        outside = self.root / "other-app"
        outside.mkdir()
        (self.mount / "ollama").symlink_to(outside, target_is_directory=True)
        result = self.run_check("check_model_storage")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlinks", result.stderr)
        self.assertEqual(list(outside.iterdir()), [])

    def test_unmanaged_nonempty_models_are_rejected_without_changes(self):
        self.models.mkdir(parents=True)
        existing = self.models / "existing-model"
        existing.write_text("preserve me")
        before = self.models.stat()
        result = self.run_check("check_model_storage")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unmanaged nonempty model directory", result.stderr)
        self.assertEqual(existing.read_text(), "preserve me")
        after = self.models.stat()
        self.assertEqual((before.st_uid, before.st_gid, before.st_mode),
                         (after.st_uid, after.st_gid, after.st_mode))

    def test_empty_and_previously_managed_models_are_accepted(self):
        for state in ("missing", "empty", "managed"):
            with self.subTest(state=state):
                if state == "empty":
                    self.models.mkdir(parents=True)
                if state == "managed":
                    (self.models / ".ollama-native-managed").write_text(
                        "# Managed by external/cawser/ollama/install.sh\n")
                    (self.models / "existing-model").write_text("preserve me")
                result = self.run_check("check_model_storage; printf 'accepted\\n'")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "accepted\n")

    def test_existing_unit_does_not_allow_an_unrelated_listener(self):
        self.listeners.write_text(self.listener(pid=9999))
        result = self.run_check("check_port_ownership")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the managed Ollama service", result.stderr)

    def test_every_listener_must_belong_to_the_service(self):
        self.listeners.write_text(self.listener() + self.listener(pid=9999))
        result = self.run_check("check_port_ownership")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the managed Ollama service", result.stderr)

    def test_managed_loopback_listener_is_accepted(self):
        self.listeners.write_text(self.listener())
        result = self.run_check("check_port_ownership 1; printf 'accepted\\n'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "accepted\n")

    def test_free_port_is_accepted_before_startup(self):
        result = self.run_check("check_port_ownership; printf 'accepted\\n'")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "accepted\n")

    def test_mutations_require_an_active_loopback_listener(self):
        for state in ("missing", "inactive", "public"):
            with self.subTest(state=state):
                self.listeners.write_text("" if state == "missing" else
                                          self.listener(address="0.0.0.0" if
                                                        state == "public" else "127.0.0.1"))
                result = self.run_check("check_port_ownership 1",
                                        ACTIVE_STATUS="1" if state == "inactive" else "0")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Error:", result.stderr)

    def test_model_pull_rechecks_listener_after_reading_tags(self):
        self.listeners.write_text(self.listener())
        self.env.update(BASE=str(self.root / "release"),
                        OLLAMA_MODEL="qwen3-coder:30b",
                        OLLAMA_MODEL_SHA256="a" * 64)
        cli = self.root / "release" / "current" / "bin"
        cli.mkdir(parents=True)
        mutation = self.root / "mutated"
        self.env["MUTATION_FILE"] = str(mutation)
        (cli / "ollama").write_text('#!/bin/bash\ntouch "$MUTATION_FILE"\n')
        (cli / "ollama").chmod(0o755)
        self.command("curl", '''[[ "${!#}" == "$API/api/tags" ]] || exit 90
printf '%s\\n' '{"models":[]}'
printf '%s\\n' 'LISTEN 0 4096 127.0.0.1:11434 0.0.0.0:* users:(("other",pid=9999,fd=3))' > "$LISTENERS_FILE"
''')
        result = self.run_check("check_port_ownership 1; ensure_model")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the managed Ollama service", result.stderr)
        self.assertFalse(mutation.exists(), "must not pull through an unrelated server")

    def test_gpu_smoke_check_rejects_an_unrelated_server(self):
        self.listeners.write_text(self.listener(pid=9999))
        mutation = self.root / "mutated"
        self.env.update(WORK=str(self.root), MUTATION_FILE=str(mutation),
                        OLLAMA_MODEL="qwen3-coder:30b", OLLAMA_CONTEXT_LENGTH="16384")
        self.command("curl", 'touch "$MUTATION_FILE"\n')
        result = self.run_check("verify_gpu")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the managed Ollama service", result.stderr)
        self.assertFalse(mutation.exists(), "must not generate through an unrelated server")


class GroupMembershipTest(unittest.TestCase):
    """Exercise group reconciliation and service activation without root access."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.groups = self.root / "groups"
        self.groups.write_text("ollama video render")
        self.changes = self.root / "changes"
        self.service_calls = self.root / "service-calls"

    def reconcile(self, **overrides):
        script = '''source "$1"
id() {
  [[ "$*" == '-nG ollama' ]] || exit 90
  cat "$TEST_GROUPS_FILE"
}
getent() {
  [[ "$1" == group ]] || exit 90
  [[ " $TEST_HOST_GROUPS " == *" $2 "* ]]
}
usermod() {
  [[ "$1" == -aG && "$3" == ollama && "$#" == 3 ]] || exit 90
  [[ "$TEST_FAIL_USERMOD" == 0 ]] || return 1
  if [[ " $(cat "$TEST_GROUPS_FILE") " != *" $2 "* ]]; then
    printf ' %s' "$2" >> "$TEST_GROUPS_FILE"
  fi
  printf '%s\\n' "$*" >> "$TEST_CHANGES_FILE"
}
systemctl() {
  case "$*" in
    daemon-reload|'enable --quiet ollama.service') ;;
    'start ollama.service'|'restart ollama.service')
      printf '%s\\n' "$1" >> "$TEST_SERVICE_CALLS" ;;
    *) exit 90 ;;
  esac
}
CHANGED="$TEST_CHANGED"
ensure_gpu_groups
activate_service
'''
        env = {**os.environ, "TEST_GROUPS_FILE": str(self.groups),
               "TEST_CHANGES_FILE": str(self.changes), "TEST_SERVICE_CALLS": str(self.service_calls),
               "TEST_HOST_GROUPS": "video render", "TEST_FAIL_USERMOD": "0", "TEST_CHANGED": "0",
               **overrides}
        return subprocess.run(["bash", "-c", script, "test", str(HERE / "install.sh")],
                              env=env, text=True, capture_output=True, timeout=10)

    def test_missing_memberships_restart_once_then_remain_idempotent(self):
        for initial, additions in (("ollama", ["video", "render"]),
                                   ("ollama video", ["render"]),
                                   ("ollama render", ["video"]),
                                   ("ollama video-capture render", ["video"])):
            with self.subTest(initial=initial):
                self.groups.write_text(initial)
                self.changes.unlink(missing_ok=True)
                self.service_calls.unlink(missing_ok=True)
                for _ in range(2):
                    result = self.reconcile()
                    self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.service_calls.read_text().splitlines(), ["restart", "start"])
                self.assertEqual(self.groups.read_text().split(), initial.split() + additions)
                self.assertEqual(self.changes.read_text().splitlines(),
                                 [f"-aG {group} ollama" for group in additions])

    def test_existing_memberships_do_not_modify_accounts_or_restart(self):
        result = self.reconcile()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.changes.exists())
        self.assertEqual(self.groups.read_text(), "ollama video render")
        self.assertEqual(self.service_calls.read_text(), "start\n")

    def test_existing_configuration_change_still_restarts_service(self):
        result = self.reconcile(TEST_CHANGED="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.changes.exists())
        self.assertEqual(self.service_calls.read_text(), "restart\n")

    def test_groups_absent_from_host_are_not_added(self):
        self.groups.write_text("ollama video")
        result = self.reconcile(TEST_HOST_GROUPS="video")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.changes.exists())
        self.assertEqual(self.groups.read_text(), "ollama video")
        self.assertEqual(self.service_calls.read_text(), "start\n")

    def test_failed_group_update_stops_before_service_activation(self):
        self.groups.write_text("ollama video")
        result = self.reconcile(TEST_FAIL_USERMOD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.groups.read_text(), "ollama video")
        self.assertFalse(self.service_calls.exists())


if __name__ == "__main__":
    unittest.main()
