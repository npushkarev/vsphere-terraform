# Offline Astra/TeamCity

Основные целевые платформы — `linux_amd64` и `windows_amd64`. Linux bundle
собирается так:

```sh
make offline-bundle PLATFORM=linux_amd64
```

Windows bundle можно собрать в PowerShell:

```powershell
.\scripts\build-offline-bundle.ps1
```

Результат появится в
`offline-dist/` и содержит:

- Terraform CLI archive (Linux проверяется через подписанный `SHA256SUMS`,
  Windows — через закреплённый в репозитории SHA-256);
- provider mirror с `vmware/vsphere = 2.15.1`;
- offline installer;
- CLI config без `direct {}` fallback.

На закрытой машине должны быть рабочая копия этого репозитория и распакованный
bundle. Передайте их утверждённым внутренним каналом. Из каталога bundle
выполните:

```sh
./install-offline.sh --prefix "$HOME/.local/share/vsphere-terraform"
```

Windows x64:

```powershell
.\install-offline.ps1 -Prefix "$env:LOCALAPPDATA\vsphere-terraform"
```

Затем используйте напечатанные installer-ом команды `PATH` и
`TF_CLI_CONFIG_FILE`. Вернитесь в рабочую копию репозитория и выполните
полностью закрытую проверку:

```sh
terraform -chdir=stacks/inventory init -backend=false -lockfile=readonly
terraform -chdir=stacks/inventory validate
terraform -chdir=stacks/vm-clones init -backend=false -lockfile=readonly
terraform -chdir=stacks/vm-clones validate
```

Provider binaries не коммитятся в Git. Lock-файлы коммитятся и проверяют
checksum пакетов mirror-а.
