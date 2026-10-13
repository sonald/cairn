#!/usr/bin/env python3
"""S0 gate probe: warm language server across an in-place git checkout, driven with
Cairn's exact `initialize` capability set (Sources/CodeInsightExact/LSP.swift:502) and,
optionally, Cairn's sandbox profile and rlimits (Sources/CodeInsightExact/Sandbox.swift).

Scenarios (REPO is a scratch `git clone --local`; this script checks it out in place):

  switch   warm the server at FROM, checkout TO, then time until textDocument/definition
           from FILE:LINE:COL points at EXPECT_FILE[:EXPECT_LINE]. Logs every
           experimental/serverStatus and $/progress notification relative to the checkout
           and reports whether the answer was already correct when each signal arrived.
  cold     checkout TO, start the server, time to the first correct definition.
  longrun  alternate between COMMITS for N iterations; per iteration record time to a
           correct definition, server rss/vsz/cpu time and the exit status (SIGXCPU shows
           up as termination). Meant to run with --sandbox.
  writeprobe  run `/bin/sh -c 'touch PATH'` under the sandbox profile for each PATH and
           report whether the write was denied.

Common options: --server ra|pyright|tsserver --repo DIR [--serve-root REL] [--sandbox]
                [--cache DIR] [--python-path P] [--link SRC:REL ...] [--timeout S]
"""
import argparse
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TSSERVER = "/opt/homebrew/lib/node_modules/typescript/lib/tsserver.js"

# RustAnalyzerProvider.initializationOptions(trustMode: .safe, featureSelection: .defaultFeatures)
RA_INIT = {
    "procMacro": {"enable": False},
    "checkOnSave": False,
    "cargo": {"buildScripts": {"enable": False}},
}
# TypeScriptLanguageServerProvider.initializationOptions(tsserverPath:)
TS_INIT = {
    "disableAutomaticTypingAcquisition": True,
    "plugins": [],
    "tsserver": {"path": TSSERVER, "logVerbosity": "off", "trace": "off",
                 "useSyntaxServer": "never"},
}

SERVERS = {
    "ra": {"helper": "/opt/homebrew/bin/rust-analyzer", "args": [], "init": RA_INIT,
           "lang": lambda p: "rust"},
    "pyright": {"helper": "/opt/homebrew/bin/pyright-langserver", "args": ["--stdio"],
                "init": {}, "lang": lambda p: "python"},
    "tsserver": {"helper": "/opt/homebrew/bin/node",
                 "args": ["/opt/homebrew/bin/typescript-language-server", "--stdio"],
                 "init": TS_INIT,
                 "lang": lambda p: "typescriptreact" if p.endswith(".tsx") else "typescript"},
}

# LSP.swift:502 — the capability set Cairn sends. Keep byte-for-byte equivalent.
CAIRN_CAPABILITIES = {
    "textDocument": {
        "callHierarchy": {},
        "definition": {"linkSupport": True},
        "hover": {"contentFormat": ["markdown", "plaintext"]},
        "implementation": {"linkSupport": True},
        "references": {},
    },
    "window": {"workDoneProgress": True},
    "workspace": {"configuration": True},
    "experimental": {"serverStatusNotification": True},
}

# Sandbox.swift — profile text and rlimit shim, copied verbatim (Safe mode, no `target`).
SANDBOX_EXEC = "/usr/bin/sandbox-exec"
CPU_LIMIT_SECONDS = "60"
ADDRESS_SPACE_KIB = str(512 * 1024 * 1024)
RLIMIT_SCRIPT = 'ulimit -S -t "$1" || exit 125\nulimit -S -v "$2" || exit 125\nshift 2\nexec "$@"'


def sandbox_aliases(path):
    paths = {os.path.normpath(path), os.path.realpath(path)}
    for p in list(paths):
        if p == "/var" or p.startswith("/var/"):
            paths.add("/private" + p)
    return sorted(paths)


def sandbox_profile(project, cache):
    def esc(p):
        return p.replace("\\", "\\\\").replace('"', '\\"')
    writable = [f'(subpath "{esc(p)}")' for p in sandbox_aliases(cache)] + ['(literal "/dev/null")']
    return (
        "(version 1)\n(deny default)\n(import \"system.sb\")\n(allow file-read*)\n"
        "(allow process*)\n(allow file-write*\n  " + "\n  ".join(writable) + ")\n"
        "(deny file-write-create (prefix \"/cores/\"))\n(deny network*)"
    )


