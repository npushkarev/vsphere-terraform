#!/usr/bin/env python3
"""Cross-platform launcher for the guarded vSphere/Terraform workflows."""

from __future__ import annotations

import argparse
import base64
import binascii
import getpass
import hashlib
import http.client
import io
import json
import os
import re
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import unicodedata
import uuid
import zipfile
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
TRUST_DIR_NAME = ".vsphere-trust"
CA_ARCHIVE_PATH = "/certs/download.zip"
CA_ARCHIVE_LIMIT = 8 * 1024 * 1024
CA_MEMBER_LIMIT = 1024 * 1024
TLS_TIMEOUT_SECONDS = 20
PEM_BLOCK = re.compile(
    r"-----BEGIN CERTIFICATE-----[A-Za-z0-9+/=\s]*?-----END CERTIFICATE-----"
)
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


def configure_stdio() -> None:
    # Windows PowerShell 5.1 may expose cp1252 pipes even when the launcher
    # prints Russian text. UTF-8 keeps console and CI output deterministic.
    for stream_name in ("stdout", "stderr"):
        stream = getattr(sys, stream_name)
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(encoding="utf-8", errors="backslashreplace")


def discover_layout(source: Optional[Path] = None, windows: Optional[bool] = None) -> Layout:
    base = (source or Path(__file__)).resolve().parent
    is_windows = os.name == "nt" if windows is None else windows
    repo_scripts = base / "scripts"
    if (repo_scripts / ("scan-vsphere.ps1" if is_windows else "scan-vsphere.sh")).is_file():
        platform = "windows_amd64" if is_windows else "linux_amd64"
        return Layout(base, repo_scripts, base, base / ".vsphere-tools" / platform, is_windows)
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
        if layout.repo_root is not None and (layout.repo_root / "vendor" / "MANIFEST.sha256").is_file():
            raise LauncherError(
                "Локальные инструменты не установлены. Запустите: "
                "python{} vsphere.py install".format("" if layout.windows else "3")
            )
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
    ca_cert: Optional[Path] = None,
) -> Dict[str, str]:
    env = sanitized_environment(layout, identity, apply_flag)
    if ca_cert is not None:
        # Go читает SSL_CERT_FILE в дополнение к системным каталогам CA.
        env["SSL_CERT_FILE"] = str(ca_cert)
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


def split_server(server: str) -> Tuple[str, int]:
    try:
        parsed = urlsplit("//" + server)
        host = parsed.hostname
        port = parsed.port or 443
    except ValueError as exc:
        raise LauncherError("Некорректный адрес vCenter: {}".format(exc))
    if not host:
        raise LauncherError("Некорректный адрес vCenter.")
    return host, port


def readable_fingerprint(digest: str) -> str:
    return ":".join(digest[index:index + 2] for index in range(0, len(digest), 2)).upper()


def normalize_thumbprint(value: str) -> str:
    cleaned = re.sub(r"[\s:]", "", value).lower()
    if not re.fullmatch(r"[0-9a-f]{64}", cleaned):
        raise LauncherError("Отпечаток должен быть SHA-256: 64 hex-символа.")
    return cleaned


def presented_certificate(host: str, port: int) -> bytes:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=TLS_TIMEOUT_SECONDS) as raw:
            with context.wrap_socket(raw, server_hostname=host) as tls:
                certificate = tls.getpeercert(binary_form=True)
    except OSError as exc:
        raise LauncherError("Не удалось получить сертификат {}:{}: {}".format(host, port, exc))
    if not certificate:
        raise LauncherError("vCenter не прислал сертификат.")
    return certificate


def download_ca_archive(host: str, port: int, pinned: bytes) -> bytes:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    connection = http.client.HTTPSConnection(
        host, port, timeout=TLS_TIMEOUT_SECONDS, context=context
    )
    try:
        connection.connect()
        # Тот же сертификат, что подтвердил оператор. Иначе архив брать нельзя.
        if connection.sock.getpeercert(binary_form=True) != pinned:
            raise LauncherError("Сертификат vCenter изменился во время загрузки.")
        connection.request("GET", CA_ARCHIVE_PATH, headers={"Connection": "close"})
        response = connection.getresponse()
        if response.status != 200:
            raise LauncherError(
                "vCenter вернул HTTP {} на {}.".format(response.status, CA_ARCHIVE_PATH)
            )
        payload = response.read(CA_ARCHIVE_LIMIT + 1)
    except LauncherError:
        raise
    except (OSError, http.client.HTTPException) as exc:
        raise LauncherError("Не удалось скачать CA-архив: {}".format(exc))
    finally:
        connection.close()
    if len(payload) > CA_ARCHIVE_LIMIT:
        raise LauncherError("CA-архив больше {} байт.".format(CA_ARCHIVE_LIMIT))
    return payload


