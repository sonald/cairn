"""Copies the license files of every crate linked into the AI helper into
DIR (one folder per crate, plus a summary), for the app's Licenses folder.
usage: python3 scripts/ai-helper-notices.py DIR"""
import json, pathlib, shutil, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
out = pathlib.Path(sys.argv[1])
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--format-version", "1", "--locked",
    "--filter-platform", "aarch64-apple-darwin",
    "--manifest-path", str(root / "Helpers/cairn-ai/Cargo.toml"),
]))
linked = {node["id"] for node in metadata["resolve"]["nodes"]}
summary = []
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["id"] not in linked or package["name"] == "cairn-ai":
        continue
    name = f'{package["name"]}-{package["version"]}'
    summary.append(f'{name}\t{package.get("license") or "see files"}')
    source = pathlib.Path(package["manifest_path"]).parent
    files = [f for f in source.iterdir()
             if f.is_file() and f.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE"))]
    if files:
        (out / name).mkdir(parents=True, exist_ok=True)
        for f in files:
            shutil.copy(f, out / name / f.name)
out.mkdir(parents=True, exist_ok=True)
(out / "CRATES.txt").write_text("\n".join(summary) + "\n")
print(f"{len(summary)} crates")
