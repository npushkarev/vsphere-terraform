# Offline: Debian/Windows/Astra/TeamCity

Репозиторий уже содержит строго закреплённые архивы и provider mirror. Обычная
Git-копия полностью автономна: repo-installer, bundle builder и scanner не
скачивают инструменты. Сеть во время scan нужна только до указанного vCenter;
plan/apply также обращаются к настроенному backend и vCenter.

Поддерживаемые target-платформы:

- `linux_amd64` — Debian/Astra Linux x64;
- `windows_amd64` — Windows x64, Windows PowerShell 5.1.

## Самый короткий путь: установка прямо из репозитория

После утверждённого переноса полной рабочей копии запустите внутри контура:

```sh
python3 ./vsphere.py install
python3 ./vsphere.py check
```

```powershell
python .\vsphere.py install
python .\vsphere.py check
```

Инструменты устанавливаются в `.vsphere-tools/linux_amd64` либо
`.vsphere-tools/windows_amd64`; каталог игнорируется Git. Launcher использует
только этот repo-local toolchain и локальный `terraform.rc`, поэтому экспорт
`PATH`/`TF_CLI_CONFIG_FILE` не требуется.

Проверка всех vendored-файлов без установки:

```sh
./scripts/verify-vendor.sh
```

```powershell
.\scripts\verify-vendor.ps1
```

## Сборка переносимого пакета без интернета

Если вместо полной рабочей копии нужен отдельный пакет, builder только проверяет
`vendor/MANIFEST.sha256`, копирует локальные файлы и упаковывает их. Ему не
нужны Terraform, GitHub, Terraform Registry или другая внешняя сеть.

Linux bundle:

```sh
make offline-bundle PLATFORM=linux_amd64
```

Windows bundle:

```powershell
.\scripts\build-offline-bundle.ps1
```

Результат в `offline-dist/` содержит:

- Terraform CLI `1.15.8`;
- filesystem mirror `vmware/vsphere = 2.15.1` без `direct {}` fallback;
- VMware `govc 0.55.1`;
- `jq 1.8.2`;
- standalone read-only scanner, Python-запускалку, filters, JSON schema и инструкции;
- lock-файлы всех трёх Terraform stacks;
- `bundle-info.json` и внутренний `MANIFEST.sha256`.

Linux Terraform проверяется по уже сохранённому подписанному HashiCorp
`SHA256SUMS` и закреплённому SHA. Windows Terraform, govc, jq и оба provider
package проверяются по SHA, закреплённым в `vendor/MANIFEST.sha256` и
`vendor/provenance.json`. Upstream release assets govc не имеют отдельной
криптографической подписи.

Рядом с archive builder создаёт внешний файл `.sha256`. Передайте его значение
отдельным доверенным каналом либо подпишите весь archive внутренним ключом.
`MANIFEST.sha256` обнаруживает повреждение распакованных файлов, но находится
внутри того же archive и без внешнего доверия не доказывает происхождение.

## Подготовка закрытой машины

Заранее включите системные зависимости в образ или внутренний package mirror.
Минимальный Debian preflight:

```sh
for tool in sha256sum gpg unzip tar install awk; do
  command -v "$tool" >/dev/null || echo "missing: $tool"
done
python3 -c 'import sys; assert sys.version_info >= (3, 9)'
```

Windows использует встроенные PowerShell 5.1, `Expand-Archive` и `Get-FileHash`.
Для единой Python-запускалки заранее установите Python 3.9+ из доверенного
внутреннего образа или package mirror; `pip` и сторонние Python-пакеты не нужны.

Передайте полную рабочую копию репозитория (не Git LFS pointers), либо созданный
archive, и публичный PEM внутреннего CA утверждённым каналом. Репозиторий нужен
для Terraform stacks; для одного скана достаточно standalone scanner внутри
bundle.

## Установка внутри Debian-контура

Сначала сравните SHA всего archive с полученным доверенным значением, затем:

```sh
tar -xzf vsphere-terraform-*-linux_amd64.tar.gz
cd vsphere-terraform-*-linux_amd64
./install-offline.sh --prefix "$HOME/.local/share/vsphere-terraform"
export PATH="$HOME/.local/share/vsphere-terraform/bin:$PATH"
export TF_CLI_CONFIG_FILE="$HOME/.local/share/vsphere-terraform/terraform.rc"
```

Проверка:

```sh
terraform version
govc version
jq --version
```

## Установка внутри Windows-контура

