#!/usr/bin/env python3
"""LSP benchmark driver for the Julia LanguageServer.

Spawns the LS the same way the VS Code extension does, drives it over stdio,
and records a timestamped event log plus derived metrics:
  - spawn -> initialize response
  - initialized -> first publishDiagnostics / bootstrap end
  - progress phase timelines (index/download/...)
  - dispatch-loop responsiveness probes during startup
  - warm request latencies (hover/completion/definition/documentSymbol/...)
  - didChange -> publish latency, typing-burst behavior
"""
import argparse, json, os, subprocess, sys, threading, time, queue, shutil, urllib.parse

REPO = "/home/pfitzseb/git/julia-vscode"
LSDIR = os.path.join(REPO, "scripts", "languageserver")
JULIA = "/home/pfitzseb/.juliaup/bin/julia"
FAKEHOME = "/home/pfitzseb/.cache/claude-lsbench/fakehome"
DEPOT = "/home/pfitzseb/.cache/claude-lsbench/depot"

def path2uri(p):
    return "file://" + urllib.parse.quote(p, safe="/")

class LSClient:
    def __init__(self, proc, log_path):
        self.proc = proc
        self.t0 = time.monotonic()
        self.lock = threading.Lock()
        self.next_id = 1
        self.pending = {}  # id -> (event, holder)
        self.events = []
        self.evlock = threading.Lock()
        self.log = open(log_path, "w")
        self.notif_q = queue.Queue()
        self.diag_versions = {}   # uri -> list of (t, count)
        self.progress = {}        # token -> dict(title, begun, ended, reports)
        self.token_titles = {}
        self.first_publish = None
        self.last_publish = None
        self.publish_count = 0
        self.config = {}
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def now(self):
        return time.monotonic() - self.t0

    def record(self, kind, **kw):
        ev = {"t": round(self.now(), 4), "kind": kind}
        ev.update(kw)
        with self.evlock:
            self.events.append(ev)
            self.log.write(json.dumps(ev) + "\n")
            self.log.flush()
        return ev

    def _read_loop(self):
        f = self.proc.stdout
        while True:
            # headers
            headers = {}
            line = f.readline()
            if not line:
                self.record("eof")
                return
            while line not in (b"\r\n", b"\n", b""):
                k, _, v = line.decode("ascii", "replace").partition(":")
                headers[k.strip().lower()] = v.strip()
                line = f.readline()
            n = int(headers.get("content-length", 0))
            body = f.read(n)
            try:
                msg = json.loads(body)
            except Exception:
                self.record("badjson", size=n)
                continue
            self._handle(msg)

    def _handle(self, msg):
        t = self.now()
        if "id" in msg and "method" in msg:
            # server -> client request
            self.record("srv_request", method=msg["method"], id=msg["id"])
            self._answer_server_request(msg)
        elif "method" in msg:
            m = msg["method"]
            p = msg.get("params", {})
            if m == "textDocument/publishDiagnostics":
                uri = p.get("uri")
                cnt = len(p.get("diagnostics", []))
                self.publish_count += 1
                if self.first_publish is None:
                    self.first_publish = t
                self.last_publish = t
                self.diag_versions.setdefault(uri, []).append((t, cnt))
                self.record("publishDiagnostics", uri=uri, count=cnt)
            elif m == "textDocument/publishTests":
                self.record("publishTests", uri=p.get("uri"),
                            count=len(p.get("testitems", [])))
            elif m == "$/progress":
                token = p.get("token")
                v = p.get("value", {})
                kindv = v.get("kind")
                self.record("progress", token=token, pkind=kindv,
                            message=v.get("message"), pct=v.get("percentage"),
                            title=v.get("title"))
                st = self.progress.setdefault(token, {"begun": None, "ended": None, "reports": []})
                if kindv == "begin":
                    st["begun"] = t
                    st["title"] = v.get("message")
                elif kindv == "end":
                    st["ended"] = t
                    st["endmsg"] = v.get("message")
                else:
                    st["reports"].append((t, v.get("message"), v.get("percentage")))
            elif m == "telemetry/event":
                pass  # too chatty to log individually
            elif m == "window/logMessage" or m == "window/showMessage":
                self.record("logMessage", message=str(p.get("message"))[:200])
            else:
                self.record("notification", method=m)
            self.notif_q.put((t, msg))
        else:
            # response
            rid = msg.get("id")
            with self.lock:
                ent = self.pending.pop(rid, None)
            if ent is not None:
                ev, holder, meta = ent
                holder["response"] = msg
                holder["t_recv"] = t
                self.record("response", id=rid, method=meta,
                            ms=round((t - holder["t_sent"]) * 1000, 2),
                            error=("error" in msg))
                ev.set()

    def _answer_server_request(self, msg):
        m = msg["method"]
        result = None
        if m == "workspace/configuration":
            items = msg["params"]["items"]
            result = [self.config.get(i.get("section"), None) for i in items]
        elif m == "window/workDoneProgress/create":
            result = None
        elif m in ("client/registerCapability", "client/unregisterCapability"):
            result = None
        elif m == "workspace/diagnostic/refresh":
            result = None
        self._send({"jsonrpc": "2.0", "id": msg["id"], "result": result})

    def _send(self, obj):
        body = json.dumps(obj).encode()
        data = b"Content-Length: %d\r\n\r\n" % len(body) + body
        with self.lock:
            self.proc.stdin.write(data)
            self.proc.stdin.flush()

    def notify(self, method, params):
        self.record("send_notification", method=method)
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def request_async(self, method, params):
        with self.lock:
            rid = self.next_id
            self.next_id += 1
        ev = threading.Event()
        holder = {"t_sent": self.now()}
        with self.lock:
            self.pending[rid] = (ev, holder, method)
        self.record("send_request", method=method, id=rid)
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return ev, holder

    def request(self, method, params, timeout=600):
        ev, holder = self.request_async(method, params)
        if not ev.wait(timeout):
            raise TimeoutError(f"no response to {method} within {timeout}s")
        return holder


