# Доступ к vCenter

Terraform использует vSphere API. Машина запуска должна разрешать DNS и TCP/443
до `incvc.inc.elara.local` и доверять его TLS-сертификату.

Рекомендуются две учётные записи:

1. Discovery/inventory account — Read Only на корне vCenter с наследованием,
   если нужен полный скан; либо на нужном datacenter для ограниченного обзора.
2. Provisioning account — только на целевой folder/resource pool/datastore/
   network/template.

Кроме обычных CRUD-прав provider может требовать чтение tags/events,
`StorageProfile.View` и `VirtualMachine.Config.SwapPlacement`. Не выдавайте
глобального Administrator только ради устранения ошибки permission denied.

Для Windows full clone дополнительно нужны как минимум права clone/customize на
source, создание VM в target folder, назначение resource pool, выделение места
на datastore, назначение network и power-on target. Scope этих прав ограничьте
`tst-win-10-12` и конкретными target-объектами.

Переменные окружения:

- `VSPHERE_SERVER`
- `VSPHERE_USER`
- `VSPHERE_PASSWORD`

Provider фиксирует `allow_unverified_ssl = false`, `persist_session = false` и
`client_debug = false`. Для внутреннего CA установите корневой сертификат в
системный trust store runner-а.

Полный read-only скан выполняется отдельно до Terraform plan. Он видит только
объекты, доступные учётной записи, и описан в [discovery.md](discovery.md).
