# Обновление vendored toolchain

Этот документ только для сопровождающих. Обычная установка, проверка, сборка
offline bundle и работа launcher-а сеть для загрузки инструментов не используют.

Текущий `vendor/` занимает около 127 МиБ и хранится в обычном Git без LFS.
Каждый blob обязан быть меньше 95 МиБ по политике репозитория (жёсткий лимит
GitHub — 100 МиБ). Не коммитьте объединённый archive и `offline-dist/`: это
создаст дубликат бинарной истории.

При осознанном обновлении на отдельной доверенной машине с интернетом:

1. Выберите совместимые exact-версии Terraform CLI, provider, govc и jq.
2. Скачайте только официальные release assets по явным URL, никогда `latest`.
3. Проверьте upstream signatures/attestations и закреплённые SHA-256.
4. Обновите оба x64 package в `vendor/provider-mirror`, все три lock-файла,
   `.terraform-version`, `.govc-version`, `.jq-version`, лицензии и notices.
5. Обновите `vendor/provenance.json`, затем пересоздайте
   `vendor/MANIFEST.sha256` в стабильном лексикографическом порядке.
6. Выполните `./scripts/verify-vendor.sh`, unit tests и offline init всех stacks
   на Linux и Windows.
7. Проведите отдельный review бинарного diff и подпишите/утвердите commit или tag
   согласно внутреннему процессу поставки.

Manifest внутри того же Git commit подтверждает целостность набора, но не
является независимым доказательством происхождения. Digest подписанного commit,
tag или внутреннего release-manifest передавайте отдельным доверенным каналом.