def sandboxed_command(project, cache, helper, helper_args):
    os.makedirs(os.path.join(cache, "tmp"), exist_ok=True)
    return [SANDBOX_EXEC, "-p", sandbox_profile(project, cache), "/bin/sh", "-c", RLIMIT_SCRIPT,
            "codeinsight-rlimit", CPU_LIMIT_SECONDS, ADDRESS_SPACE_KIB, helper, *helper_args]


def sandbox_environment(cache):
    os.makedirs(os.path.join(cache, "tmp"), exist_ok=True)
    env = dict(os.environ)
    env["TMPDIR"] = os.path.join(cache, "tmp")
    env["XDG_CACHE_HOME"] = cache
    env["CARGO_NET_OFFLINE"] = "true"
    for key in ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "VIRTUAL_ENV", "CONDA_PREFIX",
                "NODE_PATH", "NODE_OPTIONS"):
        env.pop(key, None)
    env["PYTHONNOUSERSITE"] = "1"
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["PYTHONSAFEPATH"] = "1"
    return env


class Server:
    """stdio LSP client with Cairn's handshake; records serverStatus/$/progress timeline."""

    def __init__(self, spec, root, cache, sandbox, python_path=None, log=print):
        self.spec, self.root, self.cache = spec, os.path.realpath(root), cache
        self.python_path, self.log = python_path, log
        if sandbox:
            cmd = sandboxed_command(self.root, cache, spec["helper"], spec["args"])
        else:
            cmd = [spec["helper"], *spec["args"]]
        self.env = sandbox_environment(cache)
        self.stderr_path = os.path.join(cache, "server.stderr")
        self.stderr = open(self.stderr_path, "ab")
        self.t0 = time.perf_counter()
        self.proc = subprocess.Popen(cmd, cwd=self.root, env=self.env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=self.stderr)
        self.next_id, self.pending, self.lock = 1, {}, threading.Lock()
        self.events = []          # (t, kind, detail)
        self.events_lock = threading.Lock()
        self.quiescent = None     # last experimental/serverStatus quiescent value
        self.progress_open = {}   # token -> title for $/progress begin without end
        self.opened = set()
        self.clock_base = self.t0  # events are reported relative to this
        threading.Thread(target=self._reader, daemon=True).start()

    # ---- transport -------------------------------------------------------------
    def _send(self, msg):
        data = json.dumps(msg).encode()
        with self.lock:
            try:
                self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
                self.proc.stdin.flush()
            except (BrokenPipeError, ValueError):
                self._event("send-failed", f"{msg.get('method')} (server exited status={self.proc.poll()})")

    def exited(self):
        return self.proc.poll() is not None

    def _reader(self):
        out = self.proc.stdout
        while True:
            headers = {}
            while True:
                line = out.readline()
                if not line:
                    self._event("eof", "")
                    return
                if line in (b"\r\n", b"\n"):
                    break
                k, v = line.decode().split(":", 1)
                headers[k.strip().lower()] = v.strip()
            self._dispatch(json.loads(out.read(int(headers["content-length"]))))

    def _event(self, kind, detail):
        with self.events_lock:
            self.events.append((time.perf_counter(), kind, detail))

    def _dispatch(self, msg):
        if "id" in msg and "method" in msg:  # server -> client request (LSP.swift respondToServerRequest)
            m = msg["method"]
            if m == "workspace/configuration":
                items = msg["params"]["items"]
                if self.python_path:  # decision 8 behaviour (not shipped yet): answer pythonPath
                    result = [{"pythonPath": self.python_path} if it.get("section") == "python" else None
                              for it in items]
                else:
                    result = [None for _ in items]
            elif m == "workspace/workspaceFolders":
                result = []
            else:  # client/registerCapability, window/workDoneProgress/create, ...
                result = None
            if m == "window/workDoneProgress/create":
                self._event("progress/create", str(msg["params"].get("token")))
            self._send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
        elif "id" in msg:
            q = self.pending.pop(msg["id"], None)
            if q is not None:
                q.put(msg)
        else:
            m = msg.get("method")
            p = msg.get("params") or {}
            if m == "experimental/serverStatus":
                self.quiescent = bool(p.get("quiescent"))
                self._event("serverStatus", f"quiescent={self.quiescent} health={p.get('health')}"
                            + (f" msg={p.get('message')!r}" if p.get("message") else ""))
            elif m == "$/progress":
                token, value = p.get("token"), p.get("value") or {}
                kind = value.get("kind")
                if kind == "begin":
                    self.progress_open[token] = value.get("title")
                elif kind == "end":
                    self.progress_open.pop(token, None)
                if kind in ("begin", "end"):
                    self._event(f"progress/{kind}", f"{token}: {value.get('title') or value.get('message') or ''}")
            elif m in ("window/logMessage", "window/showMessage"):
                self._event("log", str(p.get("message"))[:120])

    def request(self, method, params, timeout=120):
        rid = self.next_id
        self.next_id += 1
        q = queue.Queue()
        self.pending[rid] = q
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.perf_counter() + timeout
        while True:
            try:
                msg = q.get(timeout=0.5)
                break
            except queue.Empty:
                if self.exited():
                    self.pending.pop(rid, None)
                    return {"__error__": {"code": "exited", "message": f"server exited status={self.proc.returncode}"}}
                if time.perf_counter() > deadline:
                    self.pending.pop(rid, None)
                    return {"__error__": {"code": "timeout", "message": method}}
        return {"__error__": msg["error"]} if "error" in msg else msg.get("result")

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    # ---- LSP helpers ------------------------------------------------------------
    def uri(self, rel):
        return "file://" + os.path.join(self.root, rel)

    def initialize(self):
        r = self.request("initialize", {
            "processId": None,
            "clientInfo": {"name": "CodeInsight", "version": "4"},
            "rootUri": "file://" + self.root,
            "workspaceFolders": [{"uri": "file://" + self.root, "name": os.path.basename(self.root)}],
            "capabilities": CAIRN_CAPABILITIES,
            "initializationOptions": self.spec["init"],
            "trace": "off",
        })
        self.notify("initialized", {})
        return r

    def did_open(self, rel):
        with open(os.path.join(self.root, rel), encoding="utf-8") as f:
            text = f.read()
        self.opened.add(rel)
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": self.uri(rel), "languageId": self.spec["lang"](rel), "version": 1, "text": text}})

    def did_close_all(self):
        for rel in list(self.opened):
            self.notify("textDocument/didClose", {"textDocument": {"uri": self.uri(rel)}})
        self.opened.clear()

    def did_change_watched(self, changes):
        """changes: [(abs_path, type)] with type 1 created / 2 changed / 3 deleted."""
        self.notify("workspace/didChangeWatchedFiles", {
            "changes": [{"uri": "file://" + p, "type": t} for p, t in changes]})

    def definition(self, rel, line1, col1):
        """-> list of (path, line1) targets, or None on error/empty."""
        r = self.request("textDocument/definition", {
            "textDocument": {"uri": self.uri(rel)},
            "position": {"line": line1 - 1, "character": col1 - 1}})
        if r is None or r == [] or (isinstance(r, dict) and "__error__" in r):
            return None if not (isinstance(r, dict) and "__error__" in r) else ("error", r["__error__"])
        items = r if isinstance(r, list) else [r]
        out = []
        for it in items:
            uri = it.get("targetUri") or it.get("uri")
            rng = it.get("targetSelectionRange") or it.get("targetRange") or it.get("range") or {}
            out.append((uri.replace("file://", "", 1) if uri else None, rng.get("start", {}).get("line", -1) + 1))
        return out

    def hover_text(self, rel, line1, col1):
        r = self.request("textDocument/hover", {
            "textDocument": {"uri": self.uri(rel)},
            "position": {"line": line1 - 1, "character": col1 - 1}})
        if not r or (isinstance(r, dict) and "__error__" in r):
            return None
        c = r.get("contents")
        if isinstance(c, dict):
            return c.get("value")
        if isinstance(c, list):
            return "\n".join(x if isinstance(x, str) else x.get("value", "") for x in c)
        return str(c)

    def ps(self):
        out = subprocess.run(["ps", "-o", "rss=,vsz=,time=", "-p", str(self.proc.pid)],
                             capture_output=True, text=True).stdout.split()
        if len(out) < 3:
            return None
        return {"rss_mib": round(int(out[0]) / 1024, 1), "vsz_gib": round(int(out[1]) / 1024 / 1024, 2),
                "cpu": out[2]}

    def events_since(self, t_ref):
        with self.events_lock:
            return [(round(t - t_ref, 3), k, d) for t, k, d in self.events if t >= t_ref - 0.0005]

    def wait_idle(self, server, timeout):
        """Server-specific 'ready' wait used before the switch: RA quiescent; others progress closed
        for 1.5 s (or just 1.5 s of silence if no progress ever arrives)."""
        t0 = time.perf_counter()
        if server == "ra":
            while time.perf_counter() - t0 < timeout and not self.exited():
                if self.quiescent:
                    return time.perf_counter() - t0
                time.sleep(0.02)
            return None
        last = time.perf_counter()
        while time.perf_counter() - t0 < timeout and not self.exited():
            with self.events_lock:
                n = len(self.events)
            if self.progress_open:
                last = time.perf_counter()
            elif time.perf_counter() - last > 1.5:
                return time.perf_counter() - t0
            time.sleep(0.05)
        return None

    def shutdown(self):
        try:
            self.request("shutdown", None, timeout=10)
            self.notify("exit", None)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
        self.stderr.close()
        return self.proc.returncode


