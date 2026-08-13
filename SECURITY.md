# Security policy

- Никогда не коммитьте пароли, токены, `.tfvars`, state или saved plan.
- Не коммитьте и не загружайте в CI artifacts каталоги read-only scan: они
  содержат конфиденциальную топологию даже без паролей и guest IP/MAC.
- Не включайте `allow_unverified_ssl`, provider debug или persistent sessions.
- CA сервера получайте только через `vsphere.py trust` и подтверждайте отпечаток
  SHA-256 по независимому каналу, а не «на глаз» по факту успешного соединения.
- Используйте разные service accounts для read-only inventory и provisioning.
- Provisioning account ограничивайте конкретным VM folder/resource pool,
  datastore, network и template.
- Все изменения выполняйте только через saved plan после ручного review.
- При предложении `delete` или `replace` остановитесь и разберите причину.
- Не клонируйте Windows в production network без Sysprep: provider сам включает
  target, что создаёт конфликт hostname/IP/SID.
- Не передавайте Windows administrator, domain join или product-key секреты в
  Terraform: sensitive-значения всё равно сохраняются в state/plan.
- Для offline scan блокируйте внешний egress и разрешайте только DNS/TCP 443 до
  vCenter. Scanner очищает inherited proxy и `GOVC_*`, отключает session
  persistence/debug и требует проверяемый TLS.
- Утечка секрета требует немедленной ротации; удаления секрета из последнего
  коммита недостаточно, потому что он остаётся в Git history.

Уязвимости и обнаруженные секреты сообщайте владельцу репозитория приватным
каналом, а не через публичный issue.
