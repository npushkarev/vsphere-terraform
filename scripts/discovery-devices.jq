{
  devices: [
    (.devices // [])[] |
    if .type == "VirtualDisk" then
      {
        type,
        name,
        controllerKey,
        unitNumber,
        capacityInBytes,
        capacityInKB
      }
    elif ((.busNumber != null) and ((.type // "") | test("SCSI|LsiLogic|BusLogic"; "i"))) then
      {
        type,
        name,
        key,
        busNumber
      }
    elif has("macAddress") then
      {
        type,
        name,
        controllerKey,
        unitNumber,
        is_nic: true
      }
    elif .type == "VirtualTPM" then
      {
        type,
        name,
        key
      }
    else
      empty
    end
  ]
}