# ---- git helpers ---------------------------------------------------------------------
def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], check=True, capture_output=True, text=True).stdout


def checkout(repo, rev):
    t = time.perf_counter()
    git(repo, "checkout", "-q", "--detach", "--force", rev)
    return time.perf_counter() - t


def watched_changes(repo, frm, to):
    out = []
    for line in git(repo, "diff", "--name-status", frm, to).splitlines():
        if not line:
            continue
        status, _, path = line.partition("\t")
        if status.startswith("R"):
            old, _, new = path.partition("\t")
            out.append((os.path.join(repo, old), 3))
            out.append((os.path.join(repo, new), 1))
            continue
        kind = {"A": 1, "M": 2, "D": 3}.get(status[0], 2)
        out.append((os.path.join(repo, path), kind))
    return out


def make_links(repo, links):
    for spec in links or []:
        src, rel = spec.split(":", 1)
        dst = os.path.join(repo, rel)
        if os.path.lexists(dst):
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.symlink(os.path.realpath(src), dst)


# ---- scenarios --------------------------------------------------------------------------
def matches(result, expect_file, expect_line):
    if expect_file == "":  # warm-up: any non-error answer (including empty) counts
        return result is None or result[0] != "error"
    if not result or result[0] == "error":
        return False
    for path, line in result:
        if path and expect_file in path and (expect_line is None or line == expect_line):
            return True
    return False


