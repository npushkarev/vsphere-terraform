[.resource_changes[]? | select(.mode == "managed") |
  select(.change.actions != ["no-op"])] as $changes |
($changes | length) == 0 or
(($changes | length) == 1 and
  $changes[0].address == "vsphere_virtual_machine.clone" and
  $changes[0].change.actions == ["create"])
