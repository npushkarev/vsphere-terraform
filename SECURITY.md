# Security policy

- Никогда не коммитьте пароли, токены, `.tfvars`, state или saved plan.
- Не включайте `allow_unverified_ssl`, provider debug или persistent sessions.
- Используйте разные service accounts для read-only inventory и provisioning.
- Provisioning account ограничивайте конкретным VM folder/resource pool,
  datastore, network и template.
- Все изменения выполняйте только через saved plan после ручного review.
- При предложении `delete` или `replace` остановитесь и разберите причину.
- Не клонируйте Windows в production network без Sysprep: provider сам включает
  target, что создаёт конфликт hostname/IP/SID.
- Не передавайте Windows administrator, domain join или product-key секреты в
  Terraform: sensitive-значения всё равно сохраняются в state/plan.
- Утечка секрета требует немедленной ротации; удаления секрета из последнего
  коммита недостаточно, потому что он остаётся в Git history.

Уязвимости и обнаруженные секреты сообщайте владельцу репозитория приватным
каналом, а не через публичный issue.
