#!/usr/bin/env python3
"""Cross-platform launcher for the guarded vSphere/Terraform workflows."""

from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Mapping, Optional, Sequence, Tuple
from urllib.parse import urlsplit


MIN_PYTHON = (3, 9)
REPORT_FILES = {
    "inventory.json",
    "inventory.md",
    "inventory-tree.txt",
    "windows-clone.generated.tfvars",
}
STACKS = ("inventory", "vm-clones", "windows-clone")
APPLY_STACKS = ("vm-clones", "windows-clone")
RECEIPT_SUFFIX = ".receipt.json"
COUNT_KEYS = (
    "datacenters",
    "clusters",
    "hosts",
    "datastores",
    "storage_pods",
    "networks",
    "virtual_machines",
    "templates",
)


class LauncherError(RuntimeError):
    """A safe, user-facing launcher failure."""


@dataclass(frozen=True)
class Layout:
    base_dir: Path
    scripts_dir: Path
    repo_root: Optional[Path]
    prefix: Optional[Path]
    windows: bool

    @property
    def full_workflow(self) -> bool:
        return self.repo_root is not None


@dataclass(frozen=True)
class Identity:
    server: str
    username: str
    password: str


def discover_layout(source: Optional[Path] = None, windows: Optional[bool] = None) -> Layout:
    base = (source or Path(__file__)).resolve().parent
    is_windows = os.name == "nt" if windows is None else windows
    repo_scripts = base / "scripts"
    if (repo_scripts / ("scan-vsphere.ps1" if is_windows else "scan-vsphere.sh")).is_file():
        return Layout(base, repo_scripts, base, None, is_windows)
    local_scanner = base / ("scan-vsphere.ps1" if is_windows else "scan-vsphere.sh")
    if local_scanner.is_file():
        return Layout(base, base, None, base.parent, is_windows)
    raise LauncherError("Не найден каталог scripts или установленный offline scanner.")


def require_python() -> None:
    if sys.version_info < MIN_PYTHON:
        raise LauncherError("Требуется Python 3.9 или новее.")


def require_full_layout(layout: Layout) -> Path:
    if layout.repo_root is None:
        raise LauncherError(
            "Для plan/show/apply запустите vsphere.py из рабочей копии репозитория; "
            "standalone offline scanner поддерживает check/scan/report."
        )
    return layout.repo_root


def executable_name(name: str, windows: bool) -> str:
    return name + ".exe" if windows and not name.lower().endswith(".exe") else name


def find_tool(layout: Layout, name: str) -> Path:
    executable = executable_name(name, layout.windows)
    if layout.prefix is not None:
        bundled = layout.prefix / "bin" / executable
        if bundled.is_file() and not bundled.is_symlink():
            return bundled.resolve()
    found = shutil.which(executable)
    if not found and not layout.windows:
        found = shutil.which(name)
    if not found:
        raise LauncherError("Не найден инструмент: {}".format(executable))
    path = Path(found).resolve()
    if not path.is_file():
        raise LauncherError("Инструмент не является обычным файлом: {}".format(path))
    return path


def read_pin(layout: Layout, filename: str) -> Optional[str]:
    candidates = [layout.base_dir / filename]
    if layout.repo_root is not None:
        candidates.insert(0, layout.repo_root / filename)
    if layout.prefix is not None:
        candidates.append(layout.prefix / filename)
    for candidate in candidates:
        if candidate.is_file() and not candidate.is_symlink():
            value = candidate.read_text(encoding="utf-8").strip()
            if value:
                return value
    return None


