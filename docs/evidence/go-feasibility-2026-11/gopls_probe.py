#!/usr/bin/env python3
"""gopls long-session probe inside Cairn's Safe-mode sandbox rules.

Mirrors LSPClient.initialize (capabilities, null processId), LSPClient's answers
to server requests (configuration -> null per item, registerCapability /
workDoneProgress/create -> null) and LSPLanguageSession.switchSnapshot's order:
didClose opened docs -> checkout -> didChangeWatchedFiles -> didOpen + request.

  gopls_probe.py cold   --root R --cache C --modcache M
  gopls_probe.py switch --repo R --cache C --modcache M --from A --to B
  gopls_probe.py scale  --root R --cache C --modcache M --file F --pattern P
"""
import argparse, json, os, re, shutil, subprocess, sys, threading, time

GOPLS = shutil.which("gopls")


def sandbox_cmd(cache):
    profile = (
        '(version 1)(deny default)(import "system.sb")(allow file-read*)(allow process*)'
        f'(allow file-write* (subpath "{cache}") (literal "/dev/null"))'
        '(deny file-write-create (prefix "/cores/"))(deny network*)'
    )
    return ["/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c",
            'ulimit -S -v "$1" || exit 125; shift; exec "$@"', "codeinsight-rlimit",
            str(512 * 1024 * 1024), GOPLS, "serve"]


