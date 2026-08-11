# Offline: Debian/Windows/Astra/TeamCity

Builder запускается на доверенной машине с интернетом. Он скачивает строго
закреплённые версии, проверяет их и собирает переносимый пакет. На целевой
закрытой машине installer и scanner не выполняют сетевых загрузок.

Поддерживаемые target-платформы:

- `linux_amd64` — Debian/Astra Linux x64;
- `windows_amd64` — Windows x64, Windows PowerShell 5.1.

## Сборка снаружи закрытого контура

Linux bundle:

```sh
make offline-bundle PLATFORM=linux_amd64
```

Windows bundle:

```powershell
.\scripts\build-offline-bundle.ps1
```

Builder требует интернет для официальных HashiCorp/GitHub releases и Terraform
Registry. Результат в `offline-dist/` содержит:

- Terraform CLI `1.15.8`;
- filesystem mirror `vmware/vsphere = 2.15.1` без `direct {}` fallback;
- VMware `govc 0.55.1`;
- `jq 1.8.2`;
- standalone read-only scanner, filters, JSON schema и инструкцию;
- lock-файлы всех трёх Terraform stacks;
- `bundle-info.json` и внутренний `MANIFEST.sha256`.

Linux Terraform проверяется по подписанному HashiCorp `SHA256SUMS` и
закреплённому SHA. Windows Terraform, govc и jq проверяются по SHA, закреплённым
в репозитории. Upstream release assets govc не имеют отдельной
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
```

Windows использует встроенные PowerShell 5.1, `Expand-Archive` и `Get-FileHash`.

Передайте archive, рабочую копию репозитория и публичный PEM внутреннего CA
утверждённым каналом. Репозиторий нужен для Terraform stacks; для одного скана
достаточно standalone scanner внутри bundle.

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

Переменные `VSPHERE_SERVER`, `VSPHERE_USER`, `VSPHERE_PASSWORD` задаются только
в текущем процессе и очищаются после запуска. Полная инструкция и описание
результатов: [discovery.md](discovery.md).

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

Provider binaries и offline archives не коммитятся в Git. Lock-файлы
коммитятся и проверяют package checksums. Scan reports, `.tfvars`, state и saved
plans также нельзя коммитить или публиковать как CI artifacts.
