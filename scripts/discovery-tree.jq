[
  "TYPE\tREF\tINVENTORY PATH"
] + [
  .inventory.objects[] |
  "\(.type)\t\(.ref)\t\(.path)"
] | join("\n") + "\n"
