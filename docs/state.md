# Terraform state

Локальный state подходит только для первого read-only знакомства. Для рабочего
управления VM используйте remote backend, который предоставляет:

- TLS;
- шифрование at rest;
- разграничение доступа;
- version history/backup;
- обязательный state locking.

Пример HTTP backend находится в `backend.tf.example`. Скопируйте его в
`backend.tf`, а URL и credentials передавайте через `TF_HTTP_*` переменные
окружения. Для `inventory`, `vm-clones` и `windows-clone` нужны разные state
addresses.

Windows clone stack намеренно не принимает guest/domain passwords или product
key. Добавление таких sensitive-полей всё равно записало бы их в state и saved
plan; пометка `sensitive` скрывает вывод, но не удаляет значение из артефактов.

Не используйте `-lock=false`. Не коммитьте state, state backup или plan. Даже
значения, помеченные `sensitive`, могут храниться в state/plan открытым текстом.
