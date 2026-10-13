#!/usr/bin/env python3
"""Generic warm-LSP-across-checkout probe for pyright / typescript-language-server.

switch: checkout FROM, start server rooted at REPO/SERVE_ROOT, warm up on FILE,
        checkout TO in place, then time until hover at FILE:LINE:COL contains EXPECT.
        First polls without re-opening the file (disk propagation), then re-opens it.
deps:   checkout REV, create optional symlinks, start server, print hover + definition
        at FILE:LINE:COL (run twice: with and without --link to compare).

  lsp_probe2.py switch --server pyright|tsserver --repo R [--serve-root REL] --from A --to B
                       --file F --line L --col C --expect STR [--notify] [--link SRC:REL ...]
  lsp_probe2.py deps   --server ... --repo R [--serve-root REL] --rev A --file F --line L --col C
                       [--link SRC:REL ...] [--python-path P]
"""
import argparse, json, os, queue, subprocess, sys, threading, time

TSSERVER = "/opt/homebrew/lib/node_modules/typescript/lib/tsserver.js"

SERVERS = {
    "pyright": {
        "cmd": ["pyright-langserver", "--stdio"],
        "lang": lambda p: "python",
        "init": {},
    },
    "tsserver": {
        "cmd": ["typescript-language-server", "--stdio"],
        "lang": lambda p: "typescriptreact" if p.endswith(".tsx") else "typescript",
        # mirrors TypeScriptLanguageServerProvider.initializationOptions
        "init": {
            "disableAutomaticTypingAcquisition": True,
            "plugins": [],
            "tsserver": {"path": TSSERVER, "logVerbosity": "off", "trace": "off",
                         "useSyntaxServer": "never"},
        },
    },
}