class LSP:
    def __init__(self, root, cache, modcache):
        self.root = os.path.realpath(root)
        cache = os.path.realpath(cache)
        os.makedirs(os.path.join(cache, "tmp"), exist_ok=True)
        env = dict(os.environ)
        env.update(TMPDIR=os.path.join(cache, "tmp"), XDG_CACHE_HOME=cache,
                   GOCACHE=os.path.join(cache, "go-build"),
                   GOPLSCACHE=os.path.join(cache, "gopls"),
                   GOTOOLCHAIN="local", GOPROXY="off", GOMODCACHE=os.path.realpath(modcache))
        env.pop("GOFLAGS", None)
        self.t0 = time.time()
        self.proc = subprocess.Popen(sandbox_cmd(cache), cwd=self.root, env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE)
        self.next_id, self.pending, self.lock = 1, {}, threading.Lock()
        self.opened, self.events = {}, []
        self.server_requests, self.notifications = {}, {}
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._stderr, daemon=True).start()

    def now(self):
        return time.time() - self.t0

    def _stderr(self):
        for line in self.proc.stderr:
            self.events.append((self.now(), "stderr", line.decode(errors="replace").strip()[:300]))

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
            method = msg["method"]
            self.server_requests[method] = self.server_requests.get(method, 0) + 1
            result = None
            if method == "workspace/configuration":
                items = (msg.get("params") or {}).get("items") or []
                self.events.append((self.now(), "config-request",
                                    ",".join(str(i.get("section")) for i in items)))
                result = [None for _ in items]
            elif method == "workspace/workspaceFolders":
                result = []
            self._send({"jsonrpc": "2.0", "id": msg["id"], "result": result})
        elif "id" in msg:
            waiter = self.pending.pop(msg["id"], None)
            if waiter:
                waiter["msg"] = msg
                waiter["event"].set()
        else:
            method, params = msg["method"], msg.get("params") or {}
            self.notifications[method] = self.notifications.get(method, 0) + 1
            if method == "$/progress":
                value = params.get("value") or {}
                self.events.append((self.now(), "progress",
                                    f"{value.get('kind')} {value.get('title') or ''} {value.get('message') or ''}".strip()))
            elif method in ("window/showMessage", "window/logMessage"):
                self.events.append((self.now(), method.split("/")[1],
                                    f"type={params.get('type')} {str(params.get('message'))[:400]}"))
            elif method == "textDocument/publishDiagnostics":
                for d in params.get("diagnostics") or []:
                    self.events.append((self.now(), "diagnostic",
                                        f"{os.path.relpath(params['uri'][7:], self.root)}:{d['range']['start']['line'] + 1} {d.get('source')} {d['message'][:240]}"))

    def request(self, method, params, timeout=120):
        with self.lock:
            rid = self.next_id
            self.next_id += 1
        waiter = {"event": threading.Event()}
        self.pending[rid] = waiter
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        if not waiter["event"].wait(timeout):
            raise TimeoutError(f"{method} timed out after {timeout}s")
        msg = waiter["msg"]
        if "error" in msg:
            raise RuntimeError(f"{method}: {msg['error']}")
        return msg.get("result")

    def notify(self, method, params):
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def uri(self, rel):
        return "file://" + os.path.join(self.root, rel)

    def initialize(self):
        root_uri = "file://" + self.root
        result = self.request("initialize", {
            "processId": None,
            "clientInfo": {"name": "CodeInsight", "version": "4"},
            "rootUri": root_uri,
            "workspaceFolders": [{"uri": root_uri, "name": os.path.basename(self.root)}],
            "capabilities": {
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
            },
            "initializationOptions": {},
            "trace": "off",
        })
        self.notify("initialized", {})
        return result

    def open(self, rel):
        with open(os.path.join(self.root, rel), encoding="utf-8") as f:
            text = f.read()
        version = self.opened.get(rel, 0) + 1
        self.opened[rel] = version
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": self.uri(rel), "languageId": "go", "version": version, "text": text}})

    def close_all(self):
        for rel in list(self.opened):
            self.notify("textDocument/didClose", {"textDocument": {"uri": self.uri(rel)}})
        self.opened.clear()

    def at(self, rel, pattern, group=1):
        """(line, character) of regex group `group` at its first match in rel."""
        with open(os.path.join(self.root, rel), encoding="utf-8") as f:
            text = f.read()
        m = re.search(pattern, text)
        if not m:
            raise LookupError(f"{pattern!r} not in {rel}")
        offset = m.start(group)
        line = text.count("\n", 0, offset)
        return line, offset - (text.rfind("\n", 0, offset) + 1)

    def position(self, rel, pattern, group=1):
        if rel not in self.opened:
            self.open(rel)
        line, character = self.at(rel, pattern, group)
        return {"textDocument": {"uri": self.uri(rel)},
                "position": {"line": line, "character": character}}

    def rss_mb(self):
        out = subprocess.run(["ps", "-o", "rss=,comm=", "-p", str(self.proc.pid)],
                             capture_output=True, text=True).stdout.split(None, 1)
        return (int(out[0]) / 1024, out[1].strip()) if out else (0, "?")

    def shutdown(self):
        try:
            self.request("shutdown", None, timeout=5)
            self.notify("exit", None)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def locations(lsp, result):
    out = []
    for loc in result or []:
        uri = loc.get("targetUri") or loc.get("uri")
        rng = loc.get("targetSelectionRange") or loc.get("range")
        path = uri[7:]
        rel = os.path.relpath(path, lsp.root) if path.startswith(lsp.root + "/") else path
        out.append(f"{rel}:{rng['start']['line'] + 1}")
    return out


def timed(label, fn):
    t = time.time()
    try:
        value = fn()
        print(f"  {label}: {value}  [{time.time() - t:.2f}s]")
        return value
    except Exception as error:  # noqa: BLE001
        print(f"  {label}: ERROR {error}  [{time.time() - t:.2f}s]")
        return None


def dump(lsp, kinds=("progress", "showMessage", "config-request", "diagnostic", "stderr"), limit=14):
    print(f"  server->client requests: {lsp.server_requests}")
    print(f"  notifications: {lsp.notifications}")
    shown = [e for e in lsp.events if e[1] in kinds]
    for t, kind, text in shown[:limit]:
        print(f"    {t:6.2f}s {kind}: {text}")
    if len(shown) > limit:
        print(f"    ... {len(shown) - limit} more")


