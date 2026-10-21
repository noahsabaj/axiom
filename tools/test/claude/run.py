#!/usr/bin/env python3
"""Axiom's 'ask' end to end: Axiom in QEMU against tools/claudemock.py.

    python tools/test/claude/run.py [--live] [--seed N]

Boots build/esp (build it first) with a network card, types a session of
commands, and checks both sides: what the mock received (each request well
formed, the conversation sent back exactly as it was answered, a fresh one
after 'claude new', the key in its header) and what Axiom printed on its
serial port (each answer whole, as UTF-8; thinking never shown; the key
never; each failure said: an error event, a dropped connection, max_tokens,
400, 401, ctrl+C in the middle of an answer, and a server whose
certificate is not trusted). --live also asks the real api.anthropic.com
with a key that is not one (it must answer 401) and fetches
https://example.com/. Outputs go to build/test/claude/.
"""
import argparse
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / "build" / "test" / "claude"
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "tools" / "test"))
import claudemock  # noqa: E402
from qemu import boot  # noqa: E402

MODEL = "claude-test"
WRONG = "sk-ant-wrong-0123456789abcdef"
FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--port", type=int, default=8444)
    opts = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    mock = claudemock.MockServer(opts.port, seed=opts.seed).start()
    srv = f"https://10.0.2.2:{opts.port}"
    steps = [
        (f"claude server {srv} -k", "NOT checked"),
        (f"claude key {claudemock.KEY}", "key set"),
        (f"claude model {MODEL}", "from the next question"),
        ("ask What is two plus two?", "tokens in"),
        ("ask And three plus three?", "tokens in"),
        ("ask think", "tokens in"),
        ("ask long", "tokens in"),
        ("shot", None),
        ("ask plain", "tokens in"),
        ("ask maxtokens", "tokens in"),
        ("ask overloaded", "API stopped"),
        ("ask cut", "cut short"),
        ("ask badrequest", "API answered"),
        ("ask long", None),
        ("ctrl+C", "http: stopped"),
        ("ask After the stop", "tokens in"),
        (f"claude key {WRONG}", "key set"),
        ("ask hello", "key was refused"),
        ("claude new", "new conversation"),
        (f"claude key {claudemock.KEY}", "key set"),
        ("ask Fresh start", "tokens in"),
        (f"claude server {srv}", "server https"),
        ("ask hello", "cannot prove"),
        ("claude", "message(s)"),
    ]
    if opts.live:
        steps += [
            ("claude server", "server https://api"),
            ("claude key sk-ant-api03-this-is-not-a-real-key-000000", "key set"),
            ("ask hello", "API answered"),
            ("http https://example.com/", "http: HTTP/"),
        ]
    script = []
    for cmd, until in steps:
        if cmd == "shot":
            script.append(f"shot {OUT / 'long.png'}")
            continue
        if cmd == "ctrl+C":                     # in the middle of an answer
            script += ["wait 1.5", "sendkey ctrl-c", f"until {until}"]
            continue
        script.append(f"type {cmd}\\n")
        if until:
            script.append(f"until {until}")
    script.append("type poweroff\\n")
    # once only: the mock remembers every request
    log, err, _ = boot(OUT, "serial", script, "--smp", "2", "--nic", "rtl8139", timeout=60,
                       again=False)
    print(err.strip())
    mock.close()

    # -- what Axiom said
    for _, until in steps:
        if until:
            result(until in log, f"Axiom said '{until}'")
    # the network's own lines (TLS, IPv6 coming up) and start.asm's, at a
    # fixed time after boot, may land inside an answer
    body = "".join(l for l in log.split("\n") if not l.startswith(("https: ", "ip6: ", "start: ")))
    for i, a in enumerate(mock.answers):
        result(a.replace("\n", "") in body, f"answer {i + 1} ({len(a)} characters) "
                                            f"logged whole, as UTF-8")
    result("SECRET" not in log, "the thinking block was not shown")
    result(claudemock.KEY not in log and WRONG not in log, "the key never reached the log")
    for text in ("ask: the API stopped: Overloaded (overloaded_error)",
                 "ask: the answer was cut short",
                 "ask: cut at 4096 tokens",
                 "ask: the API answered 400: mock: asked for a 400 (invalid_request_error)",
                 "ask: the API answered 401: invalid x-api-key (authentication_error)",
                 "https: 10.0.2.2 cannot prove who it is"):
        result(text in log, f"said: {text}")

    # -- what the mock received
    reqs = mock.requests
    result(all(not p for _, _, p, _ in reqs), f"{len(reqs)} requests, all well formed: " +
           "; ".join(str(p) for _, _, p, _ in reqs if p))
    asked = [r for r in reqs if r[1]]
    first = asked[0][1]
    result(first["model"] == MODEL and first["max_tokens"] == 4096 and first["stream"] is True
           and "Axiom" in first["system"] and first["messages"] == [
               {"role": "user", "content": "What is two plus two?"}],
           f"the first request: {first['model']}, {first['max_tokens']} tokens, "
           f"{len(first['messages'])} message(s)")
    second = asked[1][1]["messages"]
    result(len(second) == 3 and second[1]["content"] == mock.answers[0],
           "the second request carries the first answer back exactly")
    counts = [len(r[1]["messages"]) for r in asked]
    print(f"      messages per request: {counts}")
    fresh = [r[1] for r in asked if r[1]["messages"][-1]["content"] == "Fresh start"]
    result(len(fresh) == 1 and len(fresh[0]["messages"]) == 1, "after 'claude new': one message")
    keys = {r[0].get("x-api-key") for r in reqs if r[0].get("host", "").startswith("10.0.2.2")}
    result(keys == {claudemock.KEY, WRONG}, f"the keys sent: {len(keys)}")
    hosts = {r[0].get("host") for r in reqs}
    result(hosts == {f"10.0.2.2:{opts.port}"}, f"Host: {hosts}")
    if opts.live:
        result("invalid x-api-key" in log, "the real API refused the made-up key")
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}; screen: {OUT / 'long.png'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
