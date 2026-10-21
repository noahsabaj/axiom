#!/usr/bin/env python3
"""The watchdog kept (watch.asm), as axiom-1 has it, in QEMU.

    python tools/test/watchdog/run.py

Three boots side by side (build/esp, built first):
  - watch: 'watchdog' is off; 'watchdog on 5' is too short and 'watchdog
    test' needs it on; 'watchdog on 12' starts QEMU's TCO watchdog (ICH9's,
    at 0x660), whose count is seen moving, and watches the network for 300
    s; for 40 s, over three times its 12 s, the main loop reloads it and
    nothing resets; then 'watchdog test' stops the main loop, interrupts
    on, and the TCO resets the machine (QEMU ends: -no-reboot) within its
    two counts;
  - net: no network card; 'watchdog net 10' is too short; 'watchdog net 30',
    'watchdog on 60': 30 s with no network, the log into AxiomLog and a
    full reset (QEMU ends), no panic;
  - netok: QEMU's network (rtl8139, its DHCP); 'watchdog net 30', 'watchdog
    on 60', an address; 45 s on, no reset;
  - gateway: QEMU's network, then 'ip' with a gateway no one answers for:
    an address and a link, but no network: a full reset after 30 s, saying
    why.
Outputs go to build/test/watchdog/.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "test"))
from qemu import boot_all  # noqa: E402

OUT = ROOT / "build" / "test" / "watchdog"
FAILS = 0


def result(ok, text):
    global FAILS
    FAILS += 0 if ok else 1
    print(("PASS " if ok else "FAIL ") + text)
    return ok


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    script = ["type watchdog\\n", "until ('watchdog on' starts it)",
              "type watchdog on 5\\n", "until usage: watchdog on",
              "type watchdog test\\n", "until only while the watchdog is on",
              "type watchdog on 12\\n", "until watchdog: on:",
              "until watchdog: counting",
              "wait 40",
              "type watchdog\\n", "until watchdog: on:",
              "type watchdog test\\n", "until the main loop stops here",
              "ended"]
    net = ["type watchdog net 10\\n", "until usage: watchdog net",
           "type watchdog net 30\\n", "until and with no network for 30 s",
           "type watchdog on 60\\n", "until watchdog: on:",
           "until watchdog: no network for 30 s", "ended"]
    netok = ["type watchdog net 30\\n", "until and with no network for 30 s",
             "type watchdog on 60\\n", "until watchdog: on:", "until dhcp: address",
             "wait 45", "type watchdog\\n", "until watchdog: on:"]
    gateway = ["until dhcp: address", "type ip 10.0.2.15/24 10.0.2.99\\n", "wait 1",
               "type watchdog net 30\\n", "until and with no network for 30 s",
               "type watchdog on 60\\n", "until watchdog: on:",
               "until watchdog: no network for 30 s", "ended"]
    runs = boot_all(OUT, {"watch": (script, ["--smp", "2"], 90),
                          "net": (net, ["--smp", "2"], 120),
                          "netok": (netok, ["--smp", "2", "--nic", "rtl8139"], 120),
                          "gateway": (gateway, ["--smp", "2", "--nic", "rtl8139"], 120)})
    log, err = runs["watch"]
    ended = "ended by itself" in err
    result("watchdog: off ('watchdog on' starts it)" in log, "'watchdog' says it is off")
    result("usage: watchdog on [<seconds>]: 10 to 600, 120 unless said" in log,
           "'watchdog on 5' is too short: its usage")
    result("watchdog test: only while the watchdog is on" in log, "'watchdog test' needs it on")
    result("watchdog: on: the machine resets at most 12 s after Axiom's main loop stops "
           "(TCO at I/O 660)" in log, "'watchdog on 12' starts QEMU's TCO watchdog at 0x660")
    result("watchdog: counting (" in log and "of 10 ticks left a second on)" in log,
           "its count is seen moving (10 ticks of 0.6 s from the top, counted twice)")
    result("watchdog: and with no network for 300 s, a full reset (its power cycled)" in log,
           "'watchdog on' watches the network too: 300 s unless said")
    after = log[log.find("watchdog: counting"):]
    result(after.count("watchdog: on: the machine resets at most 12 s") == 1 and
           "watchdog test: the main loop stops here" in after,
           "40 s on, with the main loop reloading it, the machine still runs")
    result(ended, "'watchdog test' stops the main loop; the TCO resets the machine (QEMU ends)")
    stop = log.rfind("watchdog test: the main loop stops here")
    result(stop >= 0 and "AXIOM PANIC" not in log[stop:],
           "no panic: the reset is the chipset's")

    log, err = runs["net"]
    result("usage: watchdog net <seconds>|off: 30 to 3600, 300 unless said" in log,
           "net: 'watchdog net 10' is too short: its usage")
    result("watchdog: no network for 30 s: a full reset, the machine's power cycled" in log
           and "(lately: no address)" in log, "net: no network card, 30 s: a full reset")
    result("goes into AxiomLog" in log, "net: the log into AxiomLog first")
    result("ended by itself" in err, "net: the machine reset (QEMU ends)")
    result("AXIOM PANIC" not in log, "net: no panic")

    log, err = runs["netok"]
    result("dhcp: address" in log, "netok: an address from QEMU's DHCP")
    result(log.count("watchdog: on: the machine resets at most 60 s") == 2 and
           "watchdog: no network for" not in log and "ended by itself" not in err,
           "netok: 45 s on with the network, no reset")

    log, err = runs["gateway"]
    result("watchdog: no network for 30 s: a full reset" in log and
           "(lately: the gateway does not answer)" in log,
           "gateway: an address and a link, a gateway that never answers: a full reset")
    result("ended by itself" in err and "AXIOM PANIC" not in log,
           "gateway: the machine reset (QEMU ends), no panic")
    print(f"{'all passed' if not FAILS else f'{FAILS} FAILED'}")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
