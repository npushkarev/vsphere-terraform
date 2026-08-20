# Образ Astra Linux для vSphere

Terraform не устанавливает ОС с ISO. Он клонирует уже готовый шаблон. Этот
документ отвечает на вопрос, откуда взять образ Astra Linux и что в нём лежит.

## Откуда берём

ПАО Группа Астра публикует универсальные базовые образы (UBI), среди них есть
сборки под VMware vSphere в формате OVA:

```text
https://registry.astralinux.ru/images/alse/vsphere/
```

Имя файла собирается по шаблону
`<distro>[-gui]-<version>-<secure-level>-<env>-<build-version>-<arch>.<ext>`.
Уровень защищённости в имени: `base` (Орёл), `adv` (Воронеж), `max` (Смоленск).
Рядом с каждым файлом лежат `.md5`, `.sha1` и `.sha256`.

Работает и алиас на самую свежую сборку линейки:

```text
alse-1.8-max-vsphere-latest-amd64.ova
```

Сам OVA в этот репозиторий не кладётся. Он весит около 725 МиБ, а GitHub не
принимает файлы больше 100 МиБ без LFS. Храните образ во внутреннем реестре.

## Как скачать

Прямые ссылки на образы, проверенные для этой работы:

| Что | Ссылка |
|---|---|
| Каталог всех образов vSphere | <https://registry.astralinux.ru/images/alse/vsphere/> |
| 1.8.5 Смоленск, сборка 1.8.5.46 | <https://registry.astralinux.ru/images/alse/vsphere/alse-1.8.5-max-vsphere-mg16.4.0-amd64.ova> |
| 1.8.5 Воронеж | <https://registry.astralinux.ru/images/alse/vsphere/alse-1.8.5-adv-vsphere-mg16.4.0-amd64.ova> |
| 1.8.5 Орёл | <https://registry.astralinux.ru/images/alse/vsphere/alse-1.8.5-base-vsphere-mg16.4.0-amd64.ova> |
| Самая свежая 1.8 Смоленск | <https://registry.astralinux.ru/images/alse/vsphere/alse-1.8-max-vsphere-latest-amd64.ova> |

### Скриптом

В репозитории есть `scripts/get-astra-image.py`. Он сам находит нужный файл в
каталоге, скачивает его и сверяет SHA-256 с опубликованной. Нужен Python 3.9+,
устанавливать ничего не надо.

Windows:

```powershell
python .\scripts\get-astra-image.py --version 1.8.5 --level max --output-dir C:\Images
```

Debian и Astra:

```sh
python3 scripts/get-astra-image.py --version 1.8.5 --level max --output-dir /srv/images
```

Уровень задаётся как `base` (Орёл), `adv` (Воронеж) или `max` (Смоленск).
Посмотреть, что вообще есть в каталоге:

```powershell
python .\scripts\get-astra-image.py --list
```

Полезные детали:

- без `--build` берётся самая свежая сборка нужной версии, конкретную можно
  закрепить через `--build mg16.4.0`;
- `--image <имя файла>` скачивает точно указанный файл;
- прерванная загрузка продолжается с места обрыва при повторном запуске;
- если файл уже скачан и его сумма верна, скрипт ничего не делает;
- при несовпадении суммы файл переименовывается в `.bad`, код возврата 1;
- `--base-url` переключает источник на внутреннее зеркало, когда образ уже
  выложен в закрытом контуре.

За прокси скрипт берёт стандартные переменные окружения `HTTPS_PROXY` и
`HTTP_PROXY`.

### Руками

Контрольная сумма лежит рядом с образом, к имени файла добавляется `.sha256`.
Скачивание на машине с интернетом, Debian или Astra:

```sh
BASE='https://registry.astralinux.ru/images/alse/vsphere'
IMAGE='alse-1.8.5-max-vsphere-mg16.4.0-amd64.ova'

curl -fL -O "$BASE/$IMAGE"
curl -fsSL "$BASE/$IMAGE.sha256" > "$IMAGE.sha256"
echo "$(cat "$IMAGE.sha256")  $IMAGE" | sha256sum -c -
```

Windows PowerShell:

```powershell
$Base  = 'https://registry.astralinux.ru/images/alse/vsphere'
$Image = 'alse-1.8.5-max-vsphere-mg16.4.0-amd64.ova'

Invoke-WebRequest "$Base/$Image" -OutFile $Image
$Expected = (Invoke-WebRequest "$Base/$Image.sha256").Content.Trim()
$Actual   = (Get-FileHash $Image -Algorithm SHA256).Hash.ToLower()
if ($Actual -ne $Expected) { throw "SHA-256 не совпал" }
```

Скачивать нужно один раз. Дальше образ переносится в контур утверждённым
каналом и кладётся во внутренний реестр, чтобы второй раз его не тащить.
Контрольную сумму передавайте отдельно от самого файла.

