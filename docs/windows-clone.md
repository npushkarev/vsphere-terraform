# Клонирование Windows 10 из существующей VM

На последней фотографии из vSphere в колонке `Target` видна VM
`tst-win-10-12`. Stack `stacks/windows-clone` использует её как источник по
умолчанию. Если VM лежит в folder, укажите полный inventory path, например
`Test/tst-win-10-12`.

Provider умеет делать full clone обычной VM: преобразование в template и
snapshot не требуются. Source используется только как `data` и не импортируется
в Terraform state.

## Почему используется Sysprep

Provider после клонирования сам включает target VM и не имеет опции оставить её
выключенной. Exact clone без guest customization вышел бы в сеть со старыми
hostname, статическим IP, SID и доменной идентичностью.

Stack всегда выполняет Windows customization через Sysprep:

- задаёт уникальное имя компьютера;
- создаёт новый machine SID;
- помещает клон в workgroup;
- использует DHCP либо заранее зарезервированный статический IPv4;
- не принимает Windows, domain или product-key пароли.

Domain join выполняйте после клонирования отдельным защищённым механизмом. Поля
`admin_password`, `domain_admin_password`, `product_key` и полный Sysprep XML
даже при пометке `sensitive` хранились бы в state/plan.

## Проверки до plan

1. Убедитесь, что на `tst-win-10-12` установлены и исправно работают VMware
   Tools.
2. Убедитесь, что Windows Update не ждёт установки или перезагрузки и Sysprep не
   блокируется AppX/антивирусом.
3. Проверьте Windows activation, BitLocker, VBS/vTPM и наличие KMS/Native Key
   Provider, если они используются.
4. Поддерживаемый начальный вариант: ровно один NIC, все диски SCSI, системный
   диск на SCSI `0:0`.
5. Выключите source VM. Не включайте её снова до завершения clone task.
6. При статическом IP сначала зарезервируйте новый адрес в IPAM.

## Подготовка tfvars

Скопируйте пример в приватный путь за пределами Git:

```sh
cp stacks/windows-clone/windows-clone.tfvars.example \
  /private/path/windows-clone.tfvars
```

Замените cluster, datastore, target network и folder. Задайте уникальные
`target_vm_name` и `target_computer_name`; Windows computer name ограничен 15
символами. DHCP безопаснее для первого запуска, потому что target получает новый
виртуальный MAC.

После фактического выключения source установите точную строку:

```hcl
source_powered_off_acknowledgement = "tst-win-10-12 is powered off"
```

Data source provider не экспортирует power state, поэтому это обязательная
ручная проверка непосредственно перед plan и ещё раз перед apply.

## Plan и apply

Debian/Bash:

```sh
./scripts/plan.sh windows-clone /private/path/windows-clone.tfvars
terraform -chdir=stacks/windows-clone show /absolute/path/to/saved.tfplan
ALLOW_WINDOWS_CLONE_APPLY=yes ./scripts/apply-reviewed-plan.sh \
  /absolute/path/to/saved.tfplan
```

Windows PowerShell:

```powershell
.\scripts\plan.ps1 -Stack windows-clone -VarFile C:\private\windows-clone.tfvars
terraform -chdir=stacks/windows-clone show C:\absolute\path\to\saved.tfplan
$env:ALLOW_WINDOWS_CLONE_APPLY = "yes"
.\scripts\apply-reviewed-plan.ps1 -Plan C:\absolute\path\to\saved.tfplan
```

Wrapper разрешает только no-op либо ровно один `create` ресурса
`vsphere_virtual_machine.clone`. Update, delete, replace и дополнительные
managed resources блокируются. Ресурс также защищён `prevent_destroy = true`.

После apply проверьте в vCenter завершение Guest OS Customization, новый hostname,
SID, MAC и IP. Если Sysprep завершился ошибкой, не подключайте клон к production
и проверьте в госте `%WINDIR%\System32\Sysprep\Panther` и
`%WINDIR%\temp\toolsDeployPkg.log`.

Официальные ссылки:

- [vSphere provider 2.15.1: clone и Windows customization](https://github.com/vmware/terraform-provider-vsphere/blob/v2.15.1/docs/resources/virtual_machine.md#creating-a-virtual-machine-from-a-template)
- [Broadcom: Guest OS customization/Sysprep на vCenter 7](https://knowledge.broadcom.com/external/article/313408/guest-os-customization-doesnt-work-due-t.html)
- [Microsoft: процесс Sysprep](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/sysprep-process-overview)
