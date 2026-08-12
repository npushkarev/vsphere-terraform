# Terraform для vSphere 7.0.3

Репозиторий устанавливает проверенный Terraform CLI, делает полный read-only
скан видимой топологии vCenter, создаёт Linux VM из шаблона и клонирует Windows
10 из существующей выключенной VM.

Terraform запускается с рабочей станции, dev-VM или CI и обращается к vCenter по
HTTPS API. Ничего устанавливать внутрь vCenter не нужно.

## Зафиксированные версии

- Terraform CLI: `1.15.8`.
- Provider: `vmware/vsphere = 2.15.1`.
- VMware govc: `0.55.1`.
- jq: `1.8.2`.
- vCenter из текущего окружения: `incvc.inc.elara.local`.

Provider зафиксирован строго на `2.15.1`: это последний релиз, документация
которого перечисляет vSphere 7.x. Не запускайте `terraform init -upgrade` до
обновления vSphere.

> [vSphere 7 вышел из General Support 2 октября 2025 года](https://knowledge.broadcom.com/external/article/415405/end-of-general-support-for-vsphere.html).
> Этот репозиторий сохраняет совместимую связку версий, но обновление платформы
> до vSphere 8+ всё равно нужно запланировать.

## Структура

- `stacks/inventory` — только data sources, не содержит managed resources.
- `stacks/vm-clones` — opt-in создание Linux VM из шаблона.
- `stacks/windows-clone` — один full clone Windows VM с Sysprep.
- `modules/linux-vm-clone` — модуль клонирования с `prevent_destroy = true`.
- `scripts` — установка, проверка, plan/apply и offline bundle.
- `scripts/scan-vsphere.*` — полный read-only discovery для Debian/Windows.
- `vsphere.py` — единое интерактивное меню для Debian/Windows.

## 1. Установка инструментов

Сначала клонируйте приватный репозиторий и перейдите в него:

```sh
gh repo clone npushkarev/vsphere-terraform
cd vsphere-terraform
```

Debian Linux x64:

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates curl unzip gnupg make python3
make install
export PATH="$HOME/.local/bin:$PATH"
terraform version
govc version
jq --version
```

Windows x64, обычный PowerShell — WSL не нужен:

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

Установщики не вызывают `sudo` и проверяют закреплённые SHA-256 официальных
архивов. Linux Terraform дополнительно проверяется по подписанному HashiCorp
checksum.

### Единая Python-запускалка

Если нужен один интерфейс вместо отдельных shell/PowerShell-команд, установите
Python 3.9+ и запустите интерактивное меню:

```sh
python3 vsphere.py
```

Windows:

```powershell
python .\vsphere.py
```

Запускалка умеет проверить инструменты, выполнить read-only scan, открыть
проверенный отчёт, создать plan и применить только ранее проверенный plan через
защитные wrapper-скрипты. Пароль запрашивается скрыто и не передаётся в
аргументах командной строки. Подробности: [docs/python-launcher.md](docs/python-launcher.md).

## 2. Учётная запись vCenter

Для inventory используйте отдельную Read Only учётку. Для создания VM создайте
вторую service account с правами только на нужные folder, resource pool,
datastore, network и template. Подробности: [docs/access.md](docs/access.md).

Секреты задаются только на время работы. Debian/Bash:

```bash
export VSPHERE_SERVER='incvc.inc.elara.local'
export VSPHERE_USER='<service-account>'
read -r -s -p 'Пароль vCenter: ' VSPHERE_PASSWORD
export VSPHERE_PASSWORD
printf '\n'
```

Windows PowerShell (пароль не печатается и не сохраняется в репозитории):

```powershell
$env:VSPHERE_SERVER = "incvc.inc.elara.local"
$Credential = Get-Credential -UserName "<service-account>" -Message "vCenter credentials"
$env:VSPHERE_USER = $Credential.UserName
$env:VSPHERE_PASSWORD = $Credential.GetNetworkCredential().Password
```

TLS-проверка включена принудительно. Установите корпоративный CA в trust store
машины, с которой запускается Terraform.

## 3. Сначала просканируйте весь vCenter

Для полного inventory назначьте отдельной учётке роль Read-only на корне
vCenter с наследованием. Сканер запускаете вы внутри своего контура; он не
отправляет отчёт и во время runtime обращается только к указанному vCenter.

Debian:

```sh
./scripts/scan-vsphere.sh \
  --source-vm 'tst-win-10-12' \
  --output-dir '/private/path/vsphere-scan' \
  --ca-cert '/private/path/internal-ca.pem'
```

Windows:

```powershell
.\scripts\scan-vsphere.ps1 `
  -SourceVm "tst-win-10-12" `
  -OutputDirectory "C:\Private\vsphere-scan" `
  -CaCert "C:\Private\internal-ca.pem"
```

Результат содержит Markdown-отчёт, дерево, JSON и безопасную заготовку
`windows-clone.generated.tfvars`. Полная offline-инструкция, состав отчёта и
ограничения: [docs/discovery.md](docs/discovery.md).

## 4. Безопасная проверка Terraform-подключения

По умолчанию inventory ищет datacenter `INC`. Остальные объекты необязательны.

```sh
cp stacks/inventory/inventory.tfvars.example /private/path/inventory.tfvars
terraform -chdir=stacks/inventory init
./scripts/plan.sh inventory /private/path/inventory.tfvars
```

Windows-эквивалент:

```powershell
.\scripts\plan.ps1 -Stack inventory -VarFile C:\private\inventory.tfvars
```

Скрипт проверяет JSON plan и завершится ошибкой, если в inventory появится хотя
бы одно управляемое изменение.

## 5. Создание Linux VM

1. Скопируйте `stacks/vm-clones/vm-clones.tfvars.example` за пределы Git или в
   игнорируемый `.tfvars`.
2. Укажите реальные cluster, datastore, network, template и folder.
3. Оставьте `virtual_machines = {}` и сначала проверьте доступ к инвентарю.
4. Добавьте VM в map и создайте сохранённый plan.

```sh
terraform -chdir=stacks/vm-clones init
./scripts/plan.sh vm-clones /private/path/vm-clones.tfvars
```

Скрипт напечатает путь сохранённого `.tfplan`. Внимательно просмотрите его:

```sh
terraform -chdir=stacks/vm-clones show /absolute/path/to/saved.tfplan
```

Применение разрешено только из сохранённого plan и только с явным флагом:

```sh
ALLOW_VM_APPLY=yes ./scripts/apply-reviewed-plan.sh \
  /absolute/path/to/saved.tfplan
```

Windows:

```powershell
$env:ALLOW_VM_APPLY = "yes"
.\scripts\apply-reviewed-plan.ps1 -Plan C:\absolute\path\to\saved.tfplan
```

Любое действие `delete` блокируется wrapper-скриптами, а VM защищены
`prevent_destroy = true`. Цели `destroy` в Makefile нет.

## 6. Клон Windows 10 `tst-win-10-12`

На последней фотографии target VM называется `tst-win-10-12`. Terraform может
использовать обычную VM как источник; импортировать или превращать её в template
не нужно.

Безопасный workflow делает full clone и запускает Windows Sysprep: target получает
новый SID, уникальное computer name и DHCP либо зарезервированный статический IP.
Источник должен быть выключен. Inline domain/admin passwords намеренно не
поддерживаются, потому что они попали бы в Terraform state.

```sh
cp stacks/windows-clone/windows-clone.tfvars.example \
  /private/path/windows-clone.tfvars
./scripts/plan.sh windows-clone /private/path/windows-clone.tfvars
```

После проверки сохранённого plan:

```sh
ALLOW_WINDOWS_CLONE_APPLY=yes ./scripts/apply-reviewed-plan.sh \
  /absolute/path/to/saved.tfplan
```

Wrapper принимает только no-op или ровно один create Windows-клона. Полная
подготовка source, tfvars, Windows-команды и проверки после apply описаны в
[docs/windows-clone.md](docs/windows-clone.md).

## Существующие VM и state

Существующую VM сначала описывают в конфигурации, затем импортируют и доводят
plan до отсутствия неожиданных изменений. См. [docs/import.md](docs/import.md).

Перед первым рабочим `apply` настройте командный remote backend с TLS,
шифрованием, versioning и locking: [docs/state.md](docs/state.md). Локальные
state и plan-файлы игнорируются Git, но всё равно содержат чувствительные данные.

Для Debian/Windows/Astra/TeamCity без интернета используйте
[docs/offline.md](docs/offline.md).