def pem_certificates(text: str) -> List[bytes]:
    found: List[bytes] = []
    for match in PEM_BLOCK.finditer(text):
        body = "".join(match.group(0).splitlines()[1:-1]).strip()
        try:
            payload = base64.b64decode(body, validate=True)
        except (binascii.Error, ValueError):
            continue
        # Сертификат X.509 всегда начинается с DER SEQUENCE.
        if len(payload) < 64 or payload[0] != 0x30:
            continue
        found.append(payload)
    return found


def certificates_from_archive(payload: bytes) -> List[bytes]:
    found: List[bytes] = []
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            for info in archive.infolist():
                if info.is_dir() or info.file_size > CA_MEMBER_LIMIT:
                    continue
                member = archive.read(info).decode("ascii", errors="ignore")
                found.extend(pem_certificates(member))
    except (zipfile.BadZipFile, OSError, RuntimeError) as exc:
        raise LauncherError("CA-архив нечитаем: {}".format(exc))
    return found


def unique_certificates(certificates: Sequence[bytes]) -> List[bytes]:
    seen = set()
    result: List[bytes] = []
    for certificate in certificates:
        digest = hashlib.sha256(certificate).hexdigest()
        if digest in seen:
            continue
        seen.add(digest)
        result.append(certificate)
    return result


def render_pem(certificate: bytes) -> str:
    encoded = base64.b64encode(certificate).decode("ascii")
    lines = [encoded[index:index + 64] for index in range(0, len(encoded), 64)]
    return "-----BEGIN CERTIFICATE-----\n{}\n-----END CERTIFICATE-----\n".format("\n".join(lines))


def verify_with_bundle(host: str, port: int, bundle: Path, pinned: bytes) -> None:
    try:
        context = ssl.create_default_context(cafile=str(bundle))
    except (OSError, ssl.SSLError) as exc:
        raise LauncherError("CA-файл не загрузился: {}".format(exc))
    try:
        with socket.create_connection((host, port), timeout=TLS_TIMEOUT_SECONDS) as raw:
            with context.wrap_socket(raw, server_hostname=host) as tls:
                certificate = tls.getpeercert(binary_form=True)
    except ssl.SSLCertVerificationError as exc:
        raise LauncherError("Проверка TLS с этим CA не прошла: {}".format(exc))
    except OSError as exc:
        raise LauncherError("Проверочное соединение не удалось: {}".format(exc))
    if certificate != pinned:
        raise LauncherError("Проверочное соединение вернуло другой сертификат.")


def default_trust_file(layout: Layout, server: str) -> Path:
    root = layout.repo_root or layout.base_dir
    name = re.sub(r"[^A-Za-z0-9._-]", "_", server)
    return root / TRUST_DIR_NAME / (name + ".pem")


def stored_trust_file(layout: Layout, server: str) -> Optional[Path]:
    candidate = default_trust_file(layout, server)
    if candidate.is_symlink() or not candidate.is_file():
        return None
    return candidate.resolve()


def write_trust_bundle(target: Path, certificates: Sequence[bytes], own_directory: bool) -> Path:
    directory = target.parent
    if directory.is_symlink():
        raise LauncherError("Каталог доверенных CA не должен быть symbolic link.")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Права меняем только у собственного каталога launcher-а, не у чужого пути из --output.
    if own_directory:
        protect_private_path(directory, directory=True)
    if target.is_symlink():
        raise LauncherError("Файл CA не должен быть symbolic link.")
    staged = target.with_name(target.name + ".tmp")
    staged.write_text("".join(render_pem(item) for item in certificates), encoding="ascii")
    protect_private_path(staged, directory=False)
    return staged


def certificate_hint(server: str) -> str:
    return (
        "Если в выводе есть 'certificate signed by unknown authority', сначала выполните:\n"
        "  python vsphere.py trust --server {}".format(server)
    )


def terraform_ca_file(layout: Layout, args: argparse.Namespace, server: str) -> Optional[Path]:
    value = getattr(args, "ca_cert", None)
    explicit = safe_existing_file(value, "CA certificate") if value else None
    candidate = explicit or stored_trust_file(layout, server)
    if candidate is None:
        return None
    if layout.windows:
        if explicit is None:
            return None
        raise LauncherError(
            "На Windows Terraform читает системное хранилище. Импортируйте CA: "
            "Import-Certificate -FilePath \"{}\" -CertStoreLocation Cert:\\CurrentUser\\Root".format(
                candidate
            )
        )
    return candidate


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