def client_capabilities():
    return {
        "workspace": {
            "workspaceFolders": True,
            "configuration": True,
            "didChangeConfiguration": {"dynamicRegistration": True},
            "didChangeWatchedFiles": {"dynamicRegistration": True, "relativePatternSupport": True},
            # no diagnostics.refreshSupport -> push model
        },
        "window": {"workDoneProgress": True},
        "textDocument": {
            "publishDiagnostics": {"relatedInformation": True},
            "hover": {"contentFormat": ["markdown", "plaintext"]},
            "completion": {"completionItem": {"snippetSupport": False}},
            "rename": {"prepareSupport": True},
            # no "diagnostic" -> no pull diagnostics
        },
    }


def spawn(store_path, stderr_path):
    env = {
        "HOME": FAKEHOME,
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "JULIA_LANGUAGESERVER": "1",
        "JULIA_VSCODE_LANGUAGESERVER": "1",
        "JULIA_VSCODE_INTERNAL": "1",
    }
    args = [
        JULIA, "+1.12",
        "--startup-file=no", "--history-file=no", "--depwarn=no",
        "main.jl",
        os.path.join(DEPOT, "environments", "v1.12"),   # ARGS[1] env path
        "--debug=no",                                    # ARGS[2]
        "/tmp/nonexistent-crash-pipe",                   # ARGS[3]
        store_path,                                      # ARGS[4] storage
        "--detached=no",                                 # ARGS[5]
        JULIA,                                           # ARGS[6]
        "1.12.6",                                        # ARGS[7]
    ]
    stderr_f = open(stderr_path, "wb")
    proc = subprocess.Popen(args, cwd=LSDIR, env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=stderr_f)
    return proc


