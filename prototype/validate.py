#!/usr/bin/env python3
"""
Answer, with measurements, whether two clients can share one Xtream connection.

Each test waits for a genuinely idle slot first and only makes small, complete
requests, so nothing here leaves the debris that has been confusing earlier runs.
"""
import json, subprocess, sys, threading, time, urllib.error, urllib.request

import os
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VLC_UA = "VLC/3.0.20 LibVLC/3.0.20"


def creds():
    values = {}
    for line in open(f"{REPO}/xtream.properties"):
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            values[k.strip()] = v.strip()
    return values["XTREAM_SERVER"].rstrip("/"), values["XTREAM_USER"], values["XTREAM_PASS"]


SERVER, USER, PASSWORD = creds()
MOVIE = f"{SERVER}/movie/{USER}/{PASSWORD}/2145983.mkv"


def active():
    try:
        request = urllib.request.Request(
            f"{SERVER}/player_api.php?username={USER}&password={PASSWORD}",
            headers={"User-Agent": VLC_UA})
        with urllib.request.urlopen(request, timeout=15) as response:
            info = json.load(response)["user_info"]
            return int(info.get("active_cons", 0)), int(info.get("max_connections", 1))
    except Exception:
        return -1, 1


def wait_idle(limit=300):
    began = time.time()
    while time.time() - began < limit:
        used, _ = active()
        if used == 0:
            return time.time() - began
        time.sleep(5)
    return None


def get(url, nbytes, ua=VLC_UA, timeout=60):
    """One small, complete range request. Returns (status, bytes, seconds)."""
    headers = {"Range": f"bytes=0-{nbytes-1}"}
    if ua:
        headers["User-Agent"] = ua
    began = time.time()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=headers),
                                    timeout=timeout) as response:
            data = response.read()
            return response.status, len(data), time.time() - began
    except urllib.error.HTTPError as error:
        return error.code, 0, time.time() - began
    except Exception as error:
        return type(error).__name__, 0, time.time() - began


def headline(text):
    print(f"\n{'='*64}\n{text}\n{'='*64}")


results = {}

headline("1. Does the User-Agent matter?")
for label, ua in [("python-urllib default", None), ("VLC", VLC_UA)]:
    idle = wait_idle()
    if idle is None:
        print(f"  {label:22s} -> slot never idled; skipped")
        continue
    status, got, spent = get(MOVIE, 512 * 1024, ua=ua)
    print(f"  {label:22s} -> HTTP {status}, {got/1024:.0f} KB in {spent:.1f}s")
    results[f"ua:{label}"] = status
proc = subprocess.run(["curl", "-s", "-o", "/dev/null", "-L", "-r", "0-524287",
                       "--max-time", "60", "-w", "%{http_code}", MOVIE],
                      capture_output=True, text=True)
print(f"  {'curl':22s} -> HTTP {proc.stdout.strip()}")
results["ua:curl"] = proc.stdout.strip()

headline("2. How fast is the slot released after a CLEAN request?")
wait_idle()
status, got, spent = get(MOVIE, 2 * 1024 * 1024)
print(f"  request: HTTP {status}, {got/1048576:.1f} MB in {spent:.1f}s")
began = time.time()
freed = None
for _ in range(60):
    used, _ = active()
    if used == 0:
        freed = time.time() - began
        break
    time.sleep(1)
print(f"  slot freed after: {freed:.1f}s" if freed is not None else "  still busy after 60s")
results["release_clean"] = freed

headline("3. Two clients at once: what does the loser see?")
wait_idle()
outcomes = {}
def hit(name, delay):
    time.sleep(delay)
    outcomes[name] = get(MOVIE, 8 * 1024 * 1024, timeout=90)
threads = [threading.Thread(target=hit, args=("A", 0)), threading.Thread(target=hit, args=("B", 0.3))]
[t.start() for t in threads]; [t.join() for t in threads]
for name in ("A", "B"):
    status, got, spent = outcomes[name]
    print(f"  client {name}: HTTP {status}, {got/1048576:.1f} MB in {spent:.1f}s")
results["parallel"] = {k: v[0] for k, v in outcomes.items()}

headline("4. Handoff: how soon can the second client start after the first finishes?")
wait_idle()
status, got, spent = get(MOVIE, 4 * 1024 * 1024)
print(f"  client A finished cleanly: HTTP {status}, {got/1048576:.1f} MB")
handoff = None
began = time.time()
for attempt in range(1, 21):
    status2, got2, _ = get(MOVIE, 1024 * 1024)
    if status2 == 206:
        handoff = time.time() - began
        print(f"  client B got in after {handoff:.1f}s (attempt {attempt})")
        break
    time.sleep(2)
if handoff is None:
    print("  client B never got in within 40s")
results["handoff"] = handoff

headline("VERDICT")
ua_blocked = results.get("ua:python-urllib default") == 458 and results.get("ua:VLC") == 206
if ua_blocked:
    print("  * User-Agent MATTERS - python-urllib is rejected, VLC is accepted.")
else:
    print("  * User-Agent is not the deciding factor.")
if results.get("release_clean") is not None and results["release_clean"] <= 5:
    print(f"  * Clean requests free the slot in {results['release_clean']:.1f}s - handoffs are cheap.")
else:
    print("  * Clean requests do NOT free the slot promptly - handoffs are expensive.")
par = results.get("parallel", {})
if 458 in par.values() and 206 in par.values():
    print("  * Exactly one client streams at a time; the other is refused immediately.")
elif list(par.values()).count(206) == 2:
    print("  * BOTH clients streamed at once - the limit is not strictly enforced!")
if results.get("handoff") is not None:
    print(f"  * A waiting client gets in {results['handoff']:.1f}s after the other finishes.")
    print("  => Two clients CAN share one connection, provided every transfer completes.")
else:
    print("  => A waiting client could not get in; sharing is not reliable.")
