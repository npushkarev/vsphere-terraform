# Импорт существующей VM

Import привязывает существующий объект к state, но не создаёт безопасную полную
конфигурацию автоматически.

1. Сделайте резервную копию remote state.
2. Добавьте VM в `virtual_machines` с параметрами, совпадающими с реальностью.
3. Скопируйте `stacks/vm-clones/imports.tf.example` в `imports.tf` и измените
   ключ/address/path.
4. Выполните plan, затем import.
5. Повторяйте plan и исправляйте конфигурацию, пока нет create/delete/replace.

CLI-вариант:

```sh
terraform -chdir=stacks/vm-clones import \
  -var-file=/absolute/private/vm-clones.tfvars \
  'module.linux_vm_clone.vsphere_virtual_machine.this["existing-vm"]' \
  '/INC/vm/<folder>/<existing-vm>'
```

Если следующий plan предлагает replacement, ничего не применяйте. Защита
`prevent_destroy` должна заблокировать уничтожение, но plan всё равно нужно
согласовать до no-op или ожидаемого in-place изменения.
