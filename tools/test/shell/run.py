#!/usr/bin/env python3
"""Axiom's shell in QEMU: things and actions, records, stages, the line.

    python tools/test/shell/run.py

Boots build/esp from a USB stick that also holds notes.txt, types commands
down the serial port, an 'echo' after each so its output can be told from
the next one's, and checks what each printed:
  - help: every command, a thing's actions, a command that is not there;
    no Linux names ('ls' is not a command);
  - files: a folder, a pattern, a file shown; go and here; on the stick,
    once 'vol 0 rw' allows it (and refused before), new, write, copy,
    move, remove, with patterns and into folders;
  - stages: where (each kind of field, its errors), sort, pick, first,
    last, count, to text, to json; a stage alone, an unknown one, one after
    'to'; '>' and '>>' into files;
  - the line: quotes, $names (set, removed, ${name}, \\$), ';', '&&', '||',
    a quote not closed, '&' (not yet);
  - what prints, piped as lines ('echo hi | count'); cpus, mem, threads,
    tasks as records, and 'tasks stop' refusing the kernel's own task;
  - programs by name, case aside, and by path; each given only what its
    header wants, and what +net, +store, +desk grant for one run; '&' runs
    one in the background, ctrl+C stops only the one in front, 'tasks stop'
    takes a name; a program's exit code is what && and || see;
  - afterwards, the stick's FAT is checked from here: no damage, and the
    files the shell wrote hold what they should.
Outputs go to build/test/shell/.
"""
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
sys.path.insert(0, str(ROOT / "tools"))
from qemu import boot_all  # noqa: E402
import fat32  # noqa: E402

OUT = ROOT / "build" / "test" / "shell"
FAILS = 0
NOTES = "first line\nsecond line, café\nthird line\n"
PROGRAMS = {p.name: p.stat().st_size for p in sorted((ROOT / "build" / "esp" / "EFI" /
                                                      "AXIOM").iterdir())}
NL = "\\n"
SEMI = "\\x3b"                                  # run.py splits its script at ';'


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def table(lines):
    """A table's lines -> [{column: cell}], from its header."""
    lines = [l.strip() for l in lines if l.strip()]
    if not lines:
        return []
    head = re.split(r" {2,}", lines[0])
    return [dict(zip(head, re.split(r" {2,}", l))) for l in lines[1:]]


def record(lines):
    """One record's lines ('  field  value') -> {field: value}."""
    out = {}
    for l in lines:
        m = re.match(r"^ +(\S+) {2,}(.*)$", l)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def said(text):
    return lambda lines: any(text in l for l in lines)


def size_of(n):
    """A size as Axiom's %b shows it (one decimal, cut short)."""
    for unit, shift in (("GiB", 30), ("MiB", 20), ("KiB", 10)):
        if n >= 1 << shift:
            tenths = n * 10 >> shift
            return f"{tenths // 10}.{tenths % 10} {unit}"
    return f"{n} B"


BIG = sorted(PROGRAMS, key=lambda n: -PROGRAMS[n])
OVER_10K = [n for n in PROGRAMS if PROGRAMS[n] > 10 << 10]
OVER_8K = [n for n in PROGRAMS if PROGRAMS[n] >= 8 << 10]

