"""Adds the log receiver address to a local development package: add_log_url.py <file.deb> <url>"""
import io
import lzma
import pathlib
import sys
import tarfile

from clean_deb import read_ar, write_ar

URL_FILE = "var/jb/Library/MobileSubstrate/DynamicLibraries/RedditLegacy.url"


def add_url(blob: bytes, url: str) -> bytes:
    out = io.BytesIO()
    content = (url + "\n").encode()
    with tarfile.open(fileobj=io.BytesIO(blob)) as source, tarfile.open(
        fileobj=out, mode="w", format=tarfile.USTAR_FORMAT
    ) as target:
        for member in source.getmembers():
            target.addfile(member, source.extractfile(member) if member.isfile() else None)
        info = tarfile.TarInfo(URL_FILE)
        info.size = len(content)
        info.mode = 0o644
        target.addfile(info, io.BytesIO(content))
    return lzma.compress(out.getvalue(), format=lzma.FORMAT_ALONE)


def main(path: pathlib.Path, url: str) -> None:
    members = [(name, add_url(data, url) if name == "data.tar.lzma" else data) for name, data in read_ar(path.read_bytes())]
    path.write_bytes(write_ar(members))


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]), sys.argv[2])
