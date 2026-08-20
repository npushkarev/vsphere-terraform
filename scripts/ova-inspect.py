#!/usr/bin/env python3
"""Inspect an OVA offline: print its OVF summary and unpack the virtual disk."""

from __future__ import annotations

import argparse
import re
import struct
import sys
import tarfile
import zlib
from pathlib import Path

SPARSE_MAGIC = 0x564D444B
MARKER_EOS = 0
COMPRESS_DEFLATE = 1


class InspectError(RuntimeError):
    pass


def read_member(archive: Path, suffix: str) -> tuple[str, bytes]:
    with tarfile.open(archive) as tar:
        for member in tar:
            if member.isfile() and member.name.lower().endswith(suffix):
                handle = tar.extractfile(member)
                if handle is None:
                    break
                return member.name, handle.read()
    raise InspectError("В архиве {} нет файла {}".format(archive, suffix))


def disk_member_name(archive: Path) -> str:
    with tarfile.open(archive) as tar:
        for member in tar:
            if member.isfile() and member.name.lower().endswith(".vmdk"):
                return member.name
    raise InspectError("В архиве {} нет .vmdk".format(archive))


def summarize_ovf(text: str) -> list[str]:
    lines = []
    os_type = re.search(r'vmw:osType="([^"]+)"', text)
    hardware = re.search(r"<vssd:VirtualSystemType>([^<]+)<", text)
    capacity = re.search(r'ovf:capacity="(\d+)"', text)
    quantities = re.findall(r"<rasd:VirtualQuantity>(\d+)<", text)
    subtypes = re.findall(r"<rasd:ResourceSubType>([^<]+)<", text)
    networks = re.findall(r'<Network ovf:name="([^"]+)"', text)

    if os_type:
        lines.append("guest id: {}".format(os_type.group(1)))
    if hardware:
        lines.append("hardware version: {}".format(hardware.group(1)))
    if len(quantities) >= 2:
        lines.append("vCPU: {}".format(quantities[0]))
        lines.append("RAM, МБ: {}".format(quantities[1]))
    if capacity:
        lines.append("диск, МБ: {}".format(capacity.group(1)))
    if subtypes:
        lines.append("устройства: {}".format(", ".join(sorted(set(subtypes)))))
    if networks:
        lines.append("сети в дескрипторе: {}".format(", ".join(networks)))
    return lines


def read_exact(source, count: int) -> bytes:
    chunks = []
    left = count
    while left > 0:
        chunk = source.read(left)
        if not chunk:
            break
        chunks.append(chunk)
        left -= len(chunk)
    return b"".join(chunks)


def extract_disk(archive: Path, target: Path) -> None:
    name = disk_member_name(archive)
    grains = 0
    with tarfile.open(archive) as tar:
        source = tar.extractfile(tar.getmember(name))
        if source is None:
            raise InspectError("Не удалось прочитать {}".format(name))
        header = read_exact(source, 512)
        magic, _version, _flags, capacity, _grain = struct.unpack_from("<IIIQQ", header, 0)
        if magic != SPARSE_MAGIC:
            raise InspectError("{} не является VMDK".format(name))
        if struct.unpack_from("<H", header, 77)[0] != COMPRESS_DEFLATE:
            raise InspectError("Поддерживается только streamOptimized (deflate)")
        overhead = struct.unpack_from("<Q", header, 64)[0]

        with open(target, "wb") as out:
            out.truncate(capacity * 512)
            # Данные лежат после служебных секторов, а не сразу за заголовком.
            read_exact(source, overhead * 512 - 512)
            while True:
                marker = read_exact(source, 512)
                if len(marker) < 512:
                    break
                value, size = struct.unpack_from("<QI", marker, 0)
                if size == 0:
                    if struct.unpack_from("<I", marker, 12)[0] == MARKER_EOS:
                        break
                    read_exact(source, value * 512)
                    continue
                total = ((12 + size + 511) // 512) * 512
                payload = marker[12 : 12 + size]
                payload += read_exact(source, size - len(payload))
                read_exact(source, total - 512 - max(0, size - 500))
                out.seek(value * 512)
                out.write(zlib.decompress(payload))
                grains += 1

    print("распаковано грейнов: {}".format(grains))
    print("образ: {}".format(target))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ova", type=Path)
    parser.add_argument(
        "--extract-disk",
        type=Path,
        help="Распаковать виртуальный диск в raw-образ по указанному пути.",
    )
    args = parser.parse_args(argv)

    if not args.ova.is_file():
        raise InspectError("Файл не найден: {}".format(args.ova))

    name, blob = read_member(args.ova, ".ovf")
    text = blob.decode("utf-8", "replace")
    print("OVF: {}".format(name))
    for line in summarize_ovf(text):
        print("  {}".format(line))

    try:
        _, manifest = read_member(args.ova, ".mf")
    except InspectError:
        manifest = b""
    if manifest:
        print("MANIFEST:")
        for line in manifest.decode("utf-8", "replace").splitlines():
            if line.strip():
                print("  {}".format(line.strip()))

    if args.extract_disk:
        extract_disk(args.ova, args.extract_disk)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except InspectError as error:
        print("Ошибка: {}".format(error), file=sys.stderr)
        sys.exit(1)
