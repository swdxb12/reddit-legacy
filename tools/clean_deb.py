"""Rewrites a .deb in place without dates or build-machine owners: clean_deb.py <file.deb>"""
import gzip
import io
import lzma
import pathlib
import sys
import tarfile


def read_ar(deb: bytes) -> list[tuple[str, bytes]]:
    if deb[:8] != b"!<arch>\n":
        raise ValueError("not a deb archive")
    members, pos = [], 8
    while pos < len(deb):
        name = deb[pos:pos + 16].decode().strip().rstrip("/")
        size = int(deb[pos + 48:pos + 58])
        members.append((name, deb[pos + 60:pos + 60 + size]))
        pos += 60 + size + (size & 1)
    return members


def write_ar(members: list[tuple[str, bytes]]) -> bytes:
    out = bytearray(b"!<arch>\n")
    for name, data in members:
        out += f"{name:<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode()
        out += data
        if len(data) & 1:
            out += b"\n"
    return bytes(out)


def clean_tar(blob: bytes) -> bytes:
    out = io.BytesIO()
    with tarfile.open(fileobj=io.BytesIO(blob)) as source, tarfile.open(
        fileobj=out, mode="w", format=tarfile.USTAR_FORMAT
    ) as target:
        for member in source.getmembers():
            content = source.extractfile(member) if member.isfile() else None
            member.mtime = 0
            member.uid = member.gid = 0
            member.uname = member.gname = ""
            target.addfile(member, content)
    return out.getvalue()


def clean_member(name: str, data: bytes) -> bytes:
    if name.endswith(".tar.gz"):
        return gzip.compress(clean_tar(data), mtime=0)
    if name.endswith(".tar.lzma"):
        return lzma.compress(clean_tar(data), format=lzma.FORMAT_ALONE)
    if ".tar" in name:
        raise ValueError(f"unsupported member compression: {name}")
    return data


def main(path: pathlib.Path) -> None:
    members = read_ar(path.read_bytes())
    path.write_bytes(write_ar([(name, clean_member(name, data)) for name, data in members]))


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]))
