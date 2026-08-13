# Python-запускалка

`vsphere.py` — единая запускалка для Debian и Windows. Требуется Python 3.9+
без дополнительных пакетов: `pip install` не нужен.

Launcher не реализует vSphere/Terraform заново. Он вызывает существующие
policy-wrapper-скрипты, передаёт пароль только через окружение дочернего
процесса и не добавляет опции отключения TLS.

## Интерактивное меню

Из корня рабочей копии репозитория:

```sh
python3 vsphere.py
```

Windows:

```powershell
python .\vsphere.py
```

Меню позволяет локально установить и проверить инструменты, запустить read-only scan, показать
проверенный отчёт, создать/просмотреть plan и применить только ранее созданный
launcher-ом plan.

## Offline-установка из репозитория

Полная рабочая копия уже содержит Terraform 1.15.8, govc 0.55.1, jq 1.8.2 и
provider mirror `vmware/vsphere` 2.15.1 для Linux/Windows x64:

```sh
python3 vsphere.py install
```

```powershell
python .\vsphere.py install
```

Команда не скачивает файлы и не использует системный Terraform из `PATH`.
Перед распаковкой она проверяет строгий `vendor/MANIFEST.sha256`, размеры,
отсутствие дополнительных файлов и symbolic links. Repo-local toolchain
устанавливается в `.vsphere-tools/<platform>` и автоматически используется
всеми следующими командами launcher-а.

Только проверить vendor, ничего не записывая:

```sh
python3 vsphere.py install --verify-only
```

## Проверка установки

```sh
python3 vsphere.py check
```

```powershell
python .\vsphere.py check
```

Команда сверяет repo-local Terraform, govc и jq с закреплёнными версиями. Если
toolchain отсутствует, launcher не делает fallback на `PATH`, а просит явно
выполнить `install`.

## Доверие к сертификату vCenter

vCenter обычно выдаёт сертификат своего внутреннего CA. Пока этот CA неизвестен
машине, любая команда падает с `x509: certificate signed by unknown authority`.
Команда `trust` решает это один раз на сервер:

```sh
python3 vsphere.py trust --server incvc.inc.elara.local
```

```powershell
python .\vsphere.py trust --server incvc.inc.elara.local
```

Что делает команда:

1. Открывает TLS-соединение и печатает SHA-256 сертификата vCenter.
2. Ждёт подтверждения отпечатка. Сверьте его по независимому каналу: vSphere
   Client `Administration > Certificates > Machine SSL Certificate`, либо замок в
   адресной строке браузера. Для неинтерактивного запуска передайте
   `--expect-thumbprint`.
3. По тому же проверенному соединению скачивает `/certs/download.zip` и
   извлекает из него CA-сертификаты. Если архив недоступен, скачайте корневой CA
   из vSphere Client вручную и укажите `--from-file`.
4. Делает контрольное TLS-соединение уже с полной проверкой цепочки и имени
   узла. Файл сохраняется только после успешной проверки.

Результат лежит в `.vsphere-trust/<server>.pem` (каталог в `.gitignore`, режим
0600). Команды `scan`, `plan` и `apply` подхватывают этот файл автоматически для
того же адреса vCenter; `--ca-cert` по-прежнему перекрывает выбор.

Пример с заранее известным отпечатком:

```sh
python3 vsphere.py trust --server incvc.inc.elara.local \
  --expect-thumbprint AA:BB:CC:...:FF
```

На Linux launcher передаёт CA в Terraform через `SSL_CERT_FILE`. Системные
каталоги CA при этом продолжают работать. На Windows Terraform читает системное
хранилище, поэтому CA нужно импортировать один раз:

```powershell
Import-Certificate -FilePath .\.vsphere-trust\incvc.inc.elara.local.pem `
  -CertStoreLocation Cert:\CurrentUser\Root
```

govc берёт CA из файла на обеих платформах, отдельный импорт для `scan` не
нужен.

## Read-only скан

Пароль можно оставить незаданным — launcher запросит его скрыто. Параметра
`--password` намеренно нет.

Debian:

```sh
python3 vsphere.py scan \
  --server incvc.inc.elara.local \
  --user '<read-only-user>' \
  --source-vm tst-win-10-12 \
  --output-dir /secure/vsphere-scan \
  --ca-cert /secure/internal-ca.pem
```

Windows:

```powershell
python .\vsphere.py scan `
  --server incvc.inc.elara.local `
  --user '<read-only-user>' `
  --source-vm tst-win-10-12 `
  --output-dir C:\Secure\vsphere-scan `
  --ca-cert C:\Secure\internal-ca.pem
```

После успешного скана launcher проверит локальный `SHA256SUMS` и покажет краткую
сводку. Это проверка целостности файлов одного результата, а не внешняя подпись
или доказательство происхождения. Полный отчёт не печатается без отдельной
команды, потому что содержит конфиденциальную топологию.

```sh
python3 vsphere.py report /secure/vsphere-scan
python3 vsphere.py report /secure/vsphere-scan --format tree
python3 vsphere.py report /secure/vsphere-scan --format markdown
```

## Plan Windows-клона

Сначала отредактируйте приватный `windows-clone.tfvars`, затем используйте
provisioning-учётку:

```sh
python3 vsphere.py plan \
  --stack windows-clone \
  --var-file /secure/windows-clone.tfvars \
  --server incvc.inc.elara.local \
  --user '<provisioning-user>'
```

Windows:

```powershell
python .\vsphere.py plan `
  --stack windows-clone `
  --var-file C:\Secure\windows-clone.tfvars `
  --server incvc.inc.elara.local `
  --user '<provisioning-user>'
```

Рядом с `.tfplan` launcher создаёт приватную квитанцию. Она связывает план с:

- SHA-256 самого plan;
- vCenter и именем учётной записи;
- выбранным stack и типом backend;
- текущей Terraform-конфигурацией и lock-файлом.

Локальные модули и точный hash metadata настроенного backend также входят в
проверку. На Linux plan и квитанция получают режимы `0700/0600`; на Windows
launcher закрывает inheritance ACL и оставляет доступ текущему SID.

Если plan, конфигурация, endpoint, учётка или backend изменятся, Python
`apply` завершится отказом.

## Просмотр и применение

```sh
python3 vsphere.py show /absolute/path/to/plan.tfplan
python3 vsphere.py apply /absolute/path/to/plan.tfplan \
  --server incvc.inc.elara.local \
  --user '<provisioning-user>'
```

`apply` работает только в интерактивном терминале, повторно показывает plan и
проверяет SHA. Для Windows-клона нужно вручную подтвердить свежую проверку, что
source VM выключена, а затем ввести фразу с коротким SHA плана. После этого
launcher вызывает только `apply-reviewed-plan.*`; прямого `terraform apply` в
Python нет.

По умолчанию local/uninitialized Terraform state блокирует применение.
Настройте командный remote backend согласно [state.md](state.md). Флаг
`--allow-local-state` оставлен для осознанной лабораторной работы и не отменяет
остальные подтверждения и policy-проверки.

## Offline-режим

`vsphere.py` входит и в offline bundle. После установки standalone launcher
находится здесь:

```text
<prefix>/scanner/vsphere.py
```

В standalone-режиме доступны `check`, `scan` и `report`. Для `plan`, `show` и
`apply` нужна рабочая копия репозитория со stacks и wrapper-скриптами. Python
runtime не включён в archive: заранее установите Python 3.9+ из доверенного
внутреннего образа или package mirror.
