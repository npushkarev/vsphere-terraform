# Полный read-only скан vSphere

Сканер предназначен для первого обследования vCenter до любого Terraform
`apply`. Он запускается вами на Windows x64 или Debian x64 внутри закрытого
контура. Репозиторий не содержит адреса приёмника отчётов, телеметрии или
автоматической отправки результатов.

Сканирование выполняет только read-only команды официального VMware `govc`:
`about`, `find`, `object.collect` и `device.info` для выбранной исходной VM.
Terraform во время скана не запускается.

## Что будет собрано

- vCenter version/build и видимая inventory hierarchy;
- datacenter, folder, cluster, standalone compute, host и resource pool;
- datastore и datastore cluster;
- standard network, distributed switch/port group и opaque network;
- VM и template: inventory path, питание, guest ID, CPU/RAM, hardware/firmware,
  VMware Tools, host, resource pool, datastore и network;
- для выбранной source VM — безопасная сводка дисков, NIC типов, SCSI
  controllers и наличие vTPM.

Сканер намеренно не запрашивает и не сохраняет пароли, session cookies,
permissions, license, events, annotations, tags, `ExtraConfig`, guest IP,
MAC-адреса, UUID или VMDK paths. Сам список имён VM, host, datastore и network
всё равно является конфиденциальной топологией.

Полный ответ `device.info` фильтруется в памяти/pipe до записи временного файла:
MAC и backing paths не сохраняются даже в рабочем каталоге scanner-а.

## Учётная запись и сеть

Создайте отдельную учётную запись со встроенной ролью **Read-only** на корне
vCenter и включите наследование на дочерние объекты. Отчёт содержит только то,
что видит эта учётная запись; без root scope это будет не полный inventory.

На машине запуска разрешите DNS и TCP/443 только до вашего vCenter. TLS
проверяется всегда. Для внутреннего CA установите его в системный trust store
или передайте публичный PEM через параметр `--ca-cert`/`-CaCert`.
`GOVC_INSECURE=true` и `VSPHERE_ALLOW_UNVERIFIED_SSL=true` сканер отклоняет.

## Установка на машине с интернетом

Debian x64:

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip gnupg make
make install
export PATH="$HOME/.local/bin:$PATH"
terraform version
govc version
jq --version
```

Windows x64, Windows PowerShell 5.1:

```powershell
$Tools = "$env:LOCALAPPDATA\Programs\vsphere-tools"
.\scripts\install-terraform.ps1 -BinDir $Tools
.\scripts\install-govc.ps1 -BinDir $Tools
.\scripts\install-jq.ps1 -BinDir $Tools
$env:Path = "$Tools;$env:Path"
terraform version
govc version
jq --version
```

Версии закреплены в `.terraform-version`, `.govc-version` и `.jq-version`.
Installers проверяют SHA-256; Linux Terraform дополнительно проверяется по
подписанному HashiCorp checksum.

## Подготовка полностью offline

На доверенной машине с интернетом соберите пакет для нужной ОС:

```sh
make offline-bundle PLATFORM=linux_amd64
```

```powershell
.\scripts\build-offline-bundle.ps1
```

Передайте в закрытый контур полученный archive, рабочую копию репозитория и
публичный сертификат внутреннего CA утверждённым каналом. Передавайте SHA-256
целого archive отдельным доверенным каналом либо подпишите archive внутренним
ключом. Встроенный `MANIFEST.sha256` проверяет целостность распакованных файлов,
но сам по себе не подтверждает происхождение archive.

Внутри Debian-контура:

```sh
tar -xzf vsphere-terraform-*-linux_amd64.tar.gz
cd vsphere-terraform-*-linux_amd64
./install-offline.sh --prefix "$HOME/.local/share/vsphere-terraform"
export PATH="$HOME/.local/share/vsphere-terraform/bin:$PATH"
export TF_CLI_CONFIG_FILE="$HOME/.local/share/vsphere-terraform/terraform.rc"
```

Внутри Windows-контура:

```powershell
Expand-Archive .\vsphere-terraform-*-windows_amd64.zip -DestinationPath .\offline
Set-Location .\offline\vsphere-terraform-*-windows_amd64
.\install-offline.ps1 -Prefix "$env:LOCALAPPDATA\vsphere-terraform"
$env:Path = "$env:LOCALAPPDATA\vsphere-terraform\bin;$env:Path"
$env:TF_CLI_CONFIG_FILE = "$env:LOCALAPPDATA\vsphere-terraform\terraform.rc"
```

Offline installer и runtime scanner ничего не скачивают. Для технической
гарантии закройте внешний egress firewall-ом и разрешите только vCenter:443.

## Запуск на Debian

Из рабочей копии репозитория:

```bash
export VSPHERE_SERVER='incvc.inc.elara.local'
export VSPHERE_USER='<read-only-account>'
read -r -s -p 'Пароль vCenter: ' VSPHERE_PASSWORD
export VSPHERE_PASSWORD
printf '\n'

