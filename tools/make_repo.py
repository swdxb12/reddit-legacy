"""Builds a flat APT repo for Sileo: python -I tools/make_repo.py <folder with .deb> <repo folder>"""
import bz2
import gzip
import hashlib
import io
import lzma
import pathlib
import shutil
import sys
import tarfile

HASHES = (("MD5Sum", "md5"), ("SHA1", "sha1"), ("SHA256", "sha256"))


def read_control(deb: bytes) -> str:
    if deb[:8] != b"!<arch>\n":
        raise ValueError("not a deb archive")
    pos = 8
    while pos < len(deb):
        name = deb[pos:pos + 16].decode().strip().rstrip("/")
        size = int(deb[pos + 48:pos + 58])
        if name.startswith("control.tar"):
            with tarfile.open(fileobj=io.BytesIO(deb[pos + 60:pos + 60 + size])) as tar:
                for member in tar.getmembers():
                    if member.name.lstrip("./") == "control":
                        return tar.extractfile(member).read().decode().strip()
        pos += 60 + size + (size & 1)
    raise ValueError("deb has no control file")


def package_entry(deb_path: pathlib.Path) -> str:
    deb = deb_path.read_bytes()
    return "\n".join([
        read_control(deb),
        f"Filename: ./debs/{deb_path.name}",
        f"Size: {len(deb)}",
        f"MD5sum: {hashlib.md5(deb).hexdigest()}",
        f"SHA1: {hashlib.sha1(deb).hexdigest()}",
        f"SHA256: {hashlib.sha256(deb).hexdigest()}",
    ])


def main(source: pathlib.Path, repo: pathlib.Path) -> None:
    debs = repo / "debs"
    debs.mkdir(parents=True, exist_ok=True)
    for old in debs.glob("*.deb"):
        old.unlink()
    for deb in sorted(source.glob("*.deb")):
        shutil.copy2(deb, debs / deb.name)

    packages = ("\n\n".join(package_entry(d) for d in sorted(debs.glob("*.deb"))) + "\n").encode()
    indexes = {
        "Packages": packages,
        # mtime=0 keeps the index free of build-time data.
        "Packages.gz": gzip.compress(packages, mtime=0),
        "Packages.bz2": bz2.compress(packages),
        "Packages.xz": lzma.compress(packages),
    }
    for name, content in indexes.items():
        (repo / name).write_bytes(content)

    release = [
        "Origin: RedditLegacy",
        "Label: RedditLegacy",
        "Suite: stable",
        "Version: 1.0",
        "Codename: stable",
        "Architectures: iphoneos-arm64",
        "Components: main",
        "Description: RedditLegacy tweak",
    ]
    for field, algorithm in HASHES:
        release.append(f"{field}:")
        for name, content in indexes.items():
            digest = hashlib.new(algorithm, content).hexdigest()
            release.append(f" {digest} {len(content)} {name}")
    (repo / "Release").write_text("\n".join(release) + "\n", newline="\n")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
