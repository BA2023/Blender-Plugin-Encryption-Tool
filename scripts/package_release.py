"""Package the bundled Windows tool without local build data or Git metadata."""

import hashlib
import json
import re
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DIRECTORIES = ("assets", "config", "scripts", "compiler", "python_envs")
FILES = ("Start Tool.bat", "README.txt", "README.md")


def main() -> None:
    gui = (ROOT / "scripts" / "gui_launcher.ps1").read_text(encoding="utf-8-sig")
    match = re.search(r'^\$ToolVersion\s*=\s*"(v[0-9]+(?:\.[0-9]+)*)"', gui, re.MULTILINE)
    if not match:
        raise RuntimeError("Cannot read ToolVersion from gui_launcher.ps1")
    version = match.group(1)

    required = [ROOT / name for name in (*DIRECTORIES, *FILES)]
    required.append(ROOT / "compiler" / "bin" / "gcc.exe")
    versions = json.loads((ROOT / "config" / "versions.json").read_text(encoding="utf-8-sig"))
    required.extend(ROOT / info["python"] for info in versions["versions"].values())
    missing = [str(p.relative_to(ROOT)) for p in required if not p.exists()]
    if missing:
        raise FileNotFoundError("Missing package files: " + ", ".join(missing))

    members = [ROOT / name for name in FILES]
    for name in DIRECTORIES:
        for p in sorted((ROOT / name).rglob("*")):
            if not p.is_file():
                continue
            if "__pycache__" in p.parts or p.suffix.lower() in (".pyc", ".pyo"):
                continue
            if not p.resolve().is_relative_to(ROOT):
                raise RuntimeError(f"Package member resolves outside the project: {p}")
            members.append(p)

    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    stem = f"Blender-Plugin-Encryption-Tool-{version}-Windows-x64"
    archive = dist / f"{stem}.zip"
    if archive.exists():
        raise FileExistsError(f"Release archive already exists: {archive}")
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for p in members:
            z.write(p, arcname=Path(stem) / p.relative_to(ROOT))
    with zipfile.ZipFile(archive) as z:
        bad = z.testzip()
        if bad:
            raise RuntimeError(f"Archive integrity check failed: {bad}")
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    checksum = dist / f"{archive.name}.sha256"
    checksum.write_text(f"{digest}  {archive.name}\n", encoding="ascii")
    print(json.dumps({"archive": str(archive), "files": len(members),
                      "bytes": archive.stat().st_size, "sha256": digest}))


if __name__ == "__main__":
    main()