def describe(result):
    if result is None:
        return "empty"
    if result[0] == "error":
        return f"error {result[1]}"
    return ", ".join(f"{os.path.basename(p) if p else p}:{l}" for p, l in result[:3])


def poll_definition(server, a, timeout, every, on_signal=None):
    """Poll until the definition matches; returns (t_first_correct|None, history)."""
    t0 = time.perf_counter()
    history = []
    seen_events = len(server.events)
    while True:
        r = server.definition(a.file, a.line, a.col)
        now = time.perf_counter()
        ok = matches(r, a.expect_file, a.expect_line)
        with server.events_lock:
            new = server.events[seen_events:]
            seen_events = len(server.events)
        history.append((now, ok, describe(r), [(k, d) for _, k, d in new]))
        if ok:
            return now, history
        if now - t0 > timeout or server.exited():
            return None, history
        time.sleep(every)


def report_signals(server, t_ref, t_notify, t_correct, history, log):
    """Print the signal timeline relative to checkout end, and whether the answer at each
    signal's arrival was already correct."""
    log("  signals (s after checkout; notify sent at %+.3f):" % (t_notify - t_ref))
    for t, kind, detail in server.events_since(t_ref):
        if kind == "eof":
            continue
        abs_t = t_ref + t
        # answer state at that moment = latest poll completed before the signal
        state = None
        for hist_t, ok, desc, _ in history:
            if hist_t <= abs_t:
                state = (ok, desc)
        after = None
        for hist_t, ok, desc, _ in history:
            if hist_t > abs_t:
                after = (ok, desc)
                break
        log(f"    +{t:7.3f} {kind:16} {detail[:90]}"
            f"  | answer before: {state[1] if state else 'n/a'}  after: {after[1] if after else 'n/a'}")
    if t_correct is not None:
        log("  first correct cross-file answer: +%.3f s after checkout" % (t_correct - t_ref))
    log_history(history, t_ref, log)