# (what is typed, what it must print, what that shows); a check takes the
# lines it printed
STEPS = [
    ("help", lambda l: {"files", "go", "here", "set", "cpus", "mem", "threads", "tasks",
                        "poweroff"} <= {r.get("command") for r in table(l)}
     and not {"ls", "cd", "cat", "cp", "rm", "mkdir", "write"} & {r.get("command")
                                                                  for r in table(l)},
     "help: every command, the new things among them, no Linux names"),
    ("help files", lambda l: [r["use"].split()[1] if len(r["use"].split()) > 1 and
                              not r["use"].split()[1].startswith(("[", "<")) else ""
                              for r in table(l)] ==
     ["", "show", "copy", "move", "new", "write", "remove", "find"],
     "help files: its actions, the default first"),
    ("help nonsense", said("no command 'nonsense': 'help' lists them"),
     "help nonsense: there is no such command"),
    ("ls", said("unknown command 'ls' - try 'help'"), "'ls' is not an Axiom command"),
    ("files", lambda l: {("EFI", "folder"), ("notes.txt", "file")} <=
     {(r.get("name"), r.get("kind")) for r in table(l)},
     "files: the stick's top folder, EFI and notes.txt"),
    ("files /EFI/AXIOM", lambda l: {r["name"]: r["size"] for r in table(l)} ==
     {n: size_of(s) for n, s in PROGRAMS.items()},
     "files /EFI/AXIOM: every program, its size"),
    ("files show notes.txt", lambda l: [x for x in l if x.strip()][0] == "first line"
     and l[1].startswith("second line, caf") and l[2] == "third line",
     "files show notes.txt: its lines"),
    ("files /EFI/AXIOM | sort size down | first 3",
     lambda l: [r["name"] for r in table(l)] == BIG[:3],
     "sort size down | first 3: the three biggest programs"),
    ("files /EFI/AXIOM | sort size | last 1 | pick name",
     lambda l: [r["name"] for r in table(l)] == BIG[:1] and list(table(l)[0]) == ["name"],
     "sort size | last 1 | pick name: the biggest, its name alone"),
    ("files /EFI/AXIOM | where size > 10K | pick name size",
     lambda l: sorted(r["name"] for r in table(l)) == sorted(OVER_10K)
     and list(table(l)[0]) == ["name", "size"],
     "where size > 10K | pick name size: the programs over 10 KiB"),
    ("files /EFI/AXIOM | where size >= 8K | count",
     lambda l: l == [str(len(OVER_8K))], "where size >= 8K | count"),
    ("files /EFI/AXIOM | count", lambda l: l == [str(len(PROGRAMS))], "count: every program"),
    ("files /EFI/AXIOM/*.AXE | to json",
     lambda l: {o["name"]: (o["kind"], o["size"]) for o in json.loads("\n".join(l))} ==
     {n: ("file", s) for n, s in PROGRAMS.items()},
     "a pattern | to json: sizes in bytes, as the files have"),
    ("files find *.AXE", lambda l: sorted(r["path"] for r in table(l)) ==
     sorted(f"EFI/AXIOM/{n}" for n in PROGRAMS), "files find *.AXE: each with its path"),
    ("files show notes.txt | where text ~ *second* | count", lambda l: l == ["1"],
     "files show | where text ~ ...: a file's lines are records too"),
    ("here", lambda l: l == ["vol0:/"], "here: vol0:/"),
    ("go /EFI", lambda l: l == [], "go /EFI"),
    ("here", lambda l: l == ["vol0:/EFI"], "here: vol0:/EFI"),
    ("files", lambda l: [r["name"] for r in table(l)] == ["AXIOM", "BOOT"],
     "files there: AXIOM and BOOT"),
    ("go ..", lambda l: l == [], "go .."),
    ("here", lambda l: l == ["vol0:/"], "here: back at vol0:/"),
    ("go /nope", said("nothing called 'nope' there"), "go /nope: not there"),
    ("files new old/", said("vol0 is read-only ('vol 0 rw' allows writes)"),
     "files new, read-only: refused"),
    ("files > early.txt", said("vol0 is read-only"), "> file, read-only: refused"),
    ("vol 0 rw", said("vol0 is writable"), "vol 0 rw"),
    ("files new old/", lambda l: l == ["made old/"], "files new old/: a folder"),
    ("files new old/", said("old/ is there already"), "files new old/ again: there already"),
    ("files write a.txt hello   there", lambda l: l == ["wrote 12 bytes to a.txt"],
     "files write: the words and a newline"),
    ("files show a.txt", lambda l: l == ["hello there"], "files show a.txt"),
    ("files copy a.txt b.txt", lambda l: l == ["copied a.txt to b.txt (12 B)"],
     "files copy a.txt b.txt"),
    ("files copy a.txt a.txt", said("a.txt and a.txt are the same file"),
     "files copy onto itself: refused"),
    ("files move b.txt old/", lambda l: l == ["moved b.txt to old/b.txt (12 B)"],
     "files move b.txt old/: into the folder"),
    ("files copy a.txt notes.txt old", lambda l: re.fullmatch(
        r"copied 2 of 2 \(\d+ B\) to old", l[0] if l else "") is not None,
     "files copy, two into a folder"),
    ("files old | sort name", lambda l: [r["name"] for r in table(l)] ==
     ["a.txt", "b.txt", "notes.txt"], "files old | sort name: all three"),
    ("files remove old", said("that folder is not empty"), "files remove, a full folder: no"),
    ("files remove old/*.txt", lambda l: l == ["removed 3 of 3"], "files remove a pattern"),
    ("files remove old", lambda l: l == ["removed old"], "files remove, the folder emptied"),
    ("files old", said("nothing called 'old' there"), "the folder is gone"),
    ("files /EFI/AXIOM | to text > list.txt", lambda l: re.fullmatch(
        r"wrote \d+ B to list\.txt", l[0] if l else "") is not None, "> list.txt"),
    ("cpus | count >> list.txt", lambda l: l == ["added 2 B to list.txt"], ">> list.txt"),
    ("files /EFI/AXIOM | first 2 | to json > list.json", said("to list.json"),
     "to json > list.json"),
    ("files show list.txt", lambda l: l[0].split() == ["name", "kind", "size", "changed"]
     and len(l) == len(PROGRAMS) + 2 and l[-1] == "4",
     "the file holds the table as text, then the count added"),
    ("files | where name ~ *.txt | sort name", lambda l: [r["name"] for r in table(l)] ==
     ["a.txt", "list.txt", "notes.txt"], "where name ~ *.txt | sort name"),
    ("files | where size > lots", said("where: size takes a size (4K, 2M, 1.5G); 'lots' "
                                       "is not one"), "where: a size that is not one"),
    ("files | where size about 5", said("where: 'about' is not a comparison"),
     "where: a comparison that is not one"),
    ("files | sort nosuch", said("no field 'nosuch' here; the fields are: name, kind, size, "
                                 "changed"), "sort nosuch: the fields there are"),
    ("files | bogus", said("'bogus' is not a stage"), "an unknown stage"),
    ("where x = 1", said("'where' is a stage: it comes after a |"), "a stage alone"),
    ("files | to json | count", said("'to' comes last"), "nothing after 'to'"),
    ("| count", said("a | or a > needs a command before it"), "a | with nothing before"),
    ("files >", said("> and >> take one file, and come last"), "> with no file"),
    ("set greeting hi there", lambda l: l == [], "set greeting hi there"),
    ("set", lambda l: {"greeting": "hi there"}.items() <=
     {r["name"]: r["value"] for r in table(l)}.items(), "set: the variables"),
    ("echo $greeting and \"$greeting!\" and '$greeting' and \\\\$greeting and ${greeting}s",
     lambda l: l == ["hi there and hi there! and $greeting and $greeting and hi theres"],
     "$name, in double quotes, not in single ones, \\$, ${name}"),
    ("echo [$nothing] $nothing x", lambda l: l == ["[] x"],
     "a name not set is empty, and an empty word goes"),
    ("set greeting", lambda l: l == [], "set greeting: removed"),
    ("echo [$greeting]", lambda l: l == ["[]"], "it is gone"),
    ("echo \"a | b > c\"", lambda l: l == ["a | b > c"], "| and > in quotes are words"),
    ("echo a\\\\nb \\\\$x \\\\\\\\ c\\\\ d\\\\|e", lambda l: l == ["a\\nb $x \\ c d|e"],
     "\\ takes what the shell would read as it is, and stays before anything else"),
    (f"echo one {SEMI} echo two", lambda l: l == ["one", "two"], "';' runs one, then the next"),
    ("echo ok && echo and-ran", lambda l: l == ["ok", "and-ran"], "&& after a success"),
    ("nonsense && echo not-run", lambda l: not any("not-run" in x for x in l) and
     said("unknown command 'nonsense'")(l), "&& after a failure: not run"),
    ("nonsense || echo or-ran", lambda l: l[-1:] == ["or-ran"], "|| after a failure"),
    ("echo ok || echo not-run", lambda l: l == ["ok"], "|| after a success: not run"),
    ("echo \"open", said("a quote is not closed"), "a quote not closed"),
    ("uptime &", said("'&' is for programs; 'uptime' is a command"),
     "& after a command that prints: no"),
    ("echo hi | count", lambda l: l[-1:] == ["1"], "what prints, piped: its lines"),
    ("cpus | count", lambda l: l == ["4"], "cpus | count: 4"),
    ("cpus | pick cpu kind | to json", lambda l: len(json.loads("\n".join(l))) == 4 and
     set(json.loads("\n".join(l))[0]) == {"cpu", "kind"}, "cpus | pick | to json"),
    ("mem | pick usable free", lambda l: set(record(l)) == {"usable", "free"},
     "mem | pick usable free: one record, two fields"),
    ("mem kinds | where kind = conventional | count", lambda l: l == ["1"],
     "mem kinds | where kind = conventional"),
    ("threads | where name = main | pick name state", lambda l: [r["name"] for r in
                                                                  table(l)] == ["main"],
     "threads | where name = main"),
    ("threads cpus | count", lambda l: l == ["4"], "threads cpus | count: 4"),
    ("tasks", lambda l: any(r.get("name") == "kernel" and r.get("program") == "no"
                            for r in table(l)), "tasks: the kernel's own"),
    ("tasks stop 1", said("is the kernel's own, not a program"),
     "tasks stop: not the kernel's"),
    ("tasks stop 99999", said("tasks: there is no task 99999"), "tasks stop: no such task"),
    ("help mem", lambda l: [r["use"].split()[1] if len(r["use"].split()) > 1 and
                            not r["use"].split()[1].startswith(("[", "<")) else ""
                            for r in table(l)] == ["", "kinds", "at", "test"],
     "help mem: its actions"),
    ("files remove a.txt list.json", lambda l: l == ["removed 2 of 2"], "files remove two"),
]

