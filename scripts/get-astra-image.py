#!/usr/bin/env python3
"""Download an Astra Linux vSphere image and verify its published SHA-256."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

DEFAULT_BASE_URL = "https://registry.astralinux.ru/images/alse/vsphere"
LEVELS = ("base", "adv", "max")
LEVEL_NAMES = {"base": "Орёл", "adv": "Воронеж", "max": "Смоленск"}
IMAGE_PATTERN = re.compile(
    r"^alse-(?P<version>[0-9][0-9.a-z]*)"
    r"-(?P<level>base|adv|max)"
    r"-vsphere-(?P<build>[^-]+)"
    r"-(?P<arch>[^-.]+)\.ova$"
)
BUILD_NUMBERS = re.compile(r"\d+")
CHUNK = 1024 * 1024
TIMEOUT = 60


class DownloadError(RuntimeError):
    pass


def configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(errors="replace")


def fetch(url: str, offset: int = 0):
    request = urllib.request.Request(url)
    if offset:
        request.add_header("Range", "bytes={}-".format(offset))
    try:
        return urllib.request.urlopen(request, timeout=TIMEOUT)
    except urllib.error.HTTPError as error:
        raise DownloadError("{} вернул HTTP {}".format(url, error.code)) from error
    except urllib.error.URLError as error:
        raise DownloadError("Нет связи с {}: {}".format(url, error.reason)) from error


def list_images(base_url: str) -> list[dict]:
    with fetch(base_url + "/") as response:
        body = response.read().decode("utf-8", "replace")

    images = []
    for name in dict.fromkeys(re.findall(r'href="([^"]+\.ova)"', body)):
        match = IMAGE_PATTERN.match(name)
        if match:
            images.append(dict(match.groupdict(), name=name))
    if not images:
        raise DownloadError("В каталоге {} не найдено ни одного .ova".format(base_url))
    return images


def build_rank(build: str) -> tuple:
    # "latest" это алиас, он должен проигрывать любой конкретной сборке mgX.Y.Z.
    if build == "latest":
        return (0,)
    return (1,) + tuple(int(part) for part in BUILD_NUMBERS.findall(build))


def select_image(images: list[dict], version: str, level: str, build: Optional[str]) -> str:
    matches = [i for i in images if i["version"] == version and i["level"] == level]
    if build:
        matches = [i for i in matches if i["build"] == build]
    if not matches:
        available = sorted({i["version"] for i in images})
        raise DownloadError(
            "Нет образа {} {}{}. Доступные версии: {}".format(
                version,
                level,
                " сборки " + build if build else "",
                ", ".join(available),
            )
        )
    return max(matches, key=lambda i: build_rank(i["build"]))["name"]


def expected_digest(base_url: str, name: str) -> str:
    with fetch("{}/{}.sha256".format(base_url, name)) as response:
        # Файл содержит только хеш, без имени файла.
        return response.read().decode("ascii", "replace").split()[0].strip().lower()


def download(base_url: str, name: str, target: Path) -> None:
    url = "{}/{}".format(base_url, name)
    offset = target.stat().st_size if target.exists() else 0

    with fetch(url, offset) as response:
        resumed = response.status == 206
        if offset and not resumed:
            offset = 0
        remaining = int(response.headers.get("Content-Length") or 0)
        total = offset + remaining
        if offset:
            print("Продолжаю загрузку с {:.1f} МиБ".format(offset / 1048576))

        done = offset
        step = -1
        with open(target, "ab" if offset else "wb") as handle:
            while True:
                chunk = response.read(CHUNK)
                if not chunk:
                    break
                handle.write(chunk)
                done += len(chunk)
                if total:
                    percent = done * 100 // total
                    if percent != step:
                        step = percent
                        print(
                            "\r{:3d}%  {:.0f} из {:.0f} МиБ".format(
                                percent, done / 1048576, total / 1048576
                            ),
                            end="",
                            flush=True,
                        )
        print()


def digest_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="1.8.5", help="Версия ОС, например 1.8.5.")
    parser.add_argument(
        "--level",
        default="max",
        choices=LEVELS,
        help="Уровень защищённости: base Орёл, adv Воронеж, max Смоленск.",
    )
    parser.add_argument("--build", help="Точная сборка образа, например mg16.4.0.")
    parser.add_argument("--image", help="Имя файла целиком, вместо version/level/build.")
    parser.add_argument("--output-dir", type=Path, default=Path.cwd())
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL, help="Каталог с образами.")
    parser.add_argument("--list", action="store_true", help="Показать доступные образы.")
    args = parser.parse_args(argv)

    base_url = args.base_url.rstrip("/")

    if args.list:
        for image in sorted(list_images(base_url), key=lambda i: i["name"]):
            print(
                "{name}\n    версия {version}, {level} ({human}), сборка {build}".format(
                    human=LEVEL_NAMES[image["level"]], **image
                )
            )
        return 0

    name = args.image or select_image(
        list_images(base_url), args.version, args.level, args.build
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    target = args.output_dir / name

    digest = expected_digest(base_url, name)
    if target.exists() and digest_of(target) == digest:
        print("Файл уже скачан и проверен: {}".format(target))
        return 0

    print("Образ:  {}".format(name))
    print("Куда:   {}".format(target))
    download(base_url, name, target)

    actual = digest_of(target)
    if actual != digest:
        # Битый файл убирается с дороги, иначе следующий запуск попробует его дочитать.
        target.replace(target.with_suffix(target.suffix + ".bad"))
        raise DownloadError(
            "SHA-256 не совпал.\n  ожидался {}\n  получен  {}".format(digest, actual)
        )

    print("SHA-256 совпал: {}".format(digest))
    print("Готово: {}".format(target))
    return 0


if __name__ == "__main__":
    configure_stdio()
    try:
        sys.exit(main(sys.argv[1:]))
    except DownloadError as error:
        print("Ошибка: {}".format(error), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nПрервано. Повторный запуск продолжит загрузку.", file=sys.stderr)
        sys.exit(130)