def log_history(history, t_ref, log):
    """Compact poll history: one line per run of identical answers."""
    log("  poll answers (s after reference; each line = run of identical answers):")
    runs = []
    for t, ok, desc, _ in history:
        if runs and runs[-1][2] == desc:
            runs[-1][1] = t
            runs[-1][3] += 1
        else:
            runs.append([t, t, desc, 1])
    for first, last, desc, n in runs:
        log(f"    +{first - t_ref:7.3f} .. +{last - t_ref:7.3f} ({n:3d}x) {desc[:100]}")


def scenario_switch(a, spec, log):
    repo = a.repo
    checkout(repo, a.frm)
    make_links(repo, a.link)
    serve = os.path.join(repo, a.serve_root)
    s = Server(spec, serve, a.cache, a.sandbox, a.python_path, log)
    s.initialize()
    log(f"pid={s.proc.pid} sandbox={a.sandbox} server={a.server} root={serve}")
    warm_file = a.warm_file or a.file
    if os.path.exists(os.path.join(serve, warm_file)):
        s.did_open(warm_file)
        wl, wc = (a.warm_line or a.line), (a.warm_col or a.col)
        t, h = poll_definition(s, argparse.Namespace(file=warm_file, line=wl, col=wc,
                                                    expect_file="", expect_line=None), 60, 0.2)
        log(f"warm at FROM {a.frm[:7]}: definition at {warm_file}:{wl}:{wc} -> {h[-1][2]} after {time.perf_counter()-s.t0:.2f}s")
    idle = s.wait_idle(a.server, 180)
    log(f"warm at FROM: idle after {idle if idle is None else round(idle, 2)}s (serverStatus quiescent={s.quiescent}) ps={s.ps()}")
    log("  warm-phase signals (s after server start):")
    for t, kind, detail in s.events_since(s.t0):
        if kind != "eof":
            log(f"    +{t:7.3f} {kind:16} {detail[:110]}")
    changes = watched_changes(repo, a.frm, a.to)
    # decision 5 order: didClose all -> checkout -> didChangeWatchedFiles -> wait for confirmation
    s.did_close_all()
    ct = checkout(repo, a.to)
    t_ref = time.perf_counter()
    s.clock_base = t_ref
    log(f"checkout {a.frm[:7]} -> {a.to[:7]}: {ct*1000:.0f} ms, {len(changes)} watched changes "
        f"(A={sum(t==1 for _,t in changes)} M={sum(t==2 for _,t in changes)} D={sum(t==3 for _,t in changes)})")
    if not a.no_notify:
        s.did_change_watched(changes)
    t_notify = time.perf_counter()
    if not a.no_reopen:
        s.did_open(a.file)
    t_correct, history = poll_definition(s, a, a.timeout, 0.1)
    log(f"after switch: {'correct after %.3f s' % (t_correct - t_ref) if t_correct else 'NOT correct within %ss' % a.timeout}"
        f" -> {history[-1][2]}  (polls={len(history)})")
    # keep listening a little for the trailing signals
    time.sleep(a.settle)
    report_signals(s, t_ref, t_notify, t_correct, history, log)
    log(f"ps after switch: {s.ps()}")
    rc = s.shutdown()
    log(f"exit status={rc}  (SIGXCPU shows as -24 here; a shell would report 152)")


def scenario_cold(a, spec, log):
    repo = a.repo
    checkout(repo, a.to)
    make_links(repo, a.link)
    serve = os.path.join(repo, a.serve_root)
    s = Server(spec, serve, a.cache, a.sandbox, a.python_path, log)
    t_ref = s.t0
    s.initialize()
    s.did_open(a.file)
    t_correct, history = poll_definition(s, a, a.timeout, 0.1)
    log(f"cold at {a.to[:7]}: {'correct after %.3f s' % (t_correct - t_ref) if t_correct else 'NOT correct within %ss' % a.timeout}"
        f" -> {history[-1][2]}")
    idle = s.wait_idle(a.server, 180)
    log(f"cold: idle after {idle if idle is None else round(idle, 2)}s more; ps={s.ps()}")
    for t, kind, detail in s.events_since(t_ref):
        if kind not in ("eof", "log"):
            log(f"    +{t:7.3f} {kind:16} {detail[:90]}")
    log_history(history, t_ref, log)
    rc = s.shutdown()
    log(f"exit status={rc}")


