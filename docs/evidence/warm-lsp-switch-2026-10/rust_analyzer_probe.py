#!/usr/bin/env python3
"""Minimal rust-analyzer stdio driver for the warm-LSP-across-checkout probe.

Scenarios (all run against a scratch git worktree ROOT that this script
checks out in place):
  cold            start at HEAD, time first hover + quiescent
  switch-rs       start at FROM (rs-only diff), checkout TO, time until hover text flips
  switch-manifest start at FROM (Cargo.toml/lock differ), checkout TO, time until new-file hover works
  stale           didOpen old bytes, checkout TO, show whether hover answers from the stale buffer

Usage: lsp_probe.py ROOT SCENARIO [--notify] [--from SHA] [--to SHA]
"""
import json, os, subprocess, sys, threading, time, queue, argparse

INIT_OPTIONS = {  # mirrors Cairn Safe mode (RustAnalyzerProvider.initializationOptions)
    "procMacro": {"enable": False},
    "checkOnSave": False,
    "cargo": {"buildScripts": {"enable": False}},
}


class RA:
    def __init__(self, root):
        self.root = os.path.realpath(root)
        self.proc = subprocess.Popen(
            ["rust-analyzer"], cwd=self.root, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.next_id = 1
        self.pending = {}
        self.lock = threading.Lock()
        self.quiescent = threading.Event()
        self.quiescent_at = None
        self.started = time.perf_counter()
        threading.Thread(target=self._reader, daemon=True).start()

    # ---- framing -------------------------------------------------------
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
            body = out.read(int(headers["content-length"]))
            self._dispatch(json.loads(body))

    def _dispatch(self, msg):
        if "id" in msg and "method" in msg:  # server → client request
            m = msg["method"]
            if m == "workspace/configuration":
                result = [INIT_OPTIONS for _ in msg["params"]["items"]]
            else:  # window/workDoneProgress/create, client/registerCapability, ...
                result = None
            self._send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
        elif "id" in msg:
            q = self.pending.pop(msg["id"], None)
            if q is not None:
                q.put(msg)
        elif msg.get("method") == "experimental/serverStatus":
            p = msg["params"]
            if p.get("quiescent"):
                if not self.quiescent.is_set():
                    self.quiescent_at = time.perf_counter()
                self.quiescent.set()
            else:
                self.quiescent.clear()

    def request(self, method, params, timeout=120):
        rid = self.next_id
        self.next_id += 1
        q = queue.Queue()
        self.pending[rid] = q
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        msg = q.get(timeout=timeout)
        if "error" in msg:
            return {"__error__": msg["error"]}
        return msg.get("result")

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    # ---- LSP helpers ---------------------------------------------------
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
                "experimental": {"serverStatusNotification": True},
            },
            "initializationOptions": INIT_OPTIONS,
        })
        self.notify("initialized", {})

    def did_open(self, rel, text=None):
        if text is None:
            with open(os.path.join(self.root, rel), encoding="utf-8") as f:
                text = f.read()
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": self.uri(rel), "languageId": "rust", "version": 1, "text": text}})

    def did_close(self, rel):
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
        return str(c)

    def wait_quiescent(self, timeout=180):
        ok = self.quiescent.wait(timeout)
        return (self.quiescent_at - self.started) if ok and self.quiescent_at else None

    def shutdown(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.notify("exit", None)
        except Exception:
            pass
        self.proc.kill()


def git(root, *args):
    return subprocess.run(["git", "-C", root, *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def checkout(root, sha):
    t = time.perf_counter()
    git(root, "checkout", "-q", "--detach", sha)
    return time.perf_counter() - t


def changed_files(root, a, b):
    out = git(root, "diff", "--name-only", a, b)
    return [l for l in out.splitlines() if l]


def poll_hover(ra, rel, line, col, predicate, timeout, every=0.2):
    """Poll until predicate(hover_text) is true; return (seconds, text) or (None, last)."""
    t0 = time.perf_counter()
    last = None
    while time.perf_counter() - t0 < timeout:
        last = ra.hover_text(rel, line, col)
        if predicate(last):
            return time.perf_counter() - t0, last
        time.sleep(every)
    return None, last


def first_line(text):
    if not text:
        return None
    for l in text.splitlines():
        s = l.strip()
        if s and not s.startswith("```"):
            return s
    return None


# Probe targets (toydb). types/mod.rs:57 col 8 is the `'a` of the impl header:
# `impl<'a> Into<Cow<'a, Value>> for Value` at HEAD~5 (hover Self = ...types::Value)
# vs `impl<'a> From<Value> for Cow<'a, Value>` at HEAD (hover Self = ...types::Cow).
# mutation.rs is a HEAD-only file.
TYPES = ("src/sql/types/mod.rs", 57, 8)
AT_HEAD = lambda s: bool(s) and "types::Cow" in s
AT_FROM = lambda s: bool(s) and "types::Value" in s
MUTATION = ("src/sql/execution/mutation.rs", 22, 12)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("scenario", choices=["cold", "switch-rs", "switch-manifest", "stale"])
    ap.add_argument("--notify", action="store_true")
    ap.add_argument("--from", dest="frm")
    ap.add_argument("--to", dest="to")
    a = ap.parse_args()
    root = a.root
    log = lambda *x: print(*x, flush=True)

    if a.scenario == "cold":
        checkout(root, a.to)
        ra = RA(root)
        ra.initialize()
        rel, ln, col = TYPES
        ra.did_open(rel)
        t, txt = poll_hover(ra, rel, ln, col, AT_HEAD, 120)
        log(f"cold: first correct hover after {t:.2f}s -> {first_line(txt)}" if t is not None
            else f"cold: no correct hover within 120s -> {first_line(txt)}")
        q = ra.wait_quiescent()
        log(f"cold: quiescent after {q:.2f}s" if q else "cold: never quiescent")
        ra.shutdown()
        return

    if a.scenario in ("switch-rs", "switch-manifest"):
        checkout(root, a.frm)
        ra = RA(root)
        ra.initialize()
        q = ra.wait_quiescent()
        log(f"warm at FROM: quiescent after {q:.2f}s")
        if a.scenario == "switch-rs":
            rel, ln, col = TYPES
            ra.did_open(rel)  # opened at FROM with FROM bytes
            log("hover at FROM:", first_line(ra.hover_text(rel, ln, col)))
            ra.did_close(rel)  # ensure we test disk propagation, not buffer
            pred = AT_HEAD
        else:
            rel, ln, col = MUTATION
            pred = lambda s: s and "make_row" in s
        files = changed_files(root, a.frm, a.to)
        ct = checkout(root, a.to)
        log(f"checkout {a.frm[:7]} -> {a.to[:7]}: {ct*1000:.0f}ms, {len(files)} files changed")
        t_switch = time.perf_counter()
        if a.notify:
            ra.did_change_watched(files)
        if a.scenario == "switch-manifest":
            ra.did_open(rel)  # new file: open with new bytes
        t, txt = poll_hover(ra, rel, ln, col, pred, 120)
        if t is None:
            log(f"after switch: hover never flipped within 120s; last -> {first_line(txt)}")
        else:
            log(f"after switch: correct hover after {t:.2f}s -> {first_line(txt)}")
        ra.quiescent.clear() if False else None
        # time to quiescent after switch (status may have flipped to non-quiescent)
        q2 = ra.quiescent.wait(120)
        log(f"after switch: quiescent={'yes' if q2 else 'no'} at +{time.perf_counter()-t_switch:.2f}s")
        ra.shutdown()
        return

    if a.scenario == "stale":
        checkout(root, a.frm)
        ra = RA(root)
        ra.initialize()
        ra.wait_quiescent()
        rel, ln, col = TYPES
        ra.did_open(rel)  # FROM bytes stay in the buffer
        log("hover at FROM (buffer open):", first_line(ra.hover_text(rel, ln, col)))
        files = changed_files(root, a.frm, a.to)
        checkout(root, a.to)
        if a.notify:
            ra.did_change_watched(files)
        t, txt = poll_hover(ra, rel, ln, col, AT_HEAD, 8)
        log("after checkout, buffer still open:",
            f"flipped after {t:.2f}s" if t is not None else "still stale after 8s",
            "->", first_line(txt))
        ra.did_close(rel)
        ra.did_open(rel)  # reopen with TO bytes
        t, txt = poll_hover(ra, rel, ln, col, AT_HEAD, 30)
        log("after didClose+didOpen:",
            f"correct after {t:.2f}s" if t is not None else "still wrong after 30s",
            "->", first_line(txt))
        ra.shutdown()


if __name__ == "__main__":
    main()