def sanitized_environment(
    layout: Layout,
    identity: Optional[Identity] = None,
    apply_flag: Optional[str] = None,
) -> Dict[str, str]:
    allowed = {
        "HOME",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "TMP",
        "TEMP",
        "TERM",
        "COLORTERM",
        "LANG",
        "TZ",
        "SYSTEMROOT",
        "WINDIR",
        "OS",
        "PROCESSOR_ARCHITECTURE",
        "PROCESSOR_ARCHITEW6432",
        "COMSPEC",
        "PATHEXT",
        "USERPROFILE",
        "HOMEDRIVE",
        "HOMEPATH",
        "LOCALAPPDATA",
        "APPDATA",
        "PROGRAMDATA",
        "PROGRAMFILES",
        "PROGRAMFILES(X86)",
        "COMMONPROGRAMFILES",
        "COMMONPROGRAMFILES(X86)",
        "COMMONPROGRAMW6432",
    }
    env: Dict[str, str] = {}
    for key, value in os.environ.items():
        upper = key.upper()
        if upper in allowed or upper.startswith("LC_"):
            env[upper if os.name == "nt" else key] = value
    if os.name == "nt":
        system_root = env.get("SYSTEMROOT") or env.get("WINDIR", r"C:\Windows")
        trusted_path = [
            str(Path(system_root) / "System32"),
            str(Path(system_root)),
            str(Path(system_root) / "System32" / "WindowsPowerShell" / "v1.0"),
        ]
    else:
        trusted_path = ["/usr/sbin", "/usr/bin", "/sbin", "/bin"]
    if layout.prefix is not None:
        bin_dir = layout.prefix / "bin"
        trusted_path.insert(0, str(bin_dir))
        cli_config = layout.prefix / "terraform.rc"
        if cli_config.is_file() and not cli_config.is_symlink():
            env["TF_CLI_CONFIG_FILE"] = str(cli_config.resolve())
    env["PATH"] = os.pathsep.join(trusted_path)
    env["CHECKPOINT_DISABLE"] = "1"
    env["TF_IN_AUTOMATION"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    if identity is not None:
        env["VSPHERE_SERVER"] = identity.server
        env["VSPHERE_USER"] = identity.username
        env["VSPHERE_PASSWORD"] = identity.password
    if apply_flag is not None:
        env[apply_flag] = "yes"
    return env


def terraform_environment(
    layout: Layout,
    terraform: Path,
    identity: Optional[Identity] = None,
    apply_flag: Optional[str] = None,
    include_backend_credentials: bool = True,
) -> Dict[str, str]:
    env = sanitized_environment(layout, identity, apply_flag)
    if include_backend_credentials:
        for key, value in os.environ.items():
            if key.upper().startswith("TF_HTTP_"):
                env[key.upper() if os.name == "nt" else key] = value
    sibling_config = terraform.parent.parent / "terraform.rc"
    if sibling_config.is_file() and not sibling_config.is_symlink():
        env["TF_CLI_CONFIG_FILE"] = str(sibling_config.resolve())
    else:
        # Avoid inherited ~/.terraformrc provider dev_overrides. An empty CLI
        # config keeps Terraform's normal registry behavior when online.
        env["TF_CLI_CONFIG_FILE"] = os.devnull
    return env


def powershell_path() -> str:
    system_root = os.environ.get("SystemRoot") or os.environ.get("WINDIR")
    if system_root:
        candidate = Path(system_root) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
        if candidate.is_file():
            return str(candidate)
    found = shutil.which("powershell.exe")
    if not found:
        raise LauncherError("Не найден Windows PowerShell 5.1.")
    return found


def wrapper_command(layout: Layout, name: str, arguments: Sequence[str]) -> List[str]:
    extension = ".ps1" if layout.windows else ".sh"
    script = layout.scripts_dir / (name + extension)
    if not script.is_file() or script.is_symlink():
        raise LauncherError("Не найден доверенный wrapper: {}".format(script))
    if layout.windows:
        return [
            powershell_path(),
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(script.resolve()),
        ] + list(arguments)
    return ["/bin/sh", str(script.resolve())] + list(arguments)


def terminate_process_tree(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        taskkill = shutil.which("taskkill.exe") or shutil.which("taskkill")
        if taskkill:
            subprocess.run(
                [taskkill, "/PID", str(process.pid), "/T", "/F"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                shell=False,
                check=False,
            )
        else:
            process.terminate()
    else:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            process.kill()
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)


def run_process(
    command: Sequence[str],
    env: Mapping[str, str],
    cwd: Path,
    timeout_seconds: int,
) -> None:
    creation_flags = 0
    popen_extra = {}
    if os.name == "nt":
        creation_flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        popen_extra["start_new_session"] = True
    try:
        process = subprocess.Popen(
            list(command),
            cwd=str(cwd),
            env=dict(env),
            shell=False,
            creationflags=creation_flags,
            **popen_extra,
        )
    except OSError as exc:
        raise LauncherError("Не удалось запустить дочерний процесс: {}".format(exc))
    try:
        return_code = process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        terminate_process_tree(process)
        raise LauncherError("Команда остановлена по тайм-ауту ({} секунд).".format(timeout_seconds))
    except KeyboardInterrupt:
        terminate_process_tree(process)
        raise
    if return_code != 0:
        raise LauncherError("Команда завершилась с кодом {}.".format(return_code))


def capture_tool(command: Sequence[str], env: Mapping[str, str], cwd: Path) -> str:
    try:
        result = subprocess.run(
            list(command),
            cwd=str(cwd),
            env=dict(env),
            shell=False,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LauncherError("Не удалось проверить инструмент: {}".format(exc))
    output = result.stdout.decode("utf-8", errors="replace").strip()
    if result.returncode != 0:
        raise LauncherError("Проверка инструмента завершилась с кодом {}.".format(result.returncode))
    return output


def verified_tool(layout: Layout, name: str) -> Path:
    tool = find_tool(layout, name)
    pin_file = {
        "terraform": ".terraform-version",
        "govc": ".govc-version",
        "jq": ".jq-version",
    }[name]
    pin = read_pin(layout, pin_file)
    if not pin:
        raise LauncherError("Не найден файл закреплённой версии: {}".format(pin_file))
    argument = "--version" if name == "jq" else "version"
    tool_env = (
        terraform_environment(layout, tool, include_backend_credentials=False)
        if name == "terraform" else sanitized_environment(layout)
    )
    output = capture_tool(
        [str(tool), argument],
        tool_env,
        layout.repo_root or layout.base_dir,
    )
    first_line = output.splitlines()[0] if output else ""
    expected = {
        "terraform": "Terraform v" + pin,
        "govc": "govc " + pin,
        "jq": "jq-" + pin,
    }[name]
    if first_line != expected:
        raise LauncherError("{}: ожидалось '{}', получено '{}'.".format(name, expected, first_line))
    return tool


def normalize_server(value: str) -> str:
    candidate = value.strip()
    if not candidate:
        raise LauncherError("Адрес vCenter не задан.")
    parsed = urlsplit(candidate if "://" in candidate else "//" + candidate)
    if parsed.scheme and parsed.scheme.lower() != "https":
        raise LauncherError("vCenter должен использовать HTTPS.")
    if parsed.username is not None or parsed.password is not None:
        raise LauncherError("Не помещайте логин или пароль в адрес vCenter.")
    if parsed.query or parsed.fragment:
        raise LauncherError("Адрес vCenter не должен содержать query или fragment.")
    if parsed.path.rstrip("/") not in ("", "/sdk"):
        raise LauncherError("Путь vCenter должен быть пустым или /sdk.")
    if not parsed.hostname:
        raise LauncherError("Некорректный адрес vCenter.")
    return parsed.netloc


def prompt_value(label: str, supplied: Optional[str], environment_name: str) -> str:
    value = supplied or os.environ.get(environment_name, "")
    if not value and sys.stdin.isatty():
        value = input(label).strip()
    if not value:
        raise LauncherError("Не задано значение {}.".format(environment_name))
    return value


def collect_identity(args: argparse.Namespace) -> Identity:
    server = normalize_server(prompt_value("vCenter: ", getattr(args, "server", None), "VSPHERE_SERVER"))
    username = prompt_value("Учётная запись: ", getattr(args, "user", None), "VSPHERE_USER").strip()
    password = os.environ.get("VSPHERE_PASSWORD", "")
    if not password:
        if not sys.stdin.isatty():
            raise LauncherError("VSPHERE_PASSWORD не задан, а интерактивный ввод недоступен.")
        password = getpass.getpass("Пароль vCenter: ")
    if not password:
        raise LauncherError("Пароль vCenter не задан.")
    return Identity(server, username, password)


def safe_existing_file(value: str, description: str) -> Path:
    original = Path(value).expanduser()
    if original.is_symlink():
        raise LauncherError("{} не должен быть symbolic link.".format(description))
    try:
        resolved = original.resolve(strict=True)
    except FileNotFoundError:
        raise LauncherError("{} не найден: {}".format(description, original))
    if not resolved.is_file():
        raise LauncherError("{} не является обычным файлом: {}".format(description, resolved))
    return resolved


def protect_private_path(path: Path, directory: bool) -> None:
    if os.name != "nt":
        path.chmod(0o700 if directory else 0o600)
        return
    acl_script = r"""param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][ValidateSet('Directory', 'File')][string]$Kind
)
$ErrorActionPreference = 'Stop'
$Sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
if ($Kind -ceq 'Directory') {
    $Acl = New-Object -TypeName System.Security.AccessControl.DirectorySecurity
    $Inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor `
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
}
else {
    $Acl = New-Object -TypeName System.Security.AccessControl.FileSecurity
    $Inheritance = [System.Security.AccessControl.InheritanceFlags]::None
}
$Rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
    $Sid,
    [System.Security.AccessControl.FileSystemRights]::FullControl,
    $Inheritance,
    [System.Security.AccessControl.PropagationFlags]::None,
    [System.Security.AccessControl.AccessControlType]::Allow
)
$Acl.SetOwner($Sid)
$Acl.SetAccessRuleProtection($true, $false)
[void]$Acl.AddAccessRule($Rule)
if ($Kind -ceq 'Directory') {
    [System.IO.Directory]::SetAccessControl($Target, $Acl)
}
else {
    [System.IO.File]::SetAccessControl($Target, $Acl)
}
"""
    descriptor, script_name = tempfile.mkstemp(suffix=".ps1")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\r\n") as handle:
            handle.write(acl_script)
        result = subprocess.run(
            [
                powershell_path(),
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-File",
                script_name,
                "-Target",
                str(path),
                "-Kind",
                "Directory" if directory else "File",
            ],
            shell=False,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LauncherError("Не удалось установить приватный Windows ACL: {}".format(exc))
    finally:
        try:
            Path(script_name).unlink()
        except OSError:
            pass
    if result.returncode != 0:
        raise LauncherError("PowerShell не смог установить приватный Windows ACL.")


def default_scan_output(layout: Layout) -> Path:
    root = layout.repo_root or Path.cwd()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return (root / "scan-results" / ("vsphere-scan-" + stamp)).resolve()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_report(directory_value: str) -> Tuple[Path, dict]:
    original = Path(directory_value).expanduser()
    if original.is_symlink():
        raise LauncherError("Каталог отчёта не должен быть symbolic link.")
    try:
        directory = original.resolve(strict=True)
    except FileNotFoundError:
        raise LauncherError("Каталог отчёта не найден: {}".format(original))
    if not directory.is_dir():
        raise LauncherError("Ожидался каталог отчёта: {}".format(directory))
    checksum_path = directory / "SHA256SUMS"
    if checksum_path.is_symlink() or not checksum_path.is_file():
        raise LauncherError("В отчёте отсутствует обычный файл SHA256SUMS.")
    entries: Dict[str, str] = {}
    pattern = re.compile(r"^([0-9a-f]{64})  ([^/\\]+)$")
    for line in checksum_path.read_text(encoding="utf-8").splitlines():
        match = pattern.fullmatch(line)
        if not match or match.group(2) in entries:
            raise LauncherError("Некорректный SHA256SUMS в отчёте.")
        entries[match.group(2)] = match.group(1)
    if set(entries) != REPORT_FILES:
        raise LauncherError("SHA256SUMS содержит неожиданный набор файлов.")
    for name, expected in entries.items():
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise LauncherError("Файл отчёта отсутствует или является ссылкой: {}".format(name))
        if sha256_file(path) != expected:
            raise LauncherError("Контрольная сумма отчёта не совпала: {}".format(name))
    try:
        inventory = json.loads((directory / "inventory.json").read_text(encoding="utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise LauncherError("inventory.json повреждён: {}".format(exc))
    if not isinstance(inventory, dict) or \
            inventory.get("schema_version") != "1.0.0" or inventory.get("read_only") is not True:
        raise LauncherError("Это не подтверждённый read-only inventory schema v1.")
    if not isinstance(inventory.get("counts"), dict) or \
            not isinstance(inventory.get("clone_candidate"), dict):
        raise LauncherError("inventory.json не соответствует ожидаемой структуре отчёта.")
    if any(
        type(inventory["counts"].get(key)) is not int or inventory["counts"][key] < 0
        for key in COUNT_KEYS
    ):
        raise LauncherError("inventory.json содержит некорректные inventory counts.")
    checks = inventory["clone_candidate"].get("checks")
    if not isinstance(checks, list) or any(not isinstance(item, dict) for item in checks):
        raise LauncherError("inventory.json содержит некорректные clone checks.")
    return directory, inventory


def terminal_safe(value: object, preserve_layout: bool = False) -> str:
    text = str(value)
    result = []
    for character in text:
        if preserve_layout and character in ("\n", "\t"):
            result.append(character)
        elif unicodedata.category(character) in ("Cc", "Cf"):
            codepoint = ord(character)
            result.append("\\x{:02x}".format(codepoint) if codepoint <= 0xFF else "\\u{:04x}".format(codepoint))
        else:
            result.append(character)
    return "".join(result)


def print_report(directory_value: str, report_format: str = "summary") -> None:
    directory, inventory = verify_report(directory_value)
    if report_format == "summary":
        counts = inventory.get("counts", {})
        print("Контрольные суммы read-only отчёта совпали: {}".format(directory))
        labels = (
            ("datacenters", "Datacenter"),
            ("clusters", "Clusters"),
            ("hosts", "Hosts"),
            ("datastores", "Datastores"),
            ("storage_pods", "Datastore clusters"),
            ("networks", "Networks"),
            ("virtual_machines", "VM"),
            ("templates", "Templates"),
        )
        for key, label in labels:
            print("  {:20} {}".format(label + ":", counts.get(key, 0)))
        candidate = inventory.get("clone_candidate") or {}
        print("  Source VM: {}".format(terminal_safe(
            candidate.get("source_vm_path") or "не найдена однозначно"
        )))
        for check in candidate.get("checks") or []:
            print("  [{:4}] {} — {}".format(
                str(check.get("status", "?")).upper(),
                terminal_safe(check.get("name", "check")),
                terminal_safe(check.get("message", "")),
            ))
        return
    filename = {
        "markdown": "inventory.md",
        "tree": "inventory-tree.txt",
        "json": "inventory.json",
    }[report_format]
    document = (directory / filename).read_text(encoding="utf-8")
    sys.stdout.write(terminal_safe(document, preserve_layout=True))


def stack_config_digest(repo_root: Path, stack: str) -> str:
    stack_dir = repo_root / "stacks" / stack
    files = list(stack_dir.glob("*.tf"))
    lock_file = stack_dir / ".terraform.lock.hcl"
    if lock_file.is_file():
        files.append(lock_file)
    modules_dir = repo_root / "modules"
    if modules_dir.is_dir():
        files.extend(modules_dir.glob("**/*.tf"))
    files = sorted(set(files), key=lambda item: item.relative_to(repo_root).as_posix())
    if not files:
        raise LauncherError("Не найдена конфигурация stack: {}".format(stack))
    digest = hashlib.sha256()
    for path in files:
        if path.is_symlink() or not path.is_file():
            raise LauncherError("Конфигурация содержит недопустимую ссылку: {}".format(path))
        digest.update(path.relative_to(repo_root).as_posix().encode("utf-8") + b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def backend_identity(repo_root: Path, stack: str) -> dict:
    state = repo_root / "stacks" / stack / ".terraform" / "terraform.tfstate"
    if not state.is_file() or state.is_symlink():
        return {"type": "local-or-uninitialized", "metadata_sha256": "absent"}
    try:
        payload = json.loads(state.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {"type": "unknown", "metadata_sha256": sha256_file(state)}
    backend = payload.get("backend") or {}
    return {
        "type": str(backend.get("type") or "local-or-uninitialized"),
        "metadata_sha256": sha256_file(state),
    }


def receipt_path(plan: Path) -> Path:
    return plan.with_name(plan.name + RECEIPT_SUFFIX)


def write_private_json(path: Path, payload: dict) -> None:
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex + ".tmp")
    descriptor = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(str(temporary), str(path))
        try:
            protect_private_path(path, directory=False)
        except LauncherError:
            path.unlink(missing_ok=True)
            raise
    finally:
        if temporary.exists():
            temporary.unlink()


def write_plan_receipt(repo_root: Path, plan: Path, stack: str, identity: Identity) -> Path:
    payload = {
        "version": 1,
        "created_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stack": stack,
        "plan_sha256": sha256_file(plan),
        "configuration_sha256": stack_config_digest(repo_root, stack),
        "server": identity.server,
        "username": identity.username,
        "backend": backend_identity(repo_root, stack),
    }
    path = receipt_path(plan)
    write_private_json(path, payload)
    return path


def read_plan_receipt(plan: Path) -> dict:
    path = receipt_path(plan)
    if path.is_symlink() or not path.is_file():
        raise LauncherError("Нет квитанции launcher-а; создайте plan командой python vsphere.py plan.")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LauncherError("Квитанция plan повреждена: {}".format(exc))
    if payload.get("version") != 1:
        raise LauncherError("Неподдерживаемая версия квитанции plan.")
    return payload


def validate_plan_path(repo_root: Path, value: str, for_apply: bool = False) -> Tuple[Path, str]:
    plans_root = repo_root / ".plans"
    if plans_root.is_symlink():
        raise LauncherError("Каталог .plans не должен быть symbolic link.")
    plan = safe_existing_file(value, "Plan")
    if plan.suffix.lower() != ".tfplan":
        raise LauncherError("Ожидался файл .tfplan.")
    stack = plan.parent.name
    allowed = APPLY_STACKS if for_apply else STACKS
    if stack not in allowed:
        raise LauncherError("Plan относится к неподдерживаемому stack.")
    stack_parent = plans_root / stack
    if stack_parent.is_symlink():
        raise LauncherError("Каталог stack внутри .plans не должен быть symbolic link.")
    expected_parent = stack_parent.resolve()
    if plan.parent != expected_parent:
        raise LauncherError("Принимаются только plan непосредственно из .plans/<stack>.")
    return plan, stack


def check_receipt(repo_root: Path, plan: Path, stack: str, identity: Identity) -> dict:
    receipt = read_plan_receipt(plan)
    expected = {
        "stack": stack,
        "plan_sha256": sha256_file(plan),
        "configuration_sha256": stack_config_digest(repo_root, stack),
        "server": identity.server,
        "username": identity.username,
        "backend": backend_identity(repo_root, stack),
    }
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise LauncherError("Plan больше не совпадает с квитанцией: {}.".format(key))
    return receipt


def command_check(layout: Layout, _args: argparse.Namespace) -> None:
    requirements = ["govc", "jq"]
    if layout.full_workflow or (layout.prefix and (layout.prefix / "bin").is_dir()):
        requirements.insert(0, "terraform")
    print("Python: {}.{}.{}".format(*sys.version_info[:3]))
    print("Режим: {}".format("полный repo workflow" if layout.full_workflow else "standalone scanner"))
    for tool_name in requirements:
        tool = verified_tool(layout, tool_name)
        pin = read_pin(layout, ".{}-version".format(tool_name))
        display = "Terraform v{}".format(pin) if tool_name == "terraform" else (
            "jq-{}".format(pin) if tool_name == "jq" else "govc {}".format(pin)
        )
        print("{}: {} ({})".format(tool_name, display, tool))
    print("Проверка launcher-а пройдена.")


def command_scan(layout: Layout, args: argparse.Namespace) -> None:
    identity = collect_identity(args)
    govc = verified_tool(layout, "govc")
    jq = verified_tool(layout, "jq")
    output = Path(args.output_dir).expanduser().resolve() if args.output_dir else default_scan_output(layout)
    if output.exists():
        raise LauncherError("Каталог результата уже существует: {}".format(output))
    ca_cert = safe_existing_file(args.ca_cert, "CA certificate") if args.ca_cert else None
    source_vm = args.source_vm.strip()
    if not source_vm:
        raise LauncherError("Source VM не задана.")
    arguments: List[str]
    if layout.windows:
        arguments = [
            "-SourceVm", source_vm,
            "-OutputDirectory", str(output),
            "-Govc", str(govc),
            "-Jq", str(jq),
        ]
        if ca_cert:
            arguments += ["-CaCert", str(ca_cert)]
        arguments += ["-CommandTimeoutSeconds", str(min(args.timeout_seconds, 3600))]
    else:
        arguments = [
            "--source-vm", source_vm,
            "--output-dir", str(output),
            "--govc", str(govc),
            "--jq", str(jq),
        ]
        if ca_cert:
            arguments += ["--ca-cert", str(ca_cert)]
    print("READ ONLY scan")
    print("  vCenter: {}".format(identity.server))
    print("  Учётная запись: {}".format(identity.username))
    print("  Source VM: {}".format(source_vm))
    print("  Результат: {}".format(output))
    env = sanitized_environment(layout, identity)
    try:
        run_process(
            wrapper_command(layout, "scan-vsphere", arguments),
            env,
            layout.repo_root or layout.base_dir,
            args.timeout_seconds,
        )
    finally:
        env.pop("VSPHERE_PASSWORD", None)
    print_report(str(output), "summary")


def command_report(_layout: Layout, args: argparse.Namespace) -> None:
    print_report(args.directory, args.format)


def command_plan(layout: Layout, args: argparse.Namespace) -> None:
    repo_root = require_full_layout(layout)
    terraform = verified_tool(layout, "terraform")
    jq = verified_tool(layout, "jq") if not layout.windows else None
    stack = args.stack
    var_file = safe_existing_file(args.var_file, "tfvars") if args.var_file else None
    if stack != "inventory" and var_file is None:
        raise LauncherError("Для {} требуется --var-file.".format(stack))
    identity = collect_identity(args)
    plan_dir = repo_root / ".plans" / stack
    if (repo_root / ".plans").is_symlink() or plan_dir.is_symlink():
        raise LauncherError("Каталоги .plans не должны быть symbolic links.")
    plan_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    protect_private_path(plan_dir, directory=True)
    before = set(plan_dir.glob("*.tfplan")) if plan_dir.is_dir() else set()
    if layout.windows:
        arguments = ["-Stack", stack, "-Terraform", str(terraform)]
        if var_file:
            arguments += ["-VarFile", str(var_file)]
    else:
        arguments = [stack]
        if var_file:
            arguments.append(str(var_file))
    print("Terraform plan (изменения ещё не применяются)")
    print("  vCenter: {}".format(identity.server))
    print("  Учётная запись: {}".format(identity.username))
    print("  Stack: {}".format(stack))
    env = terraform_environment(layout, terraform, identity)
    if jq is not None:
        env["JQ_BIN"] = str(jq)
    if not layout.windows:
        env["TF_BIN"] = str(terraform)
    try:
        run_process(
            wrapper_command(layout, "plan", arguments),
            env,
            repo_root,
            args.timeout_seconds,
        )
    finally:
        env.pop("VSPHERE_PASSWORD", None)
    after = set(plan_dir.glob("*.tfplan")) if plan_dir.is_dir() else set()
    created = sorted(after - before, key=lambda item: item.stat().st_mtime_ns)
    if len(created) != 1:
        raise LauncherError("Не удалось однозначно определить новый plan.")
    plan = created[0].resolve()
    try:
        protect_private_path(plan, directory=False)
        receipt = write_plan_receipt(repo_root, plan, stack, identity)
    except LauncherError:
        try:
            plan.unlink()
        except OSError:
            pass
        raise
    print("Plan: {}".format(plan))
    print("Квитанция проверки: {}".format(receipt))
    print("Следующий шаг: python vsphere.py show \"{}\"".format(plan))


def show_plan(layout: Layout, plan: Path, stack: str, timeout_seconds: int) -> None:
    repo_root = require_full_layout(layout)
    terraform = verified_tool(layout, "terraform")
    command = [
        str(terraform),
        "-chdir={}".format(repo_root / "stacks" / stack),
        "show",
        str(plan),
    ]
    run_process(
        command,
        terraform_environment(layout, terraform, include_backend_credentials=False),
        repo_root,
        timeout_seconds,
    )


def command_show(layout: Layout, args: argparse.Namespace) -> None:
    repo_root = require_full_layout(layout)
    plan, stack = validate_plan_path(repo_root, args.plan, for_apply=False)
    show_plan(layout, plan, stack, args.timeout_seconds)
    print("SHA-256: {}".format(sha256_file(plan)))


def command_apply(layout: Layout, args: argparse.Namespace) -> None:
    repo_root = require_full_layout(layout)
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise LauncherError("Apply разрешён только в интерактивном терминале.")
    plan, stack = validate_plan_path(repo_root, args.plan, for_apply=True)
    identity = collect_identity(args)
    receipt = check_receipt(repo_root, plan, stack, identity)
    current_backend = receipt["backend"]["type"]
    if current_backend in ("local", "local-or-uninitialized", "unknown") and not args.allow_local_state:
        raise LauncherError(
            "Apply с local/uninitialized state заблокирован. Настройте remote backend "
            "или осознанно добавьте --allow-local-state."
        )
    if args.allow_local_state and current_backend in ("local", "local-or-uninitialized", "unknown"):
        print("ВНИМАНИЕ: используется локальный state; обеспечьте его резервное копирование и блокировку.")
    hash_before = sha256_file(plan)
    print("Показываю сохранённый plan перед apply:")
    show_plan(layout, plan, stack, args.timeout_seconds)
    if sha256_file(plan) != hash_before:
        raise LauncherError("Plan изменился во время просмотра.")
    print("Цель apply:")
    print("  vCenter: {}".format(identity.server))
    print("  Учётная запись: {}".format(identity.username))
    print("  Stack: {}".format(stack))
    print("  Backend: {}".format(current_backend))
    print("  SHA-256: {}".format(hash_before))
    if stack == "windows-clone":
        powered_off = input("Введите SOURCE OFF, подтвердив повторную проверку выключенной source VM: ")
        if powered_off != "SOURCE OFF":
            raise LauncherError("Подтверждение выключенной source VM не получено.")
    phrase = "APPLY " + hash_before[:12]
    confirmation = input("Для применения введите точно '{}': ".format(phrase))
    if confirmation != phrase:
        raise LauncherError("Apply отменён: подтверждение не совпало.")
    if sha256_file(plan) != hash_before:
        raise LauncherError("Plan изменился после подтверждения.")
    check_receipt(repo_root, plan, stack, identity)
    terraform = verified_tool(layout, "terraform")
    jq = verified_tool(layout, "jq") if not layout.windows else None
    flag = "ALLOW_WINDOWS_CLONE_APPLY" if stack == "windows-clone" else "ALLOW_VM_APPLY"
    if layout.windows:
        arguments = ["-Plan", str(plan), "-Terraform", str(terraform)]
    else:
        arguments = [str(plan)]
    env = terraform_environment(layout, terraform, identity, flag)
    if jq is not None:
        env["JQ_BIN"] = str(jq)
    if not layout.windows:
        env["TF_BIN"] = str(terraform)
    try:
        run_process(
            wrapper_command(layout, "apply-reviewed-plan", arguments),
            env,
            repo_root,
            args.timeout_seconds,
        )
    finally:
        env.pop("VSPHERE_PASSWORD", None)
        env.pop(flag, None)


def add_identity_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--server", help="vCenter hostname[:port], без credentials")
    parser.add_argument("--user", help="учётная запись vCenter")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="vsphere.py",
        description="Безопасная запускалка read-only discovery и Terraform workflow.",
    )
    subparsers = parser.add_subparsers(dest="command")

    subparsers.add_parser("check", help="проверить Python, tools и версии")

    scan = subparsers.add_parser("scan", help="выполнить полный read-only scan")
    add_identity_options(scan)
    scan.add_argument("--source-vm", default="tst-win-10-12")
    scan.add_argument("--output-dir")
    scan.add_argument("--ca-cert")
    scan.add_argument("--timeout-seconds", type=int, default=3600)

    report = subparsers.add_parser("report", help="проверить и показать отчёт")
    report.add_argument("directory")
    report.add_argument("--format", choices=("summary", "markdown", "tree", "json"), default="summary")

    plan = subparsers.add_parser("plan", help="создать policy-проверенный Terraform plan")
    add_identity_options(plan)
    plan.add_argument("--stack", choices=STACKS, default="windows-clone")
    plan.add_argument("--var-file")
    plan.add_argument("--timeout-seconds", type=int, default=3600)

    show = subparsers.add_parser("show", help="показать сохранённый plan")
    show.add_argument("plan")
    show.add_argument("--timeout-seconds", type=int, default=600)

    apply_parser = subparsers.add_parser("apply", help="применить только проверенный plan")
    add_identity_options(apply_parser)
    apply_parser.add_argument("plan")
    apply_parser.add_argument("--allow-local-state", action="store_true")
    apply_parser.add_argument("--timeout-seconds", type=int, default=7200)
    return parser


def positive_timeout(value: int) -> None:
    if value < 1 or value > 86400:
        raise LauncherError("timeout-seconds должен быть от 1 до 86400.")


def dispatch(layout: Layout, args: argparse.Namespace) -> None:
    if hasattr(args, "timeout_seconds"):
        positive_timeout(args.timeout_seconds)
    handlers = {
        "check": command_check,
        "scan": command_scan,
        "report": command_report,
        "plan": command_plan,
        "show": command_show,
        "apply": command_apply,
    }
    handlers[args.command](layout, args)


def menu_prompt(label: str, default: str = "") -> str:
    suffix = " [{}]".format(default) if default else ""
    value = input(label + suffix + ": ").strip()
    return value or default


def interactive_menu(layout: Layout) -> int:
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise LauncherError("Без команды интерактивное меню требует терминал; используйте --help.")
    parser = build_parser()
    while True:
        print("\n=== vSphere launcher ===")
        print("1. Проверить инструменты")
        print("2. Просканировать vSphere (READ ONLY)")
        print("3. Показать отчёт")
        if layout.full_workflow:
            print("4. Создать Terraform plan")
            print("5. Показать сохранённый plan")
            print("6. Применить проверенный plan")
        print("0. Выход")
        choice = input("Выберите действие: ").strip()
        try:
            if choice == "0":
                return 0
            if choice == "1":
                dispatch(layout, parser.parse_args(["check"]))
            elif choice == "2":
                command = [
                    "scan",
                    "--server", menu_prompt("vCenter", os.environ.get("VSPHERE_SERVER", "")),
                    "--user", menu_prompt("Учётная запись", os.environ.get("VSPHERE_USER", "")),
                    "--source-vm", menu_prompt("Source VM", "tst-win-10-12"),
                ]
                output = menu_prompt("Каталог результата", str(default_scan_output(layout)))
                ca_cert = menu_prompt("CA PEM (пусто = системный trust store)")
                command += ["--output-dir", output]
                if ca_cert:
                    command += ["--ca-cert", ca_cert]
                dispatch(layout, parser.parse_args(command))
            elif choice == "3":
                directory = menu_prompt("Каталог отчёта")
                dispatch(layout, parser.parse_args(["report", directory]))
            elif choice == "4" and layout.full_workflow:
                stack = menu_prompt("Stack", "windows-clone")
                var_file = menu_prompt("Путь к tfvars")
                command = ["plan", "--stack", stack, "--var-file", var_file]
                dispatch(layout, parser.parse_args(command))
            elif choice == "5" and layout.full_workflow:
                dispatch(layout, parser.parse_args(["show", menu_prompt("Путь к .tfplan")]))
            elif choice == "6" and layout.full_workflow:
                dispatch(layout, parser.parse_args(["apply", menu_prompt("Путь к .tfplan")]))
            else:
                print("Неизвестное действие.", file=sys.stderr)
        except LauncherError as exc:
            print("Ошибка: {}".format(exc), file=sys.stderr)


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        require_python()
        layout = discover_layout()
        arguments = list(sys.argv[1:] if argv is None else argv)
        if not arguments:
            return interactive_menu(layout)
        parser = build_parser()
        args = parser.parse_args(arguments)
        if args.command is None:
            parser.print_help()
            return 2
        dispatch(layout, args)
        return 0
    except KeyboardInterrupt:
        print("\nОперация прервана.", file=sys.stderr)
        return 130
    except LauncherError as exc:
        print("Ошибка: {}".format(exc), file=sys.stderr)
        return 1
    except OSError as exc:
        print("Ошибка файловой системы: {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
