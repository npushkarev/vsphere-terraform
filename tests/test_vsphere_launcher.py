import argparse
import hashlib
import importlib.util
import io
import json
import os
import shlex
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("vsphere_launcher", PROJECT_ROOT / "vsphere.py")
launcher = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = launcher
SPEC.loader.exec_module(launcher)


class LauncherTestCase(unittest.TestCase):
    def make_repo(self, root: Path, windows: bool = False):
        scripts = root / "scripts"
        scripts.mkdir(parents=True)
        extension = ".ps1" if windows else ".sh"
        for name in ("scan-vsphere", "plan", "apply-reviewed-plan", "install-repo-offline"):
            (scripts / (name + extension)).write_text("# test\n", encoding="utf-8")
        for stack in launcher.STACKS:
            stack_dir = root / "stacks" / stack
            stack_dir.mkdir(parents=True)
            (stack_dir / "main.tf").write_text("terraform {}\n", encoding="utf-8")
            (stack_dir / ".terraform.lock.hcl").write_text("# lock\n", encoding="utf-8")
        (root / ".terraform-version").write_text("1.15.8\n", encoding="utf-8")
        (root / ".govc-version").write_text("0.55.1\n", encoding="utf-8")
        (root / ".jq-version").write_text("1.8.2\n", encoding="utf-8")
        module_dir = root / "modules" / "linux-vm-clone"
        module_dir.mkdir(parents=True)
        (module_dir / "main.tf").write_text("resource \"null_resource\" \"test\" {}\n", encoding="utf-8")
        return launcher.Layout(root, scripts, root, None, windows)

    def make_report(self, root: Path) -> Path:
        root.mkdir()
        inventory = {
            "schema_version": "1.0.0",
            "read_only": True,
            "counts": {
                "datacenters": 1,
                "clusters": 2,
                "hosts": 3,
                "datastores": 4,
                "storage_pods": 1,
                "networks": 5,
                "virtual_machines": 6,
                "templates": 1,
            },
            "clone_candidate": {
                "source_vm_path": "/DC/vm/tst-win-10-12",
                "checks": [{"name": "unique_source", "status": "pass", "message": "ok"}],
            },
        }
        payloads = {
            "inventory.json": json.dumps(inventory, ensure_ascii=False) + "\n",
            "inventory.md": "# Шаблон Windows\n",
            "inventory-tree.txt": "/DC/vm/tst-win-10-12\n",
            "windows-clone.generated.tfvars": 'source_vm_name = "tst-win-10-12"\n',
        }
        lines = []
        for name, content in payloads.items():
            data = content.encode("utf-8")
            (root / name).write_bytes(data)
            lines.append("{}  {}".format(hashlib.sha256(data).hexdigest(), name))
        (root / "SHA256SUMS").write_text("\n".join(lines) + "\n", encoding="utf-8")
        return root


class VendorMetadataTests(unittest.TestCase):
    def test_vendored_artifacts_match_provenance_and_repository_limits(self):
        vendor = PROJECT_ROOT / "vendor"
        payload = json.loads((vendor / "provenance.json").read_text(encoding="utf-8"))
        self.assertEqual(payload["schema_version"], 1)
        self.assertEqual(set(payload["supported_platforms"]), {"linux_amd64", "windows_amd64"})
        artifacts = payload["artifacts"]
        self.assertEqual(len(artifacts), 8)
        seen = set()
        for artifact in artifacts:
            relative = artifact["path"]
            self.assertNotIn(relative, seen)
            seen.add(relative)
            path = PROJECT_ROOT / relative
            self.assertTrue(path.is_file())
            self.assertFalse(path.is_symlink())
            self.assertEqual(path.stat().st_size, artifact["size"])
            self.assertLess(path.stat().st_size, 95 * 1024 * 1024)
            self.assertEqual(launcher.sha256_file(path), artifact["sha256"])

    def test_vendor_manifest_is_an_exact_file_allowlist(self):
        vendor = PROJECT_ROOT / "vendor"
        expected = set()
        for line in (vendor / "MANIFEST.sha256").read_text(encoding="ascii").splitlines():
            digest, relative = line.split("  ", 1)
            self.assertRegex(digest, r"^[0-9a-f]{64}$")
            self.assertTrue(relative.startswith("vendor/"))
            path = PROJECT_ROOT / relative
            self.assertEqual(launcher.sha256_file(path), digest)
            expected.add(relative)
        actual = {
            path.relative_to(PROJECT_ROOT).as_posix()
            for path in vendor.rglob("*")
            if path.is_file() and path.name != "MANIFEST.sha256"
        }
        self.assertEqual(actual, expected)