def cobra_queries(lsp):
    """In-project, cross-file and dependency answers on a cobra checkout."""
    expected_def = lsp.at("args.go", r"func (legacyArgs)\(")[0] + 1
    expected_ref = lsp.at("command.go", r"(legacyArgs)\(commandFound")[0] + 1
    with open(os.path.join(lsp.root, "go.mod")) as f:
        pflag = re.search(r"github.com/spf13/pflag (v\S+)", f.read()).group(1)
    results = {}
    # Asked first, while args.go is not open: its line moves between commits,
    # so a right answer means the server re-read the unopened file from disk.
    expected_moved = lsp.at("args.go", r"func (ArbitraryArgs)\(")[0] + 1
    moved = timed(f"definition command.go ArbitraryArgs -> unopened args.go:{expected_moved}",
                  lambda: locations(lsp, lsp.request("textDocument/definition",
                                                     lsp.position("command.go", r"return (ArbitraryArgs)\(c, args\)"))))
    results["unopened-moved"] = moved == [f"args.go:{expected_moved}"]
    d = timed("definition command.go legacyArgs -> args.go",
              lambda: locations(lsp, lsp.request("textDocument/definition",
                                                 lsp.position("command.go", r"(legacyArgs)\(commandFound"))))
    results["definition"] = d == [f"args.go:{expected_def}"]
    r = timed("references args.go legacyArgs (non-test)",
              lambda: [x for x in locations(lsp, lsp.request("textDocument/references", {
                  **lsp.position("args.go", r"func (legacyArgs)\("),
                  "context": {"includeDeclaration": False}})) if "_test" not in x])
    results["references"] = r == [f"command.go:{expected_ref}"]
    dep = timed("definition command.go flag.FlagSet -> pflag",
                lambda: locations(lsp, lsp.request("textDocument/definition",
                                                   lsp.position("command.go", r"flags \*flag\.(FlagSet)"))))
    results["dependency"] = bool(dep) and f"pflag@{pflag}/" in dep[0]
    print(f"  expected: definition args.go:{expected_def}, references command.go:{expected_ref}, pflag@{pflag}")
    return results


def cmd_cold(args):
    lsp = LSP(args.root, args.cache, args.modcache)
    t = time.time()
    result = lsp.initialize()
    caps = result.get("capabilities", {})
    print(f"initialize {time.time() - t:.2f}s; serverInfo={result.get('serverInfo')}")
    print("  providers:", sorted(k for k, v in caps.items() if k.endswith("Provider") and v))
    print("requests sent immediately after `initialized` (workspace still loading):")
    results = cobra_queries(lsp)
    print(f"  first answers done at {lsp.now():.2f}s after spawn")
    timed("hover ExecuteC", lambda: (lsp.request("textDocument/hover", lsp.position(
        "command.go", r"func \(c \*Command\) (ExecuteC)\(")) or {}).get("contents", {}).get("value", "")[:90].replace("\n", " | "))
    timed("typeDefinition c.flags", lambda: locations(lsp, lsp.request(
        "textDocument/typeDefinition", lsp.position("command.go", r"c\.(flags) = flag\.NewFlagSet"))))
    timed("implementation SliceValue", lambda: locations(lsp, lsp.request(
        "textDocument/implementation", lsp.position("completions.go", r"type (SliceValue) interface")))[:4])
    items = timed("prepareCallHierarchy legacyArgs", lambda: lsp.request(
        "textDocument/prepareCallHierarchy", lsp.position("args.go", r"func (legacyArgs)\(")))
    if items:
        timed("incomingCalls", lambda: [f"{c['from']['name']}@{os.path.basename(c['from']['uri'])}"
                                        for c in lsp.request("callHierarchy/incomingCalls", {"item": items[0]})])
    th = timed("prepareTypeHierarchy SliceValue", lambda: lsp.request(
        "textDocument/prepareTypeHierarchy", lsp.position("completions.go", r"type (SliceValue) interface")))
    if th:
        timed("typeHierarchy/subtypes", lambda: [
            f"{t['name']}@{os.path.basename(t['uri'])}"
            for t in lsp.request("typeHierarchy/subtypes", {"item": th[0]}) or []][:6])
    time.sleep(1.0)
    print(f"  rss={lsp.rss_mb()}")
    dump(lsp)
    print("  RESULT", results)
    lsp.shutdown()