Файл `.sha256` содержит только сам хеш, без имени файла. Поэтому в команде
проверки имя подставляется вручную, как в примере выше.

## Что проверено в `alse-1.8.5-max-vsphere-mg16.4.0-amd64.ova`

Проверка выполнена 2026-08-20 на локальной машине. Образ распакован и прочитан
без запуска виртуальной машины.

| Параметр | Значение |
|---|---|
| Размер | 759 787 520 байт |
| SHA-256 | `dae528968854e9a68bbd664bfac010e25fb38cabced062292aa4d178f9198939` |
| Собран | 29.06.2026 |
| `/etc/astra/build_version` | `1.8.5.46` |
| `/etc/astra_version` | `1.8.5` |
| `/etc/astra/hotfix_build_version` | файла нет, хотфиксы не накатаны |
| `/etc/astra_license` | `MODE=2`, `maximum(smolensk)` |
| Ядро | `6.1.158-1-generic` |
| Guest id в OVF | `other3xLinux64Guest` |
| Hardware version | `vmx-11` |
| Конфигурация | 2 vCPU, 2 ГБ RAM, диск 16 ГБ |
| Контроллер и адаптер | pvscsi, vmxnet3 |
| Разметка | GPT без LVM: `sda1` EFI 512 МБ vfat, `sda2` `/` ext4 |