```powershell
Get-FileHash -Algorithm SHA256 .\vsphere-terraform-*-windows_amd64.zip
Expand-Archive .\vsphere-terraform-*-windows_amd64.zip -DestinationPath .\offline
Set-Location .\offline\vsphere-terraform-*-windows_amd64
.\install-offline.ps1 -Prefix "$env:LOCALAPPDATA\vsphere-terraform"
$env:Path = "$env:LOCALAPPDATA\vsphere-terraform\bin;$env:Path"
$env:TF_CLI_CONFIG_FILE = "$env:LOCALAPPDATA\vsphere-terraform\terraform.rc"
terraform version
govc version
jq --version
```

Флаг `-PersistCliConfig` нужен только если вы осознанно хотите сохранить
`TF_CLI_CONFIG_FILE` в user environment. По умолчанию installer не меняет
постоянное окружение пользователя.

## Полный read-only скан внутри контура

Scanner подключается только к указанному vCenter по HTTPS. Он очищает inherited
proxy и неподдерживаемые `GOVC_*`, отключает telemetry-like debug/session files
и ничего не отправляет. Внешний egress всё равно закройте firewall-ом, разрешив
только vCenter:443.

Если CA внутреннего vCenter ещё не известен машине, сначала выполните
`python3 vsphere.py trust --server <vcenter>`. Команда сверяет отпечаток,
сохраняет CA в `.vsphere-trust/` и не требует интернета: всё скачивается с
самого vCenter. Подробности: [python-launcher.md](python-launcher.md).

Debian standalone scanner:

```sh
"$HOME/.local/share/vsphere-terraform/scanner/scan-vsphere.sh" \
  --source-vm 'tst-win-10-12' \
  --output-dir '/secure/path/vsphere-scan' \
  --ca-cert '/secure/path/internal-ca.pem'
```

Windows standalone scanner:

```powershell
& "$env:LOCALAPPDATA\vsphere-terraform\scanner\scan-vsphere.ps1" `
  -SourceVm "tst-win-10-12" `
  -OutputDirectory "C:\Secure\vsphere-scan" `
  -CaCert "C:\Secure\internal-ca.pem"
```

Тот же standalone scanner можно запускать единообразно через Python:

```sh
python3 "$HOME/.local/share/vsphere-terraform/scanner/vsphere.py" scan \
  --server incvc.inc.elara.local \
  --user '<read-only-user>' \
  --source-vm tst-win-10-12 \
  --output-dir /secure/path/vsphere-scan \
  --ca-cert /secure/path/internal-ca.pem
```

```powershell
python "$env:LOCALAPPDATA\vsphere-terraform\scanner\vsphere.py" scan `
  --server incvc.inc.elara.local `
  --user '<read-only-user>' `
  --source-vm tst-win-10-12 `
  --output-dir C:\Secure\vsphere-scan `
  --ca-cert C:\Secure\internal-ca.pem
```

Launcher передаёт `VSPHERE_SERVER`, `VSPHERE_USER`, `VSPHERE_PASSWORD` только
дочернему процессу. Он не может удалить переменные, которые вы сами заранее
экспортировали в родительской shell. После работы в Debian выполните `unset VSPHERE_PASSWORD`,
а в PowerShell — `Remove-Item Env:VSPHERE_PASSWORD`.
Полная инструкция и описание результатов: [discovery.md](discovery.md).
Возможности Python-интерфейса: [python-launcher.md](python-launcher.md).

## Offline Terraform validation

Вернитесь в рабочую копию репозитория. `terraform.rc` содержит только локальный
mirror и `disable_checkpoint = true`:

```sh
terraform -chdir=stacks/inventory init -backend=false -lockfile=readonly
terraform -chdir=stacks/inventory validate
terraform -chdir=stacks/vm-clones init -backend=false -lockfile=readonly
terraform -chdir=stacks/vm-clones validate
terraform -chdir=stacks/windows-clone init -backend=false -lockfile=readonly
terraform -chdir=stacks/windows-clone validate
```

Provider packages и исходные offline archives намеренно коммитятся в `vendor/`
как обычные Git-объекты, чтобы clone был самодостаточным. Сгенерированные
`offline-dist/` bundles не коммитятся, иначе бинарники дублировались бы. Lock-файлы
коммитятся и дополнительно проверяют package checksums. Scan reports, `.tfvars`,
state и saved plans нельзя коммитить или публиковать как CI artifacts.

Порядок обновления закреплённых бинарников: [vendor-maintenance.md](vendor-maintenance.md).
