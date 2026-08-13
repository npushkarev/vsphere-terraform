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
- `vendor` — Terraform, govc, jq и vSphere provider для обеих x64-платформ.

## 1. Закрытый контур: установка без интернета

Обычная копия этого репозитория уже содержит все закреплённые бинарные файлы.
Они хранятся как обычные Git-объекты, не Git LFS, поэтому после утверждённого
клонирования или переноса `git bundle` никакой дополнительный download не нужен.
Объём `vendor/` — около 127 МиБ; самый большой отдельный файл — около 34 МиБ.

В открытом контуре клонируйте репозиторий один раз, затем перенесите всю рабочую
копию или Git bundle утверждённым способом:

```sh
gh repo clone npushkarev/vsphere-terraform
cd vsphere-terraform
```

Внутри Debian/Astra Linux x64 нужны только уже имеющиеся системные утилиты
`python3` 3.9+, `sha256sum`, `gpg`, `unzip`, `tar`, `install` и `awk`:

```sh
python3 ./vsphere.py install
python3 ./vsphere.py check
python3 ./vsphere.py
```

Windows x64, обычный Windows PowerShell 5.1 — WSL и права администратора не нужны:

```powershell
python .\vsphere.py install
python .\vsphere.py check
python .\vsphere.py
```

Команда `install` сначала проверяет точный набор и SHA-256 всех файлов
`vendor/`, затем локально распаковывает инструменты в игнорируемый каталог
`.vsphere-tools/<platform>`. Она не содержит сетевой ветки, не вызывает `sudo`
и создаёт `terraform.rc` только с локальным `filesystem_mirror`, без `direct {}`.
Linux Terraform дополнительно проверяется по подписанному HashiCorp checksum.
Python-запускалка сама находит этот toolchain; менять `PATH` не требуется.

Проверить payload без установки:

```sh
python3 ./vsphere.py install --verify-only
```

Доверие к происхождению задаётся утверждённым commit/tag или его подписью,
переданной отдельным внутренним каналом. Вложенный manifest защищает от
повреждения, но сам по себе не является независимой подписью.

### Единая Python-запускалка

Для повторного запуска интерактивного меню:

```sh
python3 vsphere.py
```

Windows:

```powershell
python .\vsphere.py
```

Запускалка умеет локально установить и проверить инструменты, выполнить read-only scan, открыть
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

TLS-проверка включена принудительно. Сертификат vCenter должен проверяться, а не
игнорироваться. Как получить его CA, описано в следующем разделе.

## 3. Доверие к сертификату vCenter

Без этого шага команды падают с `x509: certificate signed by unknown authority`.
Выполните один раз на каждой машине и для каждого vCenter:

```sh
python3 ./vsphere.py trust --server 'incvc.inc.elara.local'
```

```powershell
python .\vsphere.py trust --server "incvc.inc.elara.local"
```

Launcher напечатает SHA-256 сертификата vCenter и подождёт подтверждения.
Сверьте отпечаток в vSphere Client (`Administration > Certificates > Machine SSL
Certificate`) или в браузере. Только после подтверждения он скачивает CA с
самого vCenter, проверяет им реальное TLS-соединение и сохраняет файл в
`.vsphere-trust/<server>.pem`.

Дальше `scan`, `plan` и `apply` берут этот CA автоматически. Флаг `--ca-cert`
по-прежнему работает, если CA получен другим путём.

На Windows Terraform читает системное хранилище, поэтому импортируйте CA один
раз (права администратора не нужны):

```powershell
Import-Certificate -FilePath .\.vsphere-trust\incvc.inc.elara.local.pem `
  -CertStoreLocation Cert:\CurrentUser\Root
```

Подробности и неинтерактивный режим: [docs/python-launcher.md](docs/python-launcher.md).

## 4. Сначала просканируйте весь vCenter

Для полного inventory назначьте отдельной учётке роль Read-only на корне
vCenter с наследованием. Сканер запускаете вы внутри своего контура; он не
отправляет отчёт и во время runtime обращается только к указанному vCenter.

Debian:

```sh
python3 ./vsphere.py scan \
  --server 'incvc.inc.elara.local' \
  --user '<read-only-account>' \
  --source-vm 'tst-win-10-12' \
  --output-dir '/private/path/vsphere-scan' \
  --ca-cert '/private/path/internal-ca.pem'
```

Windows:

```powershell
python .\vsphere.py scan `
  --server "incvc.inc.elara.local" `
  --user "<read-only-account>" `
  --source-vm "tst-win-10-12" `
  --output-dir "C:\Private\vsphere-scan" `
  --ca-cert "C:\Private\internal-ca.pem"
```

Результат содержит Markdown-отчёт, дерево, JSON и безопасную заготовку
`windows-clone.generated.tfvars`. Полная offline-инструкция, состав отчёта и
ограничения: [docs/discovery.md](docs/discovery.md).

## 5. Безопасная проверка Terraform-подключения

По умолчанию inventory ищет datacenter `INC`. Остальные объекты необязательны.

```sh
cp stacks/inventory/inventory.tfvars.example /private/path/inventory.tfvars
python3 ./vsphere.py plan --stack inventory \
  --var-file /private/path/inventory.tfvars
```

Windows-эквивалент:

```powershell
python .\vsphere.py plan --stack inventory `
  --var-file C:\private\inventory.tfvars
```

Скрипт проверяет JSON plan и завершится ошибкой, если в inventory появится хотя
бы одно управляемое изменение.

## 6. Создание Linux VM

1. Скопируйте `stacks/vm-clones/vm-clones.tfvars.example` за пределы Git или в
   игнорируемый `.tfvars`.
2. Укажите реальные cluster, datastore, network, template и folder.
3. Оставьте `virtual_machines = {}` и сначала проверьте доступ к инвентарю.
4. Добавьте VM в map и создайте сохранённый plan.

```sh
python3 ./vsphere.py plan --stack vm-clones \
  --var-file /private/path/vm-clones.tfvars
```

Скрипт напечатает путь сохранённого `.tfplan`. Внимательно просмотрите его:

```sh
python3 ./vsphere.py show /absolute/path/to/saved.tfplan
```

Применение разрешено только из сохранённого plan и только с явным флагом:

```sh
python3 ./vsphere.py apply /absolute/path/to/saved.tfplan
```

Windows:

```powershell
python .\vsphere.py apply C:\absolute\path\to\saved.tfplan
```

Любое действие `delete` блокируется wrapper-скриптами, а VM защищены
`prevent_destroy = true`. Цели `destroy` в Makefile нет.

## 7. Клон Windows 10 `tst-win-10-12`

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
python3 ./vsphere.py plan --stack windows-clone \
  --var-file /private/path/windows-clone.tfvars
```

После проверки сохранённого plan:

```sh
python3 ./vsphere.py apply /absolute/path/to/saved.tfplan
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
Процесс редкого обновления самих бинарников вынесен в
[docs/vendor-maintenance.md](docs/vendor-maintenance.md).