Сборка `1.8.5.46` соответствует бюллетеню № 2026-0224SE18 и установочному ISO
`installation-1.8.5.46-11.02.26_01.30.iso`. Соответствие сборок и обновлений
ведётся в [справочном центре Astra Linux](https://wiki.astralinux.ru/pages/viewpage.action?pageId=326852054).

Гигиена шаблона в образе уже правильная. `/etc/machine-id` пустой, host-ключей
SSH нет, они создаются при первой загрузке. Клоны не получат одинаковый
DHCP-адрес и одинаковые ключи.

Пароль по умолчанию `astra/astra`, принудительная смена при первом входе не
настроена. Пароль опубликован в документации вендора, поэтому меняйте его до
подключения машины в рабочую сеть.

## Что установлено и чего нет

Установлено: `open-vm-tools` 13.0.5 вместе с `open-vm-tools-desktop`,
`openssh-server` 9.6p1, `python3` 3.11.2, `parsec` 3.11, `astra-safepolicy` 3.0.
Всего 618 пакетов.

Не установлено и требуется доставить в шаблон:

- `cloud-init`, без него не работает передача настроек через `guestinfo`;
- `cloud-guest-utils` (`growpart`), без него диск не расширится автоматически;
- агент мониторинга.

## Закрытый контур

`/etc/apt/sources.list` в образе указывает на интернет:

```text
deb https://download.astralinux.ru/astra/frozen/1.8_x86-64/1.8.5/extended-repository 1.8_x86-64 main contrib non-free
deb https://download.astralinux.ru/astra/frozen/1.8_x86-64/1.8.5/main-repository 1.8_x86-64 main contrib non-free non-free-firmware
```

Внутри контура эти адреса недоступны. Чтобы доставить недостающие пакеты, нужен
внутренний зеркальный фид. Репозиторий помечен как `frozen`, то есть это
фиксированный слепок версии 1.8.5, его содержимое не меняется.

## Гостевая кастомизация

Astra Linux не входит в матрицу поддерживаемых гостевых ОС VMware Guest OS
Customization. Классический блок `customize { linux_options }` для неё
использовать нельзя.

Механизм объявления совместимости через `/etc/vmware-tools/customization.conf`
и `COMPATIBILITY=GOSC_METHOD_*` описан в
[KB 313164](https://knowledge.broadcom.com/external/article/313164/configure-a-guest-customization-method-f.html),
но требует vCenter 8.0 Update 3. На vSphere 7.0.3 он не работает. Проверено:
в образе такого файла нет.

Рабочий путь для Astra это cloud-init с datasource VMware, параметры передаются
через `extra_config` (`guestinfo.metadata`, `guestinfo.userdata`).

## Проверка образа перед развёртыванием

В репозитории есть автономный инструмент. Сеть ему не нужна, зависимостей нет.

```sh
python3 scripts/ova-inspect.py alse-1.8.5-max-vsphere-mg16.4.0-amd64.ova
```

Команда печатает guest id, hardware version, конфигурацию и манифест с
контрольными суммами.

Чтобы посмотреть содержимое файловой системы, распакуйте диск в raw:

```sh
python3 scripts/ova-inspect.py <образ>.ova --extract-disk disk.raw
```

Файл получается разреженным, реально занимает столько, сколько занимают данные.
Дальше на Debian и Astra:

```sh
sudo losetup --find --partscan --show --read-only disk.raw
sudo mount -o ro /dev/loopNp2 /mnt
cat /mnt/etc/astra/build_version
```

Так проверяется, какая именно сборка внутри, до переноса образа в контур.

## Развёртывание

### Подготовка окружения

Инструменты и доверие к сертификату vCenter настраиваются один раз на машине.

Windows:

```powershell
cd $HOME\vsphere-terraform
python .\vsphere.py install
python .\vsphere.py trust --server incvc.inc.elara.local
$env:Path = "$PWD\.vsphere-tools\windows_amd64\bin;$env:Path"

$env:GOVC_URL          = 'https://incvc.inc.elara.local/sdk'
$Credential            = Get-Credential -Message 'vCenter'
$env:GOVC_USERNAME     = $Credential.UserName
$env:GOVC_PASSWORD     = $Credential.GetNetworkCredential().Password
$env:GOVC_TLS_CA_CERTS = "$PWD\.vsphere-trust\incvc.inc.elara.local.pem"
$env:GOVC_DATACENTER   = 'INC'

govc about
```

Debian и Astra:

```sh
cd ~/vsphere-terraform
python3 ./vsphere.py install
python3 ./vsphere.py trust --server incvc.inc.elara.local
export PATH="$PWD/.vsphere-tools/linux_amd64/bin:$PATH"

export GOVC_URL='https://incvc.inc.elara.local/sdk'
export GOVC_USERNAME='<учётная-запись>'
read -r -s -p 'Пароль vCenter: ' GOVC_PASSWORD; export GOVC_PASSWORD; printf '\n'
export GOVC_TLS_CA_CERTS="$PWD/.vsphere-trust/incvc.inc.elara.local.pem"
export GOVC_DATACENTER='INC'

govc about
```

`govc about` должен вернуть версию vCenter. Если он падает на сертификате,
значит шаг `trust` не выполнен. Отключать проверку TLS не нужно.

### Куда класть машину

Точные имена берутся из отчёта скана, гадать не надо:

```sh
govc ls /INC/vm
govc ls /INC/datastore
govc ls /INC/network
govc ls /INC/host
```

### Параметры импорта

`govc import.spec <образ>.ova` печатает заготовку. Для этих образов она
предсказуемая: свойств OVF внутри нет, сеть в дескрипторе одна и называется
`VM Network`. Готовый `ova.json`:

```json
{
  "DiskProvisioning": "thin",
  "IPAllocationPolicy": "dhcpPolicy",
  "IPProtocol": "IPv4",
  "PropertyMapping": null,
  "NetworkMapping": [
    {
      "Name": "VM Network",
      "Network": "<ИМЯ-ПОРТГРУППЫ>"
    }
  ],
  "MarkAsTemplate": false,
  "PowerOn": false,
  "InjectOvfEnv": false,
  "WaitForIP": false,
  "Name": "<ИМЯ-ВМ>"
}
```

Поле `Name` в блоке `NetworkMapping` это имя сети внутри OVF, его менять не
надо. Меняется только `Network`, это имя портгруппы в вашем vCenter.

### Импорт

```sh
govc import.ova -options=ova.json \
  -folder='<ПАПКА>' \
  -ds='<DATASTORE>' \
  -pool='/INC/host/INC-Cluster/Resources' \
  <образ>.ova
```

Загрузка идёт с той машины, где лежит файл, поэтому запускать команду надо там
же, куда скачан образ.

Через vSphere Client то же самое делается мастером `Deploy OVF Template` с
выбором `Local file`. Результат одинаковый, но браузер грузит 725 МиБ медленнее
и не даёт повторяемости.

Provider `vmware/vsphere` 2.15.1 умеет импорт декларативно, через блок
`ovf_deploy` ресурса `vsphere_virtual_machine`. Это работает только через
vCenter, напрямую к ESXi подключаться нельзя.

### После импорта

Образ приходит с 2 vCPU, 2 ГБ RAM и диском 16 ГБ. Для рабочей машины это мало,
правится до первого включения:

```sh
govc vm.change -vm '<ИМЯ-ВМ>' -c 4 -m 8192
govc vm.disk.change -vm '<ИМЯ-ВМ>' -disk.label 'Hard disk 1' -size 60G
govc vm.power -on '<ИМЯ-ВМ>'
govc vm.info '<ИМЯ-ВМ>'
```

Дальше консоль открывается из vSphere Client, либо ссылкой от
`govc vm.console -vm '<ИМЯ-ВМ>'`. Вход `astra/astra`.

Первые действия внутри гостя:

```sh
passwd
cat /etc/astra/build_version
sudo parted -s /dev/sda resizepart 2 100%
sudo resize2fs /dev/sda2
```

Пакета `cloud-guest-utils` в образе нет, поэтому привычного `growpart` там не
будет, пока не подключен репозиторий. `parted` растягивает последний раздел на
живой системе, ядро подхватывает новый размер сразу. Если не подхватило,
хватит перезагрузки.