./scripts/scan-vsphere.sh \
  --source-vm 'tst-win-10-12' \
  --output-dir '/secure/path/vsphere-scan' \
  --ca-cert '/secure/path/internal-ca.pem'

unset VSPHERE_PASSWORD VSPHERE_USER VSPHERE_SERVER
```

Если scanner установлен из offline bundle и репозитория на машине нет:

```sh
"$HOME/.local/share/vsphere-terraform/scanner/scan-vsphere.sh" \
  --source-vm 'tst-win-10-12' \
  --output-dir '/secure/path/vsphere-scan' \
  --ca-cert '/secure/path/internal-ca.pem'
```

## Запуск на Windows

```powershell
$env:VSPHERE_SERVER = "incvc.inc.elara.local"
$Credential = Get-Credential -UserName "<read-only-account>" -Message "vCenter Read-only"
$env:VSPHERE_USER = $Credential.UserName
$env:VSPHERE_PASSWORD = $Credential.GetNetworkCredential().Password

try {
    .\scripts\scan-vsphere.ps1 `
        -SourceVm "tst-win-10-12" `
        -OutputDirectory "C:\Secure\vsphere-scan" `
        -CaCert "C:\Secure\internal-ca.pem"
}
finally {
    Remove-Item Env:VSPHERE_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item Env:VSPHERE_USER -ErrorAction SilentlyContinue
    Remove-Item Env:VSPHERE_SERVER -ErrorAction SilentlyContinue
}
```

Offline scanner находится в
`$env:LOCALAPPDATA\vsphere-terraform\scanner\scan-vsphere.ps1`.

Если source name встречается несколько раз, укажите точный inventory path,
например `/INC/vm/Test Lab/tst-win-10-12`.

## Результат

Сканер создаёт новый каталог и отказывается перезаписывать существующий:

- `inventory.md` — читаемый отчёт;
- `inventory-tree.txt` — полная видимая hierarchy;
- `inventory.json` — структурированные данные schema v1;
- `windows-clone.generated.tfvars` — безопасная заготовка для clone stack;
- `SHA256SUMS` — hashes четырёх файлов отчёта.

Linux создаёт каталог с mode `0700`, файлы `0600`; Windows ограничивает ACL
текущим пользователем. Не добавляйте каталог в Git, CI artifacts, почту или
тикеты. Путь `/scan-results/` уже игнорируется репозиторием.

Заготовка tfvars намеренно оставляет target cluster/datastore/network/folder
как `REPLACE_WITH_*`, а
`source_powered_off_acknowledgement = ""`. Скан не разрешает `apply`: сначала
вручную выберите target, проверьте VMware Tools и повторно убедитесь, что source
выключен непосредственно перед plan/apply.

Официальные ссылки:

- [govc v0.55.1](https://github.com/vmware/govmomi/releases/tag/v0.55.1)
- [govc environment и TLS](https://github.com/vmware/govmomi/blob/v0.55.1/govc/README.md)
- [govc command reference](https://github.com/vmware/govmomi/blob/v0.55.1/govc/USAGE.md)
- [jq 1.8.2](https://github.com/jqlang/jq/releases/tag/jq-1.8.2)
