# Доступ к vCenter

Terraform использует vSphere API. Машина запуска должна разрешать DNS и TCP/443
до `incvc.inc.elara.local` и доверять его TLS-сертификату.

Рекомендуются две учётные записи:

1. Inventory account — Read Only на нужном datacenter.
2. Provisioning account — только на целевой folder/resource pool/datastore/
   network/template.

Кроме обычных CRUD-прав provider может требовать чтение tags/events,
`StorageProfile.View` и `VirtualMachine.Config.SwapPlacement`. Не выдавайте
глобального Administrator только ради устранения ошибки permission denied.

Переменные окружения:

- `VSPHERE_SERVER`
- `VSPHERE_USER`
- `VSPHERE_PASSWORD`

Provider фиксирует `allow_unverified_ssl = false`, `persist_session = false` и
`client_debug = false`. Для внутреннего CA установите корневой сертификат в
системный trust store runner-а.