def command_install(layout: Layout, args: argparse.Namespace) -> None:
    repo_root = require_full_layout(layout)
    if not (repo_root / "vendor" / "MANIFEST.sha256").is_file():
        raise LauncherError("В репозитории отсутствует vendored offline toolchain.")
    arguments = ["-VerifyOnly"] if layout.windows and args.verify_only else (
        ["--verify-only"] if args.verify_only else []
    )
    print("Проверка vendored-файлов; сетевые загрузки отключены.")
    run_process(
        wrapper_command(layout, "install-repo-offline", arguments),
        sanitized_environment(layout),
        repo_root,
        1800,
    )


def confirm_fingerprint(expected: Optional[str], fingerprint: str) -> None:
    if expected:
        if normalize_thumbprint(expected) != fingerprint:
            raise LauncherError("Отпечаток не совпал с ожидаемым. Соединение доверять нельзя.")
        print("Отпечаток совпал с ожидаемым.")
        return
    if not sys.stdin.isatty():
        raise LauncherError("Нет терминала для подтверждения; укажите --expect-thumbprint.")
    print("Сверьте отпечаток по независимому каналу:")
    print("  vSphere Client: Administration > Certificates > Machine SSL Certificate.")
    print("  Браузер: замок в адресной строке > сведения о сертификате > SHA-256.")
    if input("Отпечаток совпадает? (да/нет): ").strip().lower() not in ("да", "д", "yes", "y"):
        raise LauncherError("Отпечаток не подтверждён. Ничего не сохранено.")


def command_trust(layout: Layout, args: argparse.Namespace) -> None:
    server = normalize_server(prompt_value("vCenter: ", getattr(args, "server", None), "VSPHERE_SERVER"))
    host, port = split_server(server)
    pinned = presented_certificate(host, port)
    fingerprint = hashlib.sha256(pinned).hexdigest()
    print("vCenter: {}".format(server))
    print("SHA-256 сертификата: {}".format(readable_fingerprint(fingerprint)))
    confirm_fingerprint(args.expect_thumbprint, fingerprint)
    if args.from_file:
        source = safe_existing_file(args.from_file, "CA bundle")
        certificates = pem_certificates(source.read_text(encoding="ascii", errors="ignore"))
        origin = str(source)
    else:
        certificates = certificates_from_archive(download_ca_archive(host, port, pinned))
        origin = "https://{}{}".format(server, CA_ARCHIVE_PATH)
    certificates = unique_certificates(certificates)
    if not certificates:
        raise LauncherError(
            "CA-сертификаты не найдены. Скачайте корневой CA из vSphere Client "
            "и повторите с --from-file."
        )
    default_target = default_trust_file(layout, server)
    target = Path(args.output).expanduser().resolve() if args.output else default_target
    staged = write_trust_bundle(target, certificates, own_directory=target == default_target)
    try:
        verify_with_bundle(host, port, staged, pinned)
        os.replace(str(staged), str(target))
    except LauncherError:
        try:
            staged.unlink()
        except OSError:
            pass
        raise
    print("Источник: {}".format(origin))
    print("Сертификатов в файле: {}".format(len(certificates)))
    print("Проверка TLS с этим CA прошла.")
    print("CA сохранён: {}".format(target))
    if target == default_target:
        print("scan и plan подхватят этот файл автоматически для {}.".format(server))
    if layout.windows:
        print(
            "Для Terraform на Windows импортируйте CA: Import-Certificate "
            "-FilePath \"{}\" -CertStoreLocation Cert:\\CurrentUser\\Root".format(target)
        )


