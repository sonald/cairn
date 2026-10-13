#!/usr/bin/env python3
"""Build two-commit synthetic fixtures whose only semantic difference is a server config file,
so `s0_probe.py switch` can test whether a warm server re-reads it after an in-place checkout.

  make_config_fixtures.py OUT_DIR   -> OUT_DIR/pyright-config, OUT_DIR/ts-config (git repos)

pyright-config: pyrightconfig.json `extraPaths` points at libA (commit 1) then libB (commit 2);
                main.py `from helper import f`; definition of `f` must move libA -> libB.
ts-config:      tsconfig.json `paths` maps `@lib/*` to libA (commit 1) then libB (commit 2);
                main.ts `import { f } from '@lib/helper'`; same expectation.
Prints the two commit SHAs for each fixture.
"""
import json
import os
import subprocess
import sys


def git(repo, *args):
    subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True,
                   env=dict(os.environ, GIT_AUTHOR_NAME="s0", GIT_AUTHOR_EMAIL="s0@example.invalid",
                            GIT_COMMITTER_NAME="s0", GIT_COMMITTER_EMAIL="s0@example.invalid"))


def write(repo, rel, text):
    path = os.path.join(repo, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def commit(repo, message):
    git(repo, "add", "-A")
    git(repo, "commit", "-q", "-m", message)
    return subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True,
                          text=True, check=True).stdout.strip()


def pyright_fixture(root):
    repo = os.path.join(root, "pyright-config")
    os.makedirs(repo)
    git(repo, "init", "-q")
    write(repo, "libA/helper.py", "def f() -> int:\n    return 1\n")
    write(repo, "libB/helper.py", "# libB\ndef f() -> str:\n    return 'b'\n")
    write(repo, "main.py", "from helper import f\n\nprint(f())\n")
    write(repo, "pyrightconfig.json", json.dumps({"extraPaths": ["libA"]}, indent=2) + "\n")
    a = commit(repo, "extraPaths -> libA")
    write(repo, "pyrightconfig.json", json.dumps({"extraPaths": ["libB"]}, indent=2) + "\n")
    b = commit(repo, "extraPaths -> libB")
    return repo, a, b


def ts_fixture(root):
    repo = os.path.join(root, "ts-config")
    os.makedirs(repo)
    git(repo, "init", "-q")
    write(repo, "libA/helper.ts", "export function f(): number {\n  return 1\n}\n")
    write(repo, "libB/helper.ts", "// libB\nexport function f(): string {\n  return 'b'\n}\n")
    write(repo, "src/main.ts", "import { f } from '@lib/helper'\n\nconsole.log(f())\n")
    base = {"compilerOptions": {"target": "ES2020", "module": "ESNext", "moduleResolution": "Bundler",
                                "strict": True, "baseUrl": ".", "paths": {"@lib/*": ["libA/*"]}},
            "include": ["src", "libA", "libB"]}
    write(repo, "tsconfig.json", json.dumps(base, indent=2) + "\n")
    a = commit(repo, "paths -> libA")
    base["compilerOptions"]["paths"] = {"@lib/*": ["libB/*"]}
    write(repo, "tsconfig.json", json.dumps(base, indent=2) + "\n")
    b = commit(repo, "paths -> libB")
    return repo, a, b


def main():
    root = os.path.abspath(sys.argv[1])
    os.makedirs(root, exist_ok=True)
    for name, make in (("pyright", pyright_fixture), ("ts", ts_fixture)):
        repo, a, b = make(root)
        print(f"{name}: repo={repo} from={a[:9]} to={b[:9]}")


if __name__ == "__main__":
    main()