class LayoutAndCommandTests(LauncherTestCase):
    def test_discovers_repo_independently_of_cwd(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            layout = self.make_repo(root)
            fake_source = root / "vsphere.py"
            fake_source.write_text("", encoding="utf-8")
            found = launcher.discover_layout(fake_source, windows=False)
            self.assertEqual(found.repo_root, layout.repo_root.resolve())
            self.assertEqual(found.scripts_dir, layout.scripts_dir.resolve())
            self.assertEqual(found.prefix, root.resolve() / ".vsphere-tools" / "linux_amd64")

    def test_repo_install_uses_only_offline_wrapper(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            basic = self.make_repo(root)
            vendor = root / "vendor"
            vendor.mkdir()
            (vendor / "MANIFEST.sha256").write_text("test\n", encoding="ascii")
            prefix = root / ".vsphere-tools" / "linux_amd64"
            layout = launcher.Layout(root, basic.scripts_dir, root, prefix, False)
            args = argparse.Namespace(verify_only=True)
            captured = {}

            def fake_run(command, env, cwd, timeout):
                captured["command"] = command
                captured["cwd"] = cwd

            with mock.patch.object(launcher, "run_process", side_effect=fake_run):
                launcher.command_install(layout, args)
            self.assertEqual(captured["command"][0], "/bin/sh")
            self.assertTrue(captured["command"][1].endswith("install-repo-offline.sh"))
            self.assertEqual(captured["command"][-1], "--verify-only")
            self.assertEqual(captured["cwd"], root)

    def test_vendored_repo_never_falls_back_to_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            basic = self.make_repo(root)
            vendor = root / "vendor"
            vendor.mkdir()
            (vendor / "MANIFEST.sha256").write_text("test\n", encoding="ascii")
            layout = launcher.Layout(
                root,
                basic.scripts_dir,
                root,
                root / ".vsphere-tools" / "linux_amd64",
                False,
            )
            with mock.patch.object(launcher.shutil, "which", return_value="/malicious/terraform"):
                with self.assertRaisesRegex(launcher.LauncherError, "vsphere.py install"):
                    launcher.find_tool(layout, "terraform")

    def test_linux_wrapper_is_argv_without_shell_text(self):
        with tempfile.TemporaryDirectory() as temporary:
            layout = self.make_repo(Path(temporary))
            hostile = "VM name; $(touch NO) & more"
            command = launcher.wrapper_command(layout, "scan-vsphere", ["--source-vm", hostile])
            self.assertEqual(command[0], "/bin/sh")
            self.assertEqual(command[-1], hostile)
            self.assertEqual(command.count(hostile), 1)

    def test_windows_wrapper_uses_no_profile_and_no_bypass(self):
        with tempfile.TemporaryDirectory() as temporary:
            layout = self.make_repo(Path(temporary), windows=True)
            with mock.patch.object(launcher, "powershell_path", return_value=r"C:\Windows\powershell.exe"):
                command = launcher.wrapper_command(layout, "plan", ["-Stack", "windows-clone"])
            self.assertIn("-NoProfile", command)
            self.assertIn("-NonInteractive", command)
            self.assertNotIn("Bypass", command)
            self.assertEqual(command[-2:], ["-Stack", "windows-clone"])

    def test_environment_scrubs_hidden_terraform_and_proxy_inputs(self):
        layout = launcher.Layout(Path("/tmp"), Path("/tmp"), None, None, False)
        hostile = {
            "TF_CLI_ARGS_apply": "-auto-approve",
            "TF_VAR_admin_password": "SECRET",
            "TF_WORKSPACE": "wrong",
            "TF_DATA_DIR": "/tmp/wrong-backend",
            "TF_CLI_CONFIG_FILE": "/tmp/malicious.tfrc",
            "GOVC_PASSWORD": "SECRET2",
            "HTTPS_PROXY": "http://proxy.invalid",
            "LD_PRELOAD": "/tmp/malicious.so",
            "ALLOW_WINDOWS_CLONE_APPLY": "yes",
        }
        identity = launcher.Identity("vc.example", "reader", "PASSWORD-SENTINEL")
        with mock.patch.dict(os.environ, hostile, clear=False):
            env = launcher.sanitized_environment(layout, identity)
        for name in hostile:
            self.assertNotIn(name, env)
        self.assertEqual(env["VSPHERE_PASSWORD"], "PASSWORD-SENTINEL")
        self.assertEqual(env["CHECKPOINT_DISABLE"], "1")

    def test_scan_password_is_only_in_child_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            layout = self.make_repo(root)
            output = root / "result with spaces"
            args = argparse.Namespace(
                server="vc.example",
                user="reader",
                source_vm="VM ; & | $()",
                output_dir=str(output),
                ca_cert=None,
                timeout_seconds=60,
            )
            identity = launcher.Identity("vc.example", "reader", "PASSWORD-SENTINEL")
            captured = {}

            def fake_run(command, env, cwd, timeout):
                captured["command"] = command
                captured["env"] = dict(env)

            with mock.patch.object(launcher, "collect_identity", return_value=identity), \
                    mock.patch.object(launcher, "verified_tool", return_value=Path("/trusted/tool")), \
                    mock.patch.object(launcher, "run_process", side_effect=fake_run), \
                    mock.patch.object(launcher, "print_report"), \
                    mock.patch("sys.stdout", io.StringIO()):
                launcher.command_scan(layout, args)
            self.assertNotIn("PASSWORD-SENTINEL", "\n".join(captured["command"]))
            self.assertEqual(captured["env"]["VSPHERE_PASSWORD"], "PASSWORD-SENTINEL")
            self.assertIn("VM ; & | $()", captured["command"])

    def test_standalone_scan_dispatches_real_wrapper_without_secret_in_argv(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefix = root / "installed prefix with spaces"
            scanner = prefix / "scanner"
            scanner.mkdir(parents=True)
            source_report = self.make_report(root / "source report")
            output = root / "scan result"
            argv_log = root / "argv.log"
            password_marker = root / "password-ok"
            source_file = scanner / "vsphere.py"
            source_file.write_text("# layout marker\n", encoding="utf-8")
            for name, value in (
                (".terraform-version", "1.15.8\n"),
                (".govc-version", "0.55.1\n"),
                (".jq-version", "1.8.2\n"),
            ):
                (scanner / name).write_text(value, encoding="utf-8")

            if os.name == "nt":
                wrapper = scanner / "scan-vsphere.ps1"
                quote = lambda value: str(value).replace("'", "''")
                wrapper.write_text(
                    """param(
    [string]$SourceVm,
    [string]$OutputDirectory,
    [string]$Govc,
    [string]$Jq,
    [int]$CommandTimeoutSeconds
)
if ($env:VSPHERE_PASSWORD -cne 'PASSWORD-SENTINEL') {{ exit 71 }}
if ($env:OS -cne 'Windows_NT') {{ exit 72 }}
if ($env:TF_CLI_ARGS_apply -or $env:GOVC_PASSWORD -or $env:HTTPS_PROXY) {{ exit 73 }}
[IO.File]::WriteAllLines('{log}', @($SourceVm, $OutputDirectory, $Govc, $Jq))
[IO.File]::WriteAllText('{marker}', 'ok')
Copy-Item -Recurse -LiteralPath '{source}' -Destination $OutputDirectory
""".format(
                        log=quote(argv_log), marker=quote(password_marker), source=quote(source_report)
                    ),
                    encoding="utf-8",
                )
            else:
                wrapper = scanner / "scan-vsphere.sh"
                wrapper.write_text(
                    """#!/bin/sh
set -eu
[ "${{VSPHERE_PASSWORD:-}}" = PASSWORD-SENTINEL ] || exit 71
[ -z "${{TF_CLI_ARGS_apply:-}}${{GOVC_PASSWORD:-}}${{HTTPS_PROXY:-}}" ] || exit 72
: > {log}
for argument in "$@"; do printf '%s\n' "$argument" >> {log}; done
output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-dir) output=$2; shift 2 ;;
    *) shift ;;
  esac
done
printf ok > {marker}
cp -R {source} "$output"
""".format(
                        log=shlex.quote(str(argv_log)),
                        marker=shlex.quote(str(password_marker)),
                        source=shlex.quote(str(source_report)),
                    ),
                    encoding="utf-8",
                )
                wrapper.chmod(0o700)

            layout = launcher.discover_layout(source_file, windows=(os.name == "nt"))
            identity = launcher.Identity("vc.example", "reader", "PASSWORD-SENTINEL")
            args = argparse.Namespace(
                server="vc.example",
                user="reader",
                source_vm="VM name ; & | $()",
                output_dir=str(output),
                ca_cert=None,
                timeout_seconds=60,
            )
            hostile = {
                "TF_CLI_ARGS_apply": "-auto-approve",
                "GOVC_PASSWORD": "INHERITED-SECRET",
                "HTTPS_PROXY": "http://proxy.invalid",
            }
            printed = io.StringIO()
            with mock.patch.dict(os.environ, hostile, clear=False), \
                    mock.patch.object(launcher, "collect_identity", return_value=identity), \
                    mock.patch.object(launcher, "verified_tool", return_value=Path(sys.executable)), \
                    mock.patch.object(launcher.sys, "stdout", printed):
                launcher.command_scan(layout, args)

            self.assertTrue(password_marker.is_file())
            self.assertTrue((output / "inventory.json").is_file())
            arguments = argv_log.read_text(encoding="utf-8")
            self.assertNotIn("PASSWORD-SENTINEL", arguments)
            self.assertIn("VM name ; & | $()", arguments)
            self.assertIn("Контрольные суммы", printed.getvalue())


class ReportTests(LauncherTestCase):
    def test_verifies_and_summarizes_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = self.make_report(Path(temporary) / "scan")
            directory, inventory = launcher.verify_report(str(report))
            self.assertEqual(directory, report.resolve())
            self.assertTrue(inventory["read_only"])
            output = io.StringIO()
            with redirect_stderr(io.StringIO()), mock.patch("sys.stdout", output):
                launcher.print_report(str(report), "summary")
            self.assertIn("tst-win-10-12", output.getvalue())
            self.assertIn("Datastore clusters", output.getvalue())

    def test_rejects_tampered_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = self.make_report(Path(temporary) / "scan")
            (report / "inventory.md").write_text("tampered\n", encoding="utf-8")
            with self.assertRaisesRegex(launcher.LauncherError, "Контрольная сумма"):
                launcher.verify_report(str(report))

    def test_rejects_unexpected_checksum_entry(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = self.make_report(Path(temporary) / "scan")
            with (report / "SHA256SUMS").open("a", encoding="utf-8") as handle:
                handle.write("{}  secret.txt\n".format("0" * 64))
            with self.assertRaisesRegex(launcher.LauncherError, "неожиданный набор"):
                launcher.verify_report(str(report))

    @unittest.skipIf(os.name == "nt", "symlink creation is not always available to unprivileged Windows CI")
    def test_rejects_symlinked_report_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = self.make_report(Path(temporary) / "scan")
            inventory = report / "inventory.md"
            target = report / "actual.md"
            inventory.replace(target)
            inventory.symlink_to(target)
            with self.assertRaisesRegex(launcher.LauncherError, "ссылкой"):
                launcher.verify_report(str(report))


class PlanReceiptTests(LauncherTestCase):
    def test_plan_must_be_direct_child_of_allowed_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            allowed = root / ".plans" / "windows-clone"
            allowed.mkdir(parents=True)
            plan = allowed / "safe.tfplan"
            plan.write_bytes(b"plan")
            resolved, stack = launcher.validate_plan_path(root, str(plan), for_apply=True)
            self.assertEqual(stack, "windows-clone")
            self.assertEqual(resolved, plan.resolve())
            nested = allowed / "nested"
            nested.mkdir()
            external = nested / "bad.tfplan"
            external.write_bytes(b"plan")
            with self.assertRaisesRegex(launcher.LauncherError, "неподдерживаемому|непосредственно"):
                launcher.validate_plan_path(root, str(external), for_apply=True)

    @unittest.skipIf(os.name == "nt", "symlink creation is not always available to unprivileged Windows CI")
    def test_rejects_symlinked_plans_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            external = root / "external" / "windows-clone"
            external.mkdir(parents=True)
            plan = external / "safe.tfplan"
            plan.write_bytes(b"plan")
            (root / ".plans").symlink_to(root / "external", target_is_directory=True)
            with self.assertRaisesRegex(launcher.LauncherError, "symbolic link"):
                launcher.validate_plan_path(root, str(plan), for_apply=True)

    def test_receipt_binds_plan_server_user_backend_and_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            plan_dir = root / ".plans" / "windows-clone"
            plan_dir.mkdir(parents=True)
            plan = plan_dir / "safe.tfplan"
            plan.write_bytes(b"plan-v1")
            identity = launcher.Identity("vc.example", "provisioner", "SECRET")
            launcher.write_plan_receipt(root, plan, "windows-clone", identity)
            receipt = launcher.check_receipt(root, plan, "windows-clone", identity)
            self.assertNotIn("password", receipt)
            plan.write_bytes(b"plan-v2")
            with self.assertRaisesRegex(launcher.LauncherError, "plan_sha256"):
                launcher.check_receipt(root, plan, "windows-clone", identity)

    def test_receipt_rejects_changed_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            plan_dir = root / ".plans" / "vm-clones"
            plan_dir.mkdir(parents=True)
            plan = plan_dir / "safe.tfplan"
            plan.write_bytes(b"plan")
            identity = launcher.Identity("vc.example", "provisioner", "SECRET")
            launcher.write_plan_receipt(root, plan, "vm-clones", identity)
            (root / "stacks" / "vm-clones" / "main.tf").write_text("changed {}\n", encoding="utf-8")
            with self.assertRaisesRegex(launcher.LauncherError, "configuration_sha256"):
                launcher.check_receipt(root, plan, "vm-clones", identity)

    def test_receipt_rejects_changed_local_module(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            plan_dir = root / ".plans" / "vm-clones"
            plan_dir.mkdir(parents=True)
            plan = plan_dir / "safe.tfplan"
            plan.write_bytes(b"plan")
            identity = launcher.Identity("vc.example", "provisioner", "SECRET")
            launcher.write_plan_receipt(root, plan, "vm-clones", identity)
            (root / "modules" / "linux-vm-clone" / "main.tf").write_text(
                "resource \"null_resource\" \"changed\" {}\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(launcher.LauncherError, "configuration_sha256"):
                launcher.check_receipt(root, plan, "vm-clones", identity)

    def test_receipt_rejects_same_backend_type_with_changed_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repo(root)
            stack_dir = root / "stacks" / "vm-clones"
            metadata_dir = stack_dir / ".terraform"
            metadata_dir.mkdir()
            metadata = metadata_dir / "terraform.tfstate"
            metadata.write_text(
                json.dumps({"backend": {"type": "http", "config": {"address": "https://state-a"}}}),
                encoding="utf-8",
            )
            plan_dir = root / ".plans" / "vm-clones"
            plan_dir.mkdir(parents=True)
            plan = plan_dir / "safe.tfplan"
            plan.write_bytes(b"plan")
            identity = launcher.Identity("vc.example", "provisioner", "SECRET")
            launcher.write_plan_receipt(root, plan, "vm-clones", identity)
            metadata.write_text(
                json.dumps({"backend": {"type": "http", "config": {"address": "https://state-b"}}}),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(launcher.LauncherError, "backend"):
                launcher.check_receipt(root, plan, "vm-clones", identity)


class FakeTTY(io.StringIO):
    def __init__(self, value="", tty=True):
        super().__init__(value)
        self.tty = tty

    def isatty(self):
        return self.tty


class ApplyBoundaryTests(LauncherTestCase):
    def apply_args(self, plan: Path):
        return argparse.Namespace(
            plan=str(plan),
            server="vc.example",
            user="provisioner",
            allow_local_state=True,
            timeout_seconds=60,
        )

    def test_apply_requires_tty_before_spawning(self):
        with tempfile.TemporaryDirectory() as temporary:
            layout = self.make_repo(Path(temporary))
            args = self.apply_args(Path(temporary) / "missing.tfplan")
            with mock.patch.object(launcher.sys, "stdin", FakeTTY(tty=False)), \
                    mock.patch.object(launcher.sys, "stdout", FakeTTY(tty=True)), \
                    mock.patch.object(launcher, "run_process") as run_mock:
                with self.assertRaisesRegex(launcher.LauncherError, "интерактивном"):
                    launcher.command_apply(layout, args)
            run_mock.assert_not_called()

    def test_windows_clone_apply_uses_reviewed_wrapper_and_one_shot_flag(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            layout = self.make_repo(root)
            plan_dir = root / ".plans" / "windows-clone"
            plan_dir.mkdir(parents=True)
            plan = plan_dir / "safe.tfplan"
            plan.write_bytes(b"plan")
            identity = launcher.Identity("vc.example", "provisioner", "PASSWORD-SENTINEL")
            launcher.write_plan_receipt(root, plan, "windows-clone", identity)
            phrase = "APPLY " + launcher.sha256_file(plan)[:12]
            stdin = FakeTTY("SOURCE OFF\n{}\n".format(phrase))
            stdout = FakeTTY()
            captured = {}

            def fake_run(command, env, cwd, timeout):
                captured["command"] = list(command)
                captured["env"] = dict(env)

            with mock.patch.object(launcher.sys, "stdin", stdin), \
                    mock.patch.object(launcher.sys, "stdout", stdout), \
                    mock.patch.object(launcher, "collect_identity", return_value=identity), \
                    mock.patch.object(launcher, "show_plan"), \
                    mock.patch.object(launcher, "verified_tool", return_value=Path("/trusted/tool")), \
                    mock.patch.object(launcher, "run_process", side_effect=fake_run), \
                    mock.patch.object(launcher, "check_receipt", wraps=launcher.check_receipt) as check_mock:
                launcher.command_apply(layout, self.apply_args(plan))

            self.assertEqual(check_mock.call_count, 2)
            self.assertIn("apply-reviewed-plan.sh", " ".join(captured["command"]))
            self.assertEqual(captured["env"]["ALLOW_WINDOWS_CLONE_APPLY"], "yes")
            self.assertNotIn("ALLOW_VM_APPLY", captured["env"])
            self.assertEqual(captured["env"]["VSPHERE_PASSWORD"], "PASSWORD-SENTINEL")
            self.assertNotIn("PASSWORD-SENTINEL", stdout.getvalue())

    def test_apply_rejects_plan_changed_while_shown(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            layout = self.make_repo(root)
            plan_dir = root / ".plans" / "vm-clones"
            plan_dir.mkdir(parents=True)
            plan = plan_dir / "safe.tfplan"
            plan.write_bytes(b"plan-v1")
            identity = launcher.Identity("vc.example", "provisioner", "SECRET")
            launcher.write_plan_receipt(root, plan, "vm-clones", identity)

            def mutate_plan(*_args):
                plan.write_bytes(b"plan-v2")

            with mock.patch.object(launcher.sys, "stdin", FakeTTY()), \
                    mock.patch.object(launcher.sys, "stdout", FakeTTY()), \
                    mock.patch.object(launcher, "collect_identity", return_value=identity), \
                    mock.patch.object(launcher, "show_plan", side_effect=mutate_plan), \
                    mock.patch.object(launcher, "run_process") as run_mock:
                with self.assertRaisesRegex(launcher.LauncherError, "изменился"):
                    launcher.command_apply(layout, self.apply_args(plan))
            run_mock.assert_not_called()


class ParserTests(unittest.TestCase):
    def test_stdio_is_utf8_when_parent_pipe_is_cp1252(self):
        stdout_bytes = io.BytesIO()
        stderr_bytes = io.BytesIO()
        stdout = io.TextIOWrapper(stdout_bytes, encoding="cp1252")
        stderr = io.TextIOWrapper(stderr_bytes, encoding="cp1252")
        with mock.patch.object(launcher.sys, "stdout", stdout), \
                mock.patch.object(launcher.sys, "stderr", stderr):
            launcher.configure_stdio()
            launcher.sys.stdout.write("Учётная запись")
            launcher.sys.stderr.write("Ошибка")
            launcher.sys.stdout.flush()
            launcher.sys.stderr.flush()
        self.assertEqual(stdout_bytes.getvalue().decode("utf-8"), "Учётная запись")
        self.assertEqual(stderr_bytes.getvalue().decode("utf-8"), "Ошибка")

    def test_no_password_cli_option_exists(self):
        parser = launcher.build_parser()
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser.parse_args(["scan", "--password", "SECRET"])

    def test_timeout_must_be_bounded(self):
        with self.assertRaises(launcher.LauncherError):
            launcher.positive_timeout(0)
        with self.assertRaises(launcher.LauncherError):
            launcher.positive_timeout(86401)

    def test_server_rejects_credentials_and_insecure_scheme(self):
        with self.assertRaises(launcher.LauncherError):
            launcher.normalize_server("http://vc.example")
        with self.assertRaises(launcher.LauncherError):
            launcher.normalize_server("https://user:password@vc.example/sdk")
        self.assertEqual(launcher.normalize_server("https://vc.example/sdk"), "vc.example")


if __name__ == "__main__":
    unittest.main()