def pos_of(text, needle, offset=0):
    """(line, character) of needle in text (utf-16-naive: ascii assumed)."""
    idx = text.index(needle) + offset
    line = text.count("\n", 0, idx)
    col = idx - (text.rfind("\n", 0, idx) + 1)
    return {"line": line, "character": col}


def wait_settled(c, quiet_secs, timeout, probe_uri=None, label=""):
    """Wait until no progress notifications or publishes for quiet_secs and
    all begun progress bars have ended."""
    t_start = c.now()
    while True:
        now = c.now()
        if now - t_start > timeout:
            c.record("settle_timeout", label=label)
            return False
        last_act = max([c.last_publish or 0] +
                       [st["begun"] or 0 for st in c.progress.values()] +
                       [st["ended"] or 0 for st in c.progress.values()] +
                       [r[0] for st in c.progress.values() for r in st["reports"][-1:]])
        open_bars = [t for t, st in c.progress.items() if st["begun"] and not st["ended"]]
        if not open_bars and now - last_act > quiet_secs and last_act > 0:
            c.record("settled", label=label, last_activity=round(last_act, 3))
            return True
        time.sleep(0.25)


def probe_loop(c, uri, stop_ev, results, interval=0.5):
    while not stop_ev.is_set():
        t_sent = c.now()
        try:
            h = c.request("textDocument/documentSymbol",
                          {"textDocument": {"uri": uri}}, timeout=900)
            results.append((t_sent, (h["t_recv"] - h["t_sent"]) * 1000))
        except TimeoutError:
            results.append((t_sent, None))
            return
        stop_ev.wait(interval)