# programs: each typed with the mark on the same line (after ';'), which
# runs once the program has ended, or with ctrl+C sent first
LINE, CTRL_C = "line", "ctrl+c"
PROGRAMS_STEPS = [
    ("hello one two", lambda l: "Hello from ring 3!" in l and "hello: arguments: one two" in l
     and "hello: given: nothing" in l and "run: HELLO exited with 0" in l,
     "a program by its name; it gets only what it wants: nothing", LINE),
    ("+net +desk hello", said("hello: given: net desk"), "+net +desk: granted, for that run",
     LINE),
    ("hello", said("hello: given: nothing"), "and only for that run", LINE),
    ("HELLO", said("run: HELLO exited with 0"), "its name in any case", LINE),
    ("/EFI/AXIOM/HELLO.AXE by path", said("hello: arguments: by path"), "a program by its path",
     LINE),
    ("run hello via run", said("hello: arguments: via run"), "run <program>, as its name", LINE),
    ("+bogus hello", said("'+bogus' is not something a program can be given; there are +net, "
                          "+store and +desk"), "+bogus: not a capability"),
    ("+net files", said("+net, +store and +desk are for programs; 'files' is a command"),
     "+net before a command: no"),
    ("+net", said("+net, +store and +desk come before a program's name"), "+net alone: no"),
    ("files &", said("'&' is for programs; 'files' is a command"), "& after a command: no"),
    ("hello | count &", said("a program in the background has no | or > after it"),
     "& after a pipeline: no"),
    ("fault && echo not-after-fault", lambda l: said("run: FAULT exited with 1")(l) and
     not said("not-after-fault")(l), "&& after a program that failed: not run", LINE),
    ("fault || echo after-fault", said("after-fault"), "|| after a program that failed", LINE),
    ("hello && echo after-hello", lambda l: l[-1:] == ["after-hello"],
     "&& after a program that worked, once it ended", LINE),
    ("spin &", lambda l: any(re.fullmatch(r"run: SPIN in the background, task \d+ \('tasks "
                                          r"stop \d+' stops it\)", x) for x in l),
     "spin &: in the background, the prompt back at once"),
    ("spin 2 wait &", said("run: SPIN in the background"), "and another"),
    ("tasks | where name = SPIN | count", lambda l: l == ["2"], "tasks: both running"),
    ("user", said("running: SPIN, SPIN"), "user: both running"),
    ("spin 3", lambda l: sum("run: SPIN stopped" in x for x in l) == 1,
     "ctrl+C stops the program in front", CTRL_C),
    ("tasks | where name = SPIN | count", lambda l: l == ["2"],
     "and not those in the background"),
    ("tasks stop spin", lambda l: sum(bool(re.fullmatch(r"tasks: \d+ \(SPIN\) stopped", x))
                                      for x in l) == 2, "tasks stop spin: each of that name"),
    ("tasks | where name = SPIN | count",       # their ends may be said meanwhile
     lambda l: [x for x in l if x != "run: SPIN stopped"] == ["0"], "none left"),
    ("tasks stop spin", said("tasks: no program called spin is running"),
     "tasks stop spin again: none"),
    ("user", said("running: none"), "user: nothing running"),
]