class LSP:
    def __init__(self, spec, root, python_path=None):
        self.spec, self.root, self.python_path = spec, os.path.realpath(root), python_path
        self.proc = subprocess.Popen(spec["cmd"], cwd=self.root, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.next_id, self.pending, self.lock = 1, {}, threading.Lock()
        self.opened = set()
        threading.Thread(target=self._reader, daemon=True).start()

    def _send(self, msg):
        data = json.dumps(msg).encode()
        with self.lock:
            self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
            self.proc.stdin.flush()

    def _reader(self):
        out = self.proc.stdout
        while True:
            headers = {}
            while True:
                line = out.readline()
                if not line:
                    return
                if line in (b"\r\n", b"\n"):
                    break
                k, v = line.decode().split(":", 1)
                headers[k.strip().lower()] = v.strip()
            self._dispatch(json.loads(out.read(int(headers["content-length"]))))

    def _dispatch(self, msg):
        if "id" in msg and "method" in msg:
            result = None
            if msg["method"] == "workspace/configuration":
                result = []
                for item in msg["params"]["items"]:
                    if item.get("section") == "python" and self.python_path:
                        result.append({"pythonPath": self.python_path})
                    else:
                        result.append(None)
            self._send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
        elif "id" in msg:
            q = self.pending.pop(msg["id"], None)
            if q is not None:
                q.put(msg)

    def request(self, method, params, timeout=120):
        rid = self.next_id
        self.next_id += 1
        q = queue.Queue()
        self.pending[rid] = q
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        msg = q.get(timeout=timeout)
        return {"__error__": msg["error"]} if "error" in msg else msg.get("result")

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def uri(self, rel):
        return "file://" + os.path.join(self.root, rel)

    def initialize(self):
        self.request("initialize", {
            "processId": os.getpid(),
            "rootUri": "file://" + self.root,
            "workspaceFolders": [{"uri": "file://" + self.root, "name": "root"}],
            "capabilities": {
                "textDocument": {"hover": {"contentFormat": ["markdown", "plaintext"]}},
                "workspace": {"configuration": True},
            },
            "initializationOptions": self.spec["init"],
        })
        self.notify("initialized", {})

    def did_open(self, rel):
        with open(os.path.join(self.root, rel), encoding="utf-8") as f:
            text = f.read()
        self.opened.add(rel)
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": self.uri(rel), "languageId": self.spec["lang"](rel), "version": 1, "text": text}})

    def did_close(self, rel):
        self.opened.discard(rel)
        self.notify("textDocument/didClose", {"textDocument": {"uri": self.uri(rel)}})

    def did_change_watched(self, rels):
        self.notify("workspace/didChangeWatchedFiles", {
            "changes": [{"uri": self.uri(r), "type": 2} for r in rels]})

    def hover_text(self, rel, line1, col1):
        r = self.request("textDocument/hover", {
            "textDocument": {"uri": self.uri(rel)},
            "position": {"line": line1 - 1, "character": col1 - 1}})
        if not r or "__error__" in r:
            return None
        c = r.get("contents")
        if isinstance(c, dict):
            return c.get("value")
        if isinstance(c, list):
            return "\n".join(x if isinstance(x, str) else x.get("value", "") for x in c)
        return str(c)

    def definition(self, rel, line1, col1):
        r = self.request("textDocument/definition", {
            "textDocument": {"uri": self.uri(rel)},
            "position": {"line": line1 - 1, "character": col1 - 1}})
        if not r or "__error__" in r:
            return []
        items = r if isinstance(r, list) else [r]
        return [i.get("uri") or i.get("targetUri") for i in items]

    def shutdown(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.notify("exit", None)
        except Exception:
            pass
        self.proc.kill()


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def checkout(repo, sha):
    t = time.perf_counter()
    git(repo, "checkout", "-q", "--detach", sha)
    return time.perf_counter() - t


def make_links(repo, links):
    for spec in links or []:
        src, rel = spec.split(":", 1)
        dst = os.path.join(repo, rel)
        if os.path.lexists(dst):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.symlink(os.path.realpath(src), dst)


def poll(fn, pred, timeout, every=0.2):
    t0, last = time.perf_counter(), None
    while time.perf_counter() - t0 < timeout:
        last = fn()
        if pred(last):
            return time.perf_counter() - t0, last
        time.sleep(every)
    return None, last


def first_line(text):
    if not text:
        return None
    for l in text.splitlines():
        s = l.strip()
        if s and not s.startswith("```"):
            return s[:120]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario", choices=["switch", "deps"])
    ap.add_argument("--server", required=True, choices=SERVERS)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--serve-root", default=".")
    ap.add_argument("--from", dest="frm")
    ap.add_argument("--to")
    ap.add_argument("--rev")
    ap.add_argument("--file", required=True)
    ap.add_argument("--line", type=int, required=True)
    ap.add_argument("--col", type=int, required=True)
    ap.add_argument("--expect")
    ap.add_argument("--notify", action="store_true")
    ap.add_argument("--link", action="append")
    ap.add_argument("--python-path")
    a = ap.parse_args()
    spec = SERVERS[a.server]
    serve = os.path.join(a.repo, a.serve_root)
    log = lambda *x: print(*x, flush=True)

    if a.scenario == "deps":
        checkout(a.repo, a.rev)
        make_links(a.repo, a.link)
        t0 = time.perf_counter()
        s = LSP(spec, serve, a.python_path)
        s.initialize()
        s.did_open(a.file)
        # wait for a resolved answer (not Unknown/any) up to 90s; report the last one
        resolved = lambda x: bool(x) and "Unknown" not in x and ": any" not in x
        t, txt = poll(lambda: s.hover_text(a.file, a.line, a.col), resolved, 90)
        log(f"hover after {time.perf_counter()-t0:.2f}s ({'resolved' if t is not None else 'unresolved'}) -> {first_line(txt)!r}")
        defs = s.definition(a.file, a.line, a.col)
        log("definition ->", [d.replace("file://", "") for d in defs][:3] or "none")
        s.shutdown()
        return

    # switch
    checkout(a.repo, a.frm)
    make_links(a.repo, a.link)
    t0 = time.perf_counter()
    s = LSP(spec, serve, a.python_path)
    s.initialize()
    exists_at_from = os.path.exists(os.path.join(serve, a.file))
    if exists_at_from:
        s.did_open(a.file)
        t, txt = poll(lambda: s.hover_text(a.file, a.line, a.col), lambda x: x is not None, 60)
        log(f"warm at FROM: hover after {time.perf_counter()-t0:.2f}s -> {first_line(txt)!r}")
        s.did_close(a.file)
    else:
        time.sleep(5)
        log("warm at FROM: file absent; waited 5s")
    files = [l for l in git(a.repo, "diff", "--name-only", a.frm, a.to).splitlines() if l]
    ct = checkout(a.repo, a.to)
    log(f"checkout {a.frm[:7]} -> {a.to[:7]}: {ct*1000:.0f}ms, {len(files)} files changed")
    t_switch = time.perf_counter()
    if a.notify:
        s.did_change_watched([os.path.relpath(os.path.join(a.repo, f), serve) for f in files])
    pred = lambda x: bool(x) and a.expect in x
    # phase 1: no didOpen -> does the server read the new disk content on its own?
    t, txt = poll(lambda: s.hover_text(a.file, a.line, a.col), pred, 10)
    if t is not None:
        log(f"after switch, file NOT re-opened: correct after {t:.2f}s -> {first_line(txt)!r}")
    else:
        log(f"after switch, file NOT re-opened: not correct within 10s -> {first_line(txt)!r}")
        s.did_open(a.file)
        t, txt = poll(lambda: s.hover_text(a.file, a.line, a.col), pred, 120)
        total = time.perf_counter() - t_switch
        if t is not None:
            log(f"after didOpen with TO bytes: correct after {t:.2f}s (total since checkout {total:.2f}s) -> {first_line(txt)!r}")
        else:
            log(f"after didOpen: still wrong after 120s -> {first_line(txt)!r}")
    s.shutdown()


if __name__ == "__main__":
    main()