def checkout(repo, rev):
    subprocess.run(["git", "-C", repo, "checkout", "-q", "--detach", rev], check=True)


def cmd_switch(args):
    repo = os.path.realpath(args.repo)
    checkout(repo, args.frm)
    lsp = LSP(repo, args.cache, args.modcache)
    lsp.initialize()
    print(f"cold at {args.frm}:")
    before = cobra_queries(lsp)
    t_cold = lsp.now()
    print(f"  cold ready {t_cold:.2f}s; RESULT {before}")
    for target in [args.to, args.frm, args.to]:
        head = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        changed = subprocess.run(["git", "-C", repo, "diff", "--name-status", head, target],
                                 capture_output=True, text=True, check=True).stdout.split("\n")
        changes = []
        for line in changed:
            if not line:
                continue
            status, path = line.split("\t")[0], line.split("\t")[-1]
            kind = {"A": 1, "D": 3}.get(status[0], 2)
            changes.append({"uri": "file://" + os.path.join(repo, path), "type": kind})
        events_before = len(lsp.events)
        t = time.time()
        lsp.close_all()
        checkout(repo, target)
        lsp.notify("workspace/didChangeWatchedFiles", {"changes": changes})
        go_mod = any(c["uri"].endswith(("go.mod", "go.sum")) for c in changes)
        print(f"switch -> {target} ({len(changes)} files, go.mod/go.sum changed={go_mod}); requests sent at once:")
        after = cobra_queries(lsp)
        print(f"  all three correct={all(after.values())} {after}  total {time.time() - t:.2f}s")
        for when, kind, text in lsp.events[events_before:][:6]:
            if kind in ("progress", "showMessage", "stderr"):
                print(f"    {when:6.2f}s {kind}: {text}")
    print(f"  rss={lsp.rss_mb()}  pid alive={lsp.proc.poll() is None}")
    print(f"  server->client requests: {lsp.server_requests}")
    lsp.shutdown()


def cmd_scale(args):
    lsp = LSP(args.root, args.cache, args.modcache)
    lsp.initialize()
    peak = [0.0]

    def sample():
        while lsp.proc.poll() is None:
            peak[0] = max(peak[0], lsp.rss_mb()[0])
            time.sleep(0.5)
    threading.Thread(target=sample, daemon=True).start()
    timed("first definition", lambda: locations(lsp, lsp.request(
        "textDocument/definition", lsp.position(args.file, args.pattern), timeout=600)))
    print(f"  first answer at {lsp.now():.2f}s after spawn")
    timed("references (same symbol)", lambda: len(lsp.request("textDocument/references", {
        **lsp.position(args.file, args.pattern), "context": {"includeDeclaration": False}}, timeout=600) or []))
    timed("second definition", lambda: locations(lsp, lsp.request(
        "textDocument/definition", lsp.position(args.file, args.pattern))))
    time.sleep(2)
    print(f"  rss now={lsp.rss_mb()} peak={peak[0]:.0f} MB")
    dump(lsp, limit=8)
    lsp.shutdown()


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("cold", "switch", "scale"):
        p = sub.add_parser(name)
        p.add_argument("--cache", required=True)
        p.add_argument("--modcache", required=True)
        if name == "switch":
            p.add_argument("--repo", required=True)
            p.add_argument("--from", dest="frm", required=True)
            p.add_argument("--to", required=True)
        else:
            p.add_argument("--root", required=True)
        if name == "scale":
            p.add_argument("--file", required=True)
            p.add_argument("--pattern", required=True)
    args = parser.parse_args()
    {"cold": cmd_cold, "switch": cmd_switch, "scale": cmd_scale}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