def run(args):
    store = args.store
    os.makedirs(store, exist_ok=True)
    outdir = args.outdir
    os.makedirs(outdir, exist_ok=True)
    stderr_path = os.path.join(outdir, "ls-stderr.log")
    log_path = os.path.join(outdir, "events.jsonl")

    t_spawn_wall = time.time()
    proc = spawn(store, stderr_path)
    c = LSClient(proc, log_path)
    c.config = {
        "julia.completionmode": "qualify",
        "julia.inlayHints.static.enabled": True,
        "julia.inlayHints.static.variableTypes.enabled": True,
        "julia.inlayHints.static.parameterNames.enabled": "literals",
        "julia.symbolCacheDownload": args.download,
        "julia.symbolserverUpstream": "https://julia-symbolcache.org",
        "julia.enableDynamicIndexing": args.dynamic,
        "julia.maxConcurrentIndexingProcesses": 4,
        "julia.enableWorkspaceEnvironmentResolution": args.env_resolution,
    }

    summary = {"label": args.label, "config": dict(c.config), "wall_start": t_spawn_wall}

    # --- initialize ---
    h = c.request("initialize", {
        "processId": os.getpid(),
        "clientInfo": {"name": "lsbench", "version": "1.0"},
        "rootUri": path2uri(REPO),
        "workspaceFolders": [{"uri": path2uri(REPO), "name": "julia-vscode"}],
        "capabilities": client_capabilities(),
        "initializationOptions": {"julialangTestItemIdentification": True},
        "trace": "off",
    }, timeout=600)
    summary["t_initialize_response"] = h["t_recv"]

    # target file for probes + runtime suite
    target_rel = "scripts/packages/JuliaWorkspaces/src/layer_diagnostics.jl"
    target_path = os.path.join(REPO, target_rel)
    target_uri = path2uri(target_path)
    text = open(target_path).read()

    c.notify("initialized", {})
    t_initialized = c.now()
    summary["t_initialized_sent"] = t_initialized

    c.notify("textDocument/didOpen", {"textDocument": {
        "uri": target_uri, "languageId": "julia", "version": 1, "text": text}})

    # responsiveness probes during startup
    probes = []
    stop_probes = threading.Event()
    pt = threading.Thread(target=probe_loop, args=(c, target_uri, stop_probes, probes), daemon=True)
    pt.start()

    # wait for startup to settle
    settled = wait_settled(c, quiet_secs=8.0, timeout=args.settle_timeout, label="startup")
    summary["startup_settled"] = settled
    summary["t_settled"] = c.now()
    summary["t_first_publish"] = c.first_publish
    summary["t_last_publish_startup"] = c.last_publish
    summary["publish_count_startup"] = c.publish_count
    summary["startup_probes"] = [(round(t, 3), round(ms, 1) if ms else None) for t, ms in probes]

    stop_probes.set()
    time.sleep(0.1)

    # progress phase summary
    phases = []
    for token, st in c.progress.items():
        phases.append({
            "title": st.get("title"), "begun": st["begun"], "ended": st["ended"],
            "endmsg": st.get("endmsg"),
            "n_reports": len(st["reports"]),
            "last_report": st["reports"][-1][1] if st["reports"] else None,
        })
    summary["progress_phases"] = phases

    if args.runtime_suite:
        rt = {}
        version = [1]

        def did_change(edits):
            version[0] += 1
            c.notify("textDocument/didChange", {
                "textDocument": {"uri": target_uri, "version": version[0]},
                "contentChanges": edits,
            })

        def timed(name, method, params, n=20, timeout=300):
            lat = []
            for i in range(n):
                h = c.request(method, params, timeout=timeout)
                lat.append((h["t_recv"] - h["t_sent"]) * 1000)
            lat.sort()
            rt[name] = {
                "n": n, "min": round(lat[0], 2),
                "p50": round(lat[n // 2], 2), "p90": round(lat[int(n * 0.9) - 1], 2),
                "max": round(lat[-1], 2),
            }
            c.record("timed_done", name=name, **rt[name])

        hover_pos = pos_of(text, 'startswith(d.message, "Missing', 3)
        def_pos = pos_of(text, "is_path_lintconfig_file(uri2filepath", 3)
        ref_pos = pos_of(text, "function _is_env_dependent_diagnostic", len("function ") + 3)
        # first-request-after-startup (cold-ish JIT/salsa state)
        h = c.request("textDocument/hover",
                      {"textDocument": {"uri": target_uri}, "position": hover_pos})
        rt["hover_first"] = round((h["t_recv"] - h["t_sent"]) * 1000, 2)

        timed("hover", "textDocument/hover",
              {"textDocument": {"uri": target_uri}, "position": hover_pos})
        timed("documentSymbol", "textDocument/documentSymbol",
              {"textDocument": {"uri": target_uri}})
        timed("definition", "textDocument/definition",
              {"textDocument": {"uri": target_uri}, "position": def_pos})
        compl_pos = pos_of(text, "StaticLint.LintCodeDescriptions[StaticLint.IncorrectCallArgs",
                           len("StaticLint.LintCode"))
        timed("completion", "textDocument/completion",
              {"textDocument": {"uri": target_uri}, "position": compl_pos,
               "context": {"triggerKind": 1}}, n=20)
        timed("workspace_symbol", "workspace/symbol", {"query": "diagnostic"}, n=10)
        timed("getModuleAt", "julia/getModuleAt",
              {"textDocument": {"uri": target_uri}, "version": version[0],
               "position": hover_pos})

        # references: cold then warm
        h = c.request("textDocument/references",
                      {"textDocument": {"uri": target_uri}, "position": ref_pos,
                       "context": {"includeDeclaration": True}}, timeout=600)
        rt["references_first"] = round((h["t_recv"] - h["t_sent"]) * 1000, 2)
        timed("references", "textDocument/references",
              {"textDocument": {"uri": target_uri}, "position": ref_pos,
               "context": {"includeDeclaration": True}}, n=10)

        # --- didChange -> publish latency (syntax error toggle) ---
        insert_pos = pos_of(text, "function _lint_options_from_config", 0)
        line = insert_pos["line"]
        toggles = []
        for i in range(10):
            n_before = len(c.diag_versions.get(target_uri, []))
            t_sent = c.now()
            did_change([{"range": {"start": {"line": line, "character": 0},
                                   "end": {"line": line, "character": 0}},
                         "text": "1 ] )\n"}])
            # wait for a publish for this uri
            deadline = time.monotonic() + 30
            while len(c.diag_versions.get(target_uri, [])) == n_before and time.monotonic() < deadline:
                time.sleep(0.002)
            pubs = c.diag_versions.get(target_uri, [])
            toggles.append(round((pubs[-1][0] - t_sent) * 1000, 2) if len(pubs) > n_before else None)
            # revert
            n_before = len(pubs)
            t_sent = c.now()
            did_change([{"range": {"start": {"line": line, "character": 0},
                                   "end": {"line": line + 1, "character": 0}},
                         "text": ""}])
            deadline = time.monotonic() + 30
            while len(c.diag_versions.get(target_uri, [])) == n_before and time.monotonic() < deadline:
                time.sleep(0.002)
            pubs = c.diag_versions.get(target_uri, [])
            toggles.append(round((pubs[-1][0] - t_sent) * 1000, 2) if len(pubs) > n_before else None)
            time.sleep(0.6)  # let debounced sweep drain between toggles
        rt["didchange_publish_ms"] = toggles

        # --- typing burst: 30 keystrokes at 33 ms inside a comment ---
        cpos = pos_of(text, "# StaticLint diagnostics that depend", 2)
        # burst probes
        bprobes = []
        bstop = threading.Event()
        bt = threading.Thread(target=probe_loop, args=(c, target_uri, bstop, bprobes, 0.2), daemon=True)
        bt.start()
        t_burst0 = c.now()
        ch = cpos["character"]
        for i in range(30):
            did_change([{"range": {"start": {"line": cpos["line"], "character": ch},
                                   "end": {"line": cpos["line"], "character": ch}},
                         "text": "x"}])
            ch += 1
            time.sleep(0.033)
        t_burst_end = c.now()
        # delete the inserted chars again
        did_change([{"range": {"start": {"line": cpos["line"], "character": cpos["character"]},
                               "end": {"line": cpos["line"], "character": ch}},
                     "text": ""}])
        time.sleep(4.0)
        bstop.set()
        rt["burst"] = {
            "duration_s": round(t_burst_end - t_burst0, 3),
            "probes_ms": [(round(t - t_burst0, 3), round(ms, 1) if ms else None) for t, ms in bprobes],
            "publishes_during": len([1 for (t, n) in c.diag_versions.get(target_uri, []) if t >= t_burst0]),
        }

        # restore original content and close
        did_change([{"text": text}])
        time.sleep(1)
        c.notify("textDocument/didClose", {"textDocument": {"uri": target_uri}})
        summary["runtime"] = rt

    # memory of the LS process tree
    try:
        rss = subprocess.run(["ps", "-o", "rss=", "-p", str(proc.pid)],
                             capture_output=True, text=True).stdout.strip()
        summary["ls_rss_mb"] = round(int(rss) / 1024, 1)
        kids = subprocess.run(["ps", "--ppid", str(proc.pid), "-o", "rss="],
                              capture_output=True, text=True).stdout.split()
        summary["children_rss_mb"] = [round(int(k) / 1024, 1) for k in kids]
    except Exception as e:
        summary["rss_error"] = str(e)

    # shutdown
    try:
        c.request("shutdown", None, timeout=30)
        c.notify("exit", {})
    except Exception:
        pass
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()

    summary["t_end"] = c.now()
    with open(os.path.join(outdir, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
    print(json.dumps({k: v for k, v in summary.items()
                      if k not in ("startup_probes",)}, indent=2))
    return summary


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", required=True)
    ap.add_argument("--store", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--dynamic", action="store_true", default=False)
    ap.add_argument("--download", action="store_true", default=False)
    ap.add_argument("--env-resolution", action="store_true", default=False)
    ap.add_argument("--runtime-suite", action="store_true", default=False)
    ap.add_argument("--settle-timeout", type=float, default=1800)
    args = ap.parse_args()
    run(args)
