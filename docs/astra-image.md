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

Загрузка OVA в vSphere:

```sh
govc import.spec <образ>.ova > ova.json
# в ova.json задайте Name, NetworkMapping и DiskProvisioning
govc import.ova -options=ova.json \
  -folder='<ПАПКА>' \
  -ds='<DATASTORE>' \
  -pool='/INC/host/INC-Cluster/Resources' \
  <образ>.ova
```

Provider `vmware/vsphere` 2.15.1 умеет то же самое декларативно через блок
`ovf_deploy` ресурса `vsphere_virtual_machine`. Это работает только через
vCenter, напрямую к ESXi подключаться нельзя.

Диск в образе 16 ГБ. Для рабочей машины его расширяют до включения:

```sh
govc vm.disk.change -vm '<ИМЯ_VM>' -disk.label 'Hard disk 1' -size 60G
govc vm.change -vm '<ИМЯ_VM>' -c 4 -m 8192
```

Внутри гостя после загрузки останется растянуть раздел `sda2` и файловую
систему.