def jobs():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "notes.txt").write_bytes(NOTES.encode())
    stick = OUT / "stick.img"
    subprocess.run([sys.executable, str(ROOT / "tools" / "mkstick.py"), str(stick),
                    "--file", f"notes.txt={OUT / 'notes.txt'}"],
                   cwd=ROOT, check=True, capture_output=True)
    script = ["until log: kept in", "wait 0.5", f"type echo mark''-1{NL}", "until mark-1"]
    for i, (typed, _, _, *how) in enumerate(STEPS + PROGRAMS_STEPS):
        if how == [LINE]:
            script += [f"type {typed} {SEMI} echo mark''{i}{NL}", f"until mark{i}"]
            continue
        script += [f"type {typed}{NL}"]
        if how == [CTRL_C]:
            script += ["wait 1.5", "sendkey ctrl-c", "until stopped", "wait 0.3"]
        script += [f"type echo mark''{i}{NL}", f"until mark{i}"]
        if typed.startswith("tasks stop"):
            script += ["wait 0.5"]                      # their ends said, after
    script += [f"type poweroff{NL}", "ended"]
    return {"shell": (script, ["--smp", "4", "--stick", stick.relative_to(ROOT).as_posix()],
                      60)}


def outputs(log):
    """{n: the lines step n printed}, between the marks."""
    out, lines, at = {}, [], None
    for line in log.splitlines():
        m = re.fullmatch(r"mark(-?\d+)", line)
        if m:
            if at is not None:
                out[int(m.group(1))] = lines
            at, lines = int(m.group(1)), []
        elif at is not None:
            lines.append(line)
    return out