def command_scan(layout: Layout, args: argparse.Namespace) -> None:
    identity = collect_identity(args)
    govc = verified_tool(layout, "govc")
    jq = verified_tool(layout, "jq")
    output = Path(args.output_dir).expanduser().resolve() if args.output_dir else default_scan_output(layout)
    if output.exists():
        raise LauncherError("Каталог результата уже существует: {}".format(output))
    ca_cert = (
        safe_existing_file(args.ca_cert, "CA certificate")
        if args.ca_cert
        else stored_trust_file(layout, identity.server)
    )
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
    print("  CA: {}".format(ca_cert if ca_cert else "системный trust store"))
    env = sanitized_environment(layout, identity)
    try:
        run_process(
            wrapper_command(layout, "scan-vsphere", arguments),
            env,
            layout.repo_root or layout.base_dir,
            args.timeout_seconds,
        )
    except LauncherError:
        if ca_cert is None:
            print(certificate_hint(identity.server), file=sys.stderr)
        raise
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
    ca_cert = terraform_ca_file(layout, args, identity.server)
    print("Terraform plan (изменения ещё не применяются)")
    print("  vCenter: {}".format(identity.server))
    print("  Учётная запись: {}".format(identity.username))
    print("  Stack: {}".format(stack))
    print("  CA: {}".format(ca_cert if ca_cert else "системный trust store"))
    env = terraform_environment(layout, terraform, identity, ca_cert=ca_cert)
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
    except LauncherError:
        if ca_cert is None:
            print(certificate_hint(identity.server), file=sys.stderr)
        raise
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
    ca_cert = terraform_ca_file(layout, args, identity.server)
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
    print("  CA: {}".format(ca_cert if ca_cert else "системный trust store"))
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
    env = terraform_environment(layout, terraform, identity, flag, ca_cert=ca_cert)
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

    install_parser = subparsers.add_parser(
        "install", help="установить инструменты только из файлов репозитория"
    )
    install_parser.add_argument(
        "--verify-only", action="store_true", help="проверить vendor без установки"
    )

    subparsers.add_parser("check", help="проверить Python, tools и версии")

    trust = subparsers.add_parser(
        "trust", help="проверить сертификат vCenter и сохранить его CA"
    )
    trust.add_argument("--server", help="vCenter hostname[:port], без credentials")
    trust.add_argument("--expect-thumbprint", help="ожидаемый SHA-256 сертификата vCenter")
    trust.add_argument("--from-file", help="готовый CA PEM вместо загрузки с vCenter")
    trust.add_argument("--output", help="путь для сохранённого CA")

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
    plan.add_argument("--ca-cert")
    plan.add_argument("--timeout-seconds", type=int, default=3600)

    show = subparsers.add_parser("show", help="показать сохранённый plan")
    show.add_argument("plan")
    show.add_argument("--timeout-seconds", type=int, default=600)

    apply_parser = subparsers.add_parser("apply", help="применить только проверенный plan")
    add_identity_options(apply_parser)
    apply_parser.add_argument("plan")
    apply_parser.add_argument("--ca-cert")
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
        "install": command_install,
        "check": command_check,
        "trust": command_trust,
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
        if layout.full_workflow:
            print("1. Установить инструменты из репозитория (OFFLINE)")
            print("2. Проверить инструменты")
            print("3. Доверие к сертификату vCenter (CA)")
            print("4. Просканировать vSphere (READ ONLY)")
            print("5. Показать отчёт")
            print("6. Создать Terraform plan")
            print("7. Показать сохранённый plan")
            print("8. Применить проверенный plan")
        else:
            print("1. Проверить инструменты")
            print("2. Доверие к сертификату vCenter (CA)")
            print("3. Просканировать vSphere (READ ONLY)")
            print("4. Показать отчёт")
        print("0. Выход")
        choice = input("Выберите действие: ").strip()
        normalized = choice
        if not layout.full_workflow and choice in ("1", "2", "3", "4"):
            normalized = str(int(choice) + 1)
        try:
            if normalized == "0":
                return 0
            if normalized == "1" and layout.full_workflow:
                dispatch(layout, parser.parse_args(["install"]))
            elif normalized == "2":
                dispatch(layout, parser.parse_args(["check"]))
            elif normalized == "3":
                command = [
                    "trust",
                    "--server", menu_prompt("vCenter", os.environ.get("VSPHERE_SERVER", "")),
                ]
                from_file = menu_prompt("Готовый CA PEM (пусто = скачать с vCenter)")
                if from_file:
                    command += ["--from-file", from_file]
                dispatch(layout, parser.parse_args(command))
            elif normalized == "4":
                command = [
                    "scan",
                    "--server", menu_prompt("vCenter", os.environ.get("VSPHERE_SERVER", "")),
                    "--user", menu_prompt("Учётная запись", os.environ.get("VSPHERE_USER", "")),
                    "--source-vm", menu_prompt("Source VM", "tst-win-10-12"),
                ]
                output = menu_prompt("Каталог результата", str(default_scan_output(layout)))
                ca_cert = menu_prompt("CA PEM (пусто = сохранённый CA или системный trust store)")
                command += ["--output-dir", output]
                if ca_cert:
                    command += ["--ca-cert", ca_cert]
                dispatch(layout, parser.parse_args(command))
            elif normalized == "5":
                directory = menu_prompt("Каталог отчёта")
                dispatch(layout, parser.parse_args(["report", directory]))
            elif normalized == "6" and layout.full_workflow:
                stack = menu_prompt("Stack", "windows-clone")
                var_file = menu_prompt("Путь к tfvars")
                command = ["plan", "--stack", stack, "--var-file", var_file]
                dispatch(layout, parser.parse_args(command))
            elif normalized == "7" and layout.full_workflow:
                dispatch(layout, parser.parse_args(["show", menu_prompt("Путь к .tfplan")]))
            elif normalized == "8" and layout.full_workflow:
                dispatch(layout, parser.parse_args(["apply", menu_prompt("Путь к .tfplan")]))
            else:
                print("Неизвестное действие.", file=sys.stderr)
        except LauncherError as exc:
            print("Ошибка: {}".format(exc), file=sys.stderr)


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        configure_stdio()
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