def scenario_longrun(a, spec, log):
    repo = a.repo
    commits = a.commits
    checkout(repo, commits[0])
    make_links(repo, a.link)
    serve = os.path.join(repo, a.serve_root)
    s = Server(spec, serve, a.cache, a.sandbox, a.python_path, log)
    s.initialize()
    log(f"pid={s.proc.pid} sandbox={a.sandbox} cmdline-check: {' '.join(subprocess.run(['ps','-o','args=','-p',str(s.proc.pid)],capture_output=True,text=True).stdout.split()[:1])}")
    s.did_open(a.file)
    t, h = poll_definition(s, a, a.timeout, 0.2)
    log(f"iter 0 cold at {commits[0][:7]}: {'correct after %.2fs' % (t - s.t0) if t else 'NOT correct'} ps={s.ps()}")
    idle = s.wait_idle(a.server, 180)
    log(f"iter 0 idle after {idle}s ps={s.ps()}")
    prev = commits[0]
    for i in range(1, a.iterations + 1):
        nxt = commits[i % len(commits)]
        changes = watched_changes(repo, prev, nxt)
        s.did_close_all()
        ct = checkout(repo, nxt)
        t_ref = time.perf_counter()
        s.did_change_watched(changes)
        s.did_open(a.file)
        t, h = poll_definition(s, a, a.timeout, 0.1)
        if s.proc.poll() is not None:
            log(f"iter {i}: server exited status={s.proc.returncode} (SIGXCPU is -24 / 152)")
            break
        idle = s.wait_idle(a.server, 120)
        log(f"iter {i} {prev[:7]}->{nxt[:7]} checkout={ct*1000:.0f}ms changes={len(changes)} "
            f"correct={'+%.2fs' % (t - t_ref) if t else 'NO (%s)' % h[-1][2]} idle=+{(time.perf_counter()-t_ref):.2f}s ps={s.ps()}")
        prev = nxt
    rc = s.shutdown()
    log(f"final exit status={rc}; stderr tail: {open(s.stderr_path,'rb').read()[-400:]!r}")


def scenario_writeprobe(a, spec, log):
    serve = os.path.join(a.repo, a.serve_root)
    for path in a.paths:
        cmd = sandboxed_command(os.path.realpath(serve), a.cache, "/bin/sh",
                                ["-c", 'printf probe > "$1"', "probe", path])
        r = subprocess.run(cmd, cwd=serve, env=sandbox_environment(a.cache), capture_output=True, text=True)
        exists = os.path.exists(path)
        if exists:
            os.remove(path)
        log(f"write {path}: status={r.returncode} created={exists} stderr={r.stderr.strip()[:120]!r}"
            f" -> {'ALLOWED' if exists else 'denied'}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenario", choices=["switch", "cold", "longrun", "writeprobe"])
    ap.add_argument("--server", required=True, choices=SERVERS)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--serve-root", default=".")
    ap.add_argument("--sandbox", action="store_true")
    ap.add_argument("--cache")
    ap.add_argument("--python-path")
    ap.add_argument("--link", action="append")
    ap.add_argument("--from", dest="frm")
    ap.add_argument("--to")
    ap.add_argument("--commits", nargs="+")
    ap.add_argument("--iterations", type=int, default=20)
    ap.add_argument("--file")
    ap.add_argument("--line", type=int)
    ap.add_argument("--col", type=int)
    ap.add_argument("--warm-file")
    ap.add_argument("--warm-line", type=int)
    ap.add_argument("--warm-col", type=int)
    ap.add_argument("--expect-file", default="")
    ap.add_argument("--expect-line", type=int)
    ap.add_argument("--no-notify", action="store_true")
    ap.add_argument("--no-reopen", action="store_true")
    ap.add_argument("--timeout", type=float, default=120)
    ap.add_argument("--settle", type=float, default=3.0)
    ap.add_argument("--paths", nargs="*", default=[])
    a = ap.parse_args()
    a.repo = os.path.realpath(a.repo)
    if not a.cache:
        a.cache = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"s0cache-{a.server}-{os.getpid()}")
    os.makedirs(a.cache, exist_ok=True)
    spec = SERVERS[a.server]
    started = time.strftime("%Y-%m-%d %H:%M:%S")

    def log(*x):
        print(*x, flush=True)

    log(f"# {started} {a.scenario} server={a.server} repo={a.repo} serve_root={a.serve_root} sandbox={a.sandbox}")
    {"switch": scenario_switch, "cold": scenario_cold, "longrun": scenario_longrun,
     "writeprobe": scenario_writeprobe}[a.scenario](a, spec, log)


if __name__ == "__main__":
    main()