def stick():
    print("-- the stick afterwards")
    img = bytearray((OUT / "stick.img").read_bytes())
    _, first, last, _ = fat32.read_gpt(img)[0]
    fs = fat32.Fat32(img, first, last - first + 1).mount()
    files, problems = fat32.check(fs)
    result(not problems, "the FAT is whole" + (f": {problems}" if problems else ""))
    text = (files.get("/list.txt") or b"").decode("latin-1").splitlines()
    rows = table(text[:-1])
    result([r.get("name") for r in rows] == list(PROGRAMS) and text[-1:] == ["4"],
           "list.txt: the programs' table, then the count")
    result("/a.txt" not in files and "/old" not in files and "/list.json" not in files,
           "what was removed is gone")
    result(files.get("/notes.txt") == NOTES.encode(), "notes.txt is as it was")


def main():
    logs = boot_all(OUT, jobs())
    log, err = logs["shell"]
    got = outputs(log)
    print("-- the shell")
    for i, (typed, check, what, *_) in enumerate(STEPS + PROGRAMS_STEPS):
        lines = got.get(i)
        try:
            ok = lines is not None and bool(check(lines))
        except (KeyError, IndexError, ValueError):
            ok = False
        if not result(ok, what):
            print(f"      {typed!r} printed: {lines!r}")
    result("AXIOM PANIC" not in log, "no panic")
    result("QEMU ended by itself" in err, "powered off")
    stick()
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
