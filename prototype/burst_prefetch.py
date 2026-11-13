#!/usr/bin/env python3
"""
Burst-prefetch prototype: can two clients share ONE Xtream connection for VOD?

The scheme under test: hold the connection only in bursts. Wait for the slot,
grab it, download a chunk well ahead of playback, release it so the other client
can do the same, repeat. Whether that sustains playback depends on two numbers we
do not get to choose - how fast the server delivers, and how long the slot takes
to free after a download ends - so this measures both while it runs.

Run one copy per "TV":

    ./burst_prefetch.py --label A --query "matrix"
    ./burst_prefetch.py --label B --query "inception"

It downloads into a growing local file you can open in a player (mpv/VLC), and
prints a verdict at the end: whether the buffer kept up with playback, and what
burst length the measured latency actually demands.
"""
import argparse, contextlib, fcntl, json, os, random, re, subprocess, sys, time
import urllib.parse, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOCK_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".slot.lock")


USE_LOCK = False  # set by --coordinate


@contextlib.contextmanager
def slot(tag, label=""):
    """
    Take a turn at the single connection.

    Two real TVs share nothing, so by default there is no coordination at all:
    each client simply attempts the download, treats 458 as "someone else has
    it", and backs off. What makes them take turns is the buffer target - once a
    client is far enough ahead it stops asking, which frees the slot for the
    other. --coordinate adds a local file lock, which is only meaningful when
    both clients run on this one machine.
    """
    if not USE_LOCK:
        yield 0.0
        return
    handle = open(LOCK_PATH, "w")
    waiting_since = time.time()
    announced = False
    while True:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if not announced:
                print(f"{tag} other client holds the slot, queuing{label}...")
                announced = True
            time.sleep(1 + random.random())  # jitter so they never sync up
    try:
        # Our turn. Do NOT gate on active_cons: that counter lags behind the
        # server, so waiting for it to read "free" throws away seconds where the
        # stream would already have been accepted. Just try - 458 is the real
        # answer, and the caller retries on it.
        yield time.time() - waiting_since
    finally:
        fcntl.flock(handle, fcntl.LOCK_UN)
        handle.close()



def serve_growing_file(path, stop_flag):
    """
    Serve a file that is still being written, without ever signalling EOF.

    VLC reads a local file's length when it opens and stops there, so a growing
    file cuts out at whatever size it had at launch. Streaming it over HTTP with
    no Content-Length instead makes VLC treat it as a live stream: when the
    reader catches up to the downloader we simply wait for more bytes rather
    than closing the connection.
    """
    import http.server, socketserver, threading

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"  # close-delimited: no length needed

        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "video/x-matroska")
            self.send_header("Accept-Ranges", "none")
            self.end_headers()
            sent = 0
            idle = 0.0
            try:
                with open(path, "rb") as handle:
                    while not stop_flag.is_set():
                        handle.seek(sent)
                        chunk = handle.read(1 << 20)
                        if chunk:
                            self.wfile.write(chunk)
                            sent += len(chunk)
                            idle = 0.0
                        else:
                            # Caught up with the downloader - wait, do not close.
                            time.sleep(0.5)
                            idle += 0.5
                            if idle > 300:
                                break
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def backoff(base, attempt, cap=150.0):
    """
    Full-jitter backoff over a deliberately wide window.

    Two clients retrying on the same fixed interval stay in phase and collide
    forever. The defence is randomness across a *large* range: a short base keeps
    pickup quick when the slot is genuinely free, while the window grows fast so
    repeated collisions scatter the two clients far apart in time.
    """
    # Floor of 20s is not politeness, it is correctness: a request keeps the slot
    # occupied for ~15-35s after it finishes, so two clients retrying faster than
    # that hold it permanently against each other and neither ever gets in.
    floor = max(base, 20.0)
    window = min(cap, floor * 2 * (2 ** min(attempt, 3)))
    return random.uniform(floor, window)


def wait_for_free(tag, retry_every, deadline, quiet=False):
    """
    Wait for a chance at the slot, then return so the caller can try.

    active_cons is advisory only - it goes stale and keeps reading "busy" long
    after the other client has actually gone quiet. Trusting it alone means
    waiting forever through a window that was free the whole time. So watch it
    for a fast opening, but also just *try anyway* on a randomised interval: the
    only authoritative answer is what the stream request returns.
    """
    time.sleep(random.uniform(2, 8))  # desynchronise before watching
    # Measured: the server frees the slot within ~1s of a client finishing
    # cleanly, and a refusal costs nothing. The long lockouts we saw came from
    # our own aborted transfers, not from server-side hold time. So retry
    # promptly - the cost of asking is low, and the opening is brief.
    blind_try_at = time.time() + random.uniform(12, 30)
    while time.time() < deadline:
        active, cap = active_connections()
        if active < 0 or active < cap:
            time.sleep(random.uniform(0.5, 3))  # stagger the pounce
            return True
        if time.time() >= blind_try_at:
            if not quiet:
                print(f"{tag} counter still says {active}/{cap}, but trying anyway "
                      f"(it goes stale)")
            return True
        if not quiet:
            remaining = blind_try_at - time.time()
            print(f"{tag} waiting for the slot [{active}/{cap}] "
                  f"- trying regardless in {remaining:.0f}s")
        time.sleep(retry_every * random.uniform(0.7, 1.3))
    return False


# IPTV servers commonly reject Python-urllib's default User-Agent outright - it
# comes back as 458, exactly like a connection-limit refusal, which is what sent
# this prototype chasing phantom "busy slot" problems. Identify as a player.
USER_AGENT = "VLC/3.0.20 LibVLC/3.0.20"


def creds():
    values = {}
    with open(os.path.join(REPO, "xtream.properties")) as handle:
        for line in handle:
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = line.split("=", 1)
                values[key.strip()] = value.strip()
    server = values["XTREAM_SERVER"].rstrip("/")
    return server, values["XTREAM_USER"], values["XTREAM_PASS"]


SERVER, USER, PASSWORD = creds()


def api(action="", extra=""):
    url = f"{SERVER}/player_api.php?username={USER}&password={PASSWORD}"
    if action:
        url += f"&action={action}{extra}"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def active_connections():
    """Slots in use. This is an API call, so it costs no stream connection."""
    try:
        info = api().get("user_info", {})
        return int(info.get("active_cons", 0)), int(info.get("max_connections", 1))
    except Exception:
        return -1, 1


def find_title(query):
    """First VOD match for the query, preferring lower-bitrate sources."""
    cache = "/private/tmp/claude-501/-Users-nirajgautam/6b6366a3-2338-4a37-b3b5-a181e4f8cceb/scratchpad/all_vod.json"
    if not os.path.exists(cache):
        sys.exit("No catalogue cache; pass --stream-id instead.")
    with open(cache) as handle:
        catalogue = json.load(handle)
    matches = [x for x in catalogue if query.lower() in x.get("name", "").lower()]
    if not matches:
        sys.exit(f"Nothing matching {query!r}")
    # 4K/UHD copies are the ones that cannot fit two streams, so rank them last.
    matches.sort(key=lambda x: ("4k" in x["name"].lower() or "uhd" in x["name"].lower()))
    chosen = matches[0]
    return chosen["stream_id"], chosen.get("container_extension", "mkv"), chosen["name"]


def stream_url(stream_id, ext):
    return f"{SERVER}/movie/{USER}/{PASSWORD}/{stream_id}.{ext}"


def fetch_range(url, start, length, sink=None):
    """
    One burst. Returns (status, bytes_written, seconds). 458 = connection limit.

    Streams straight to disk in chunks rather than reading the whole range into
    memory: a burst is hundreds of megabytes, and buffering that in RAM while
    also tripping the socket timeout was killing the download outright.
    """
    request = urllib.request.Request(url, headers={
        "Range": f"bytes={start}-{start+length-1}", "User-Agent": USER_AGENT})
    began = time.time()
    written = 0
    try:
        # Generous timeout: this is a per-read deadline, and a large burst on a
        # slow edge node legitimately takes minutes.
        with urllib.request.urlopen(request, timeout=90) as response:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                if sink is not None:
                    sink.write(chunk)
                written += len(chunk)
            if sink is not None:
                sink.flush()
            return response.status, written, time.time() - began
    except urllib.error.HTTPError as error:
        return error.code, 0, time.time() - began
    except Exception as error:
        # Partial data already on disk still counts; report what we got.
        return (206 if written else 0), written, time.time() - began


def total_size(url):
    request = urllib.request.Request(url, headers={
        "Range": "bytes=0-1", "User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            crange = response.headers.get("Content-Range", "")
            match = re.search(r"/(\d+)$", crange)
            return int(match.group(1)) if match else 0
    except urllib.error.HTTPError as error:
        if error.code == 458:
            return -1
        return 0
    except Exception:
        return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", default="A", help="which TV this pretends to be")
    parser.add_argument("--query", default="", help="title to look up")
    parser.add_argument("--stream-id", type=int, default=0)
    parser.add_argument("--ext", default="mkv")
    parser.add_argument("--buffer", type=float, default=600,
                        help="seconds of video to keep ahead; this cap is what makes a client yield the slot")
    parser.add_argument("--ramp", default="150,360,600",
                        help="buffer targets in seconds: reach the first fast so playback "
                             "starts, then build to the last and hold it")
    parser.add_argument("--burst", type=float, default=0,
                        help="override seconds of video per turn (0 = follow the ramp)")
    parser.add_argument("--chunk-mb", type=float, default=24,
                        help="size of each individual range request; small enough that "
                             "the server never truncates one")
    parser.add_argument("--cooldown", type=float, default=120,
                        help="stay off the connection this long after a successful burst, "
                             "so the other client can get in")
    parser.add_argument("--retry-every", type=float, default=6,
                        help="seconds between attempts while the slot is busy")
    parser.add_argument("--minutes", type=float, default=10, help="how long to run")
    parser.add_argument("--play", action="store_true", help="open a player once buffered")
    parser.add_argument("--coordinate", action="store_true",
                        help="share a local lock (only valid when both clients "
                             "run on this machine; real TVs cannot)")
    parser.add_argument("--play-at", type=float, default=90,
                        help="seconds of video to buffer before opening the player")
    args = parser.parse_args()
    global USE_LOCK
    USE_LOCK = args.coordinate

    if args.stream_id:
        stream_id, ext, name = args.stream_id, args.ext, f"stream {args.stream_id}"
    else:
        stream_id, ext, name = find_title(args.query or "the")
    url = stream_url(stream_id, ext)
    time.sleep(random.uniform(0, 6))  # stagger clients started together

    tag = f"[{args.label}]"
    print(f"{tag} build   : v19 (ramp {args.ramp}s, then quiet {args.cooldown:.0f}s, poll every {args.retry_every:.0f}s, {args.chunk_mb:.0f}MB chunks)")
    print(f"{tag} title   : {name[:70]}")

    duration = 0
    try:
        info = api("get_vod_info", f"&vod_id={stream_id}").get("info", {}) or {}
        duration = int(info.get("duration_secs") or 0)
    except Exception:
        pass

    # Keep trying for the size: the other client's burst can easily run a minute
    # or more, and giving up after a few attempts just kills this client before it
    # ever gets a turn.
    size = 0
    probe_deadline = time.time() + 15 * 60
    probe_attempts = 0
    while time.time() < probe_deadline:
        probe_attempts += 1
        with slot(tag, " to read the file size"):
            size = total_size(url)
        if size > 0:
            break
        print(f"{tag} slot busy (x{probe_attempts}) - watching for it to free")
        wait_for_free(tag, args.retry_every, probe_deadline)
    if size <= 0:
        sys.exit(f"{tag} could not read the file size after 15 min of retries")

    rate = size / duration if duration else 0  # bytes per second of video
    print(f"{tag} size    : {size/1e9:.2f} GB   duration: {duration//60} min")
    print(f"{tag} bitrate : {rate*8/1e6:.2f} Mbps ({rate/1024:.0f} KB/s of video)" if rate
          else f"{tag} bitrate : unknown (no duration)")

    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"buffer_{args.label}.{ext}")
    ramp = [float(x) for x in args.ramp.split(",") if x.strip()] or [600.0]
    stage = 0
    chunk_bytes = int(args.chunk_mb * 1024 * 1024)
    out = open(out_path, "wb")
    print(f"{tag} writing : {out_path}")

    import threading
    stop_serving = threading.Event()
    play_target = out_path
    downloaded = 0          # bytes on disk
    played = 0.0            # seconds of video notionally consumed
    started = time.time()
    waits, speeds, refusals, stalls = [], [], 0, 0
    launched = False
    deadline = started + args.minutes * 60

    # Without a duration we cannot reason in seconds of video, so fall back to a
    # fixed 8 MB burst just to exercise the mechanism.
    def burst_bytes(latency_estimate):
        if not rate:
            return 8 << 20
        if args.burst:
            return int(args.burst * rate)
        # Fetch the shortfall plus what playback will eat during the idle period,
        # so each turn ends with the buffer at target and the connection free.
        played_now = time.time() - started
        have = downloaded / rate - played_now
        need = max(30.0, (ramp[stage] - have) + args.cooldown)
        return int(need * rate)

    try:
        while time.time() < deadline:
            played = time.time() - started
            buffered = (downloaded / rate - played) if rate else 0
            # Walk up the ramp: once the current target is met, aim for the next.
            while rate and stage < len(ramp) - 1 and buffered >= ramp[stage] * 0.95:
                stage += 1
                print(f"{tag} buffer target -> {ramp[stage]/60:.0f} min")
            target_buffer = ramp[stage] if rate else 0
            if rate and buffered >= target_buffer:
                time.sleep(2)
                continue
            if rate and buffered < 0 and downloaded:
                stalls += 1
                print(f"{tag} !! BUFFER EMPTY at {played:.0f}s - playback would stall")

            latency = sorted(waits)[len(waits)//2] if waits else 10.0
            want = burst_bytes(latency)

            # Take the slot exclusively, then download. Holding it across the
            # whole burst is what stops the two clients thrashing each other.
            with slot(tag) as queued:
                began_turn = time.time()
                attempts = 0
                while time.time() < deadline:
                    attempts += 1
                    # Fetch the burst as a sequence of modest range requests that
                    # each complete, rather than one huge one. A 200 MB+ range gets
                    # truncated by the server, and a truncated transfer leaves a
                    # half-open session that blocks the slot for minutes - which is
                    # what locked this client out of its own next turn.
                    got, elapsed, status = 0, 0.0, 206
                    target = want
                    while got < target and time.time() < deadline:
                        piece = min(chunk_bytes, target - got)
                        code, wrote, spent = fetch_range(url, downloaded + got, piece, out)
                        elapsed += spent
                        if code == 458:
                            status = 458 if got == 0 else 206
                            break
                        if not wrote:
                            break
                        got += wrote
                        status = 206
                        print(f"{tag}   chunk {wrote/1048576:.0f} MB "
                              f"({got/1048576:.0f}/{target/1048576:.0f} MB of this burst, "
                              f"{wrote/spent/1024 if spent else 0:.0f} KB/s)")
                        if wrote < piece * 0.9:
                            break  # server ended this piece early; stop cleanly
                    if status != 458:
                        break
                    refusals += 1
                    # Still held by the other client. Ask the advisory counter how
                    # busy things look and sleep accordingly - a hint, not a gate.
                    print(f"{tag} 458 busy (x{attempts}) - watching for the slot")
                    wait_for_free(tag, args.retry_every, deadline)
                waited = queued + (time.time() - began_turn - elapsed)
            if status == 458:
                waits.append(waited)
                continue  # ran out of time inside the retry loop
            if not got:
                print(f"{tag} empty response (status {status}); retrying")
                time.sleep(backoff(args.retry_every, 1))
                continue

            downloaded += got
            speed = got / elapsed if elapsed else 0
            # Did we actually get the burst we asked for? A transfer cut short
            # still writes useful bytes, but it must NOT earn a full quiet period
            # - going silent for two minutes holding one minute of video starves
            # this client.
            complete = got >= want * 0.8
            if not complete:
                print(f"{tag} burst cut short: got {got/1e6:.0f} MB of "
                      f"{want/1e6:.0f} MB requested")
            speeds.append(speed)
            if waited > 0.5:
                waits.append(waited)
            buffered = (downloaded / rate - played) if rate else 0
            print(f"{tag} +{got/1e6:5.1f} MB in {elapsed:5.1f}s "
                  f"({speed/1024:4.0f} KB/s)  waited {waited:4.1f}s  "
                  f"buffer {buffered:5.0f}s  total {downloaded/1e6:6.0f} MB")

            if args.play and not launched and rate and buffered > args.play_at:
                launched = True
                # A growing file plays fine, but VLC reads what exists when it
                # opens - so give it a real head start, and tell it not to quit
                # the moment it catches up to the download.
                # Hand the file to LaunchServices rather than spawning VLC as a
                # child: forking a GUI app from this process crashes the Python
                # interpreter on macOS, which took the whole downloader with it.
                # -n forces a NEW VLC instance: without it the file is just handed
                # to whatever VLC is already open, which shows nothing, and two
                # clients could never play at once. Report what actually happened
                # rather than assuming it worked.
                try:
                    port = serve_growing_file(out_path, stop_serving)
                    play_target = f"http://127.0.0.1:{port}/stream.mkv"
                    result = subprocess.run(["open", "-n", "-a", "VLC", play_target],
                                            check=False, timeout=30,
                                            capture_output=True, text=True)
                    # A cold VLC launch can take several seconds; poll instead
                    # of assuming it failed after a fixed two.
                    running = ""
                    for _ in range(12):
                        time.sleep(1)
                        running = subprocess.run(["pgrep", "-x", "VLC"],
                                                 capture_output=True, text=True).stdout.strip()
                        if running:
                            break
                    if result.returncode == 0 and running:
                        print(f"{tag} >>> VLC OPENED ({buffered:.0f}s buffered) <<<")
                    else:
                        detail = (result.stderr or result.stdout or "").strip()
                        print(f"{tag} !! VLC did not start"
                              f"{' - ' + detail if detail else ''}")
                    # Always show the command: even a successful launch can end up
                    # behind another window or on a different Space, and the stream
                    # stays open for the whole run.
                    print(f"{tag} play/replay any time with:")
                    print(f"    open -n -a VLC {play_target}")
                except Exception as error:
                    print(f"{tag} !! could not launch VLC ({error}). Open it yourself:"
                          f"\n    open -n -a VLC {play_target}")

            # Deliberately stay off the connection for a while. Refilling the
            # moment we finish would keep the slot permanently, so the quiet
            # period - not politeness - is what lets the other client in. We
            # start refilling well before the buffer is low, so the pause never
            # risks a stall.
            quiet = args.cooldown if complete else max(args.retry_every, 20.0)
            quiet_until = time.time() + quiet
            print(f"{tag} holding off {quiet:.0f}s so the other client can fetch"
                  f"{'' if complete else ' (short - still need to top up)'}")
            while time.time() < quiet_until and time.time() < deadline:
                time.sleep(2)

    except KeyboardInterrupt:
        print(f"\n{tag} stopped")
    finally:
        stop_serving.set()
        out.close()

    elapsed_total = time.time() - started
    median_wait = sorted(waits)[len(waits)//2] if waits else 0
    median_speed = sorted(speeds)[len(speeds)//2] if speeds else 0
    print(f"\n{tag} ===== RESULT =====")
    print(f"{tag} ran for            : {elapsed_total/60:.1f} min")
    print(f"{tag} downloaded         : {downloaded/1e6:.0f} MB")
    print(f"{tag} median burst speed : {median_speed/1024:.0f} KB/s")
    print(f"{tag} median slot wait   : {median_wait:.1f}s")
    print(f"{tag} refusals (458)     : {refusals}")
    print(f"{tag} buffer-empty events: {stalls}")
    if rate:
        got = downloaded / elapsed_total
        print(f"{tag} sustained rate     : {got/1024:.0f} KB/s vs {rate/1024:.0f} needed "
              f"-> {got/rate:.2f}x realtime {'OK' if got >= rate else 'TOO SLOW'}")
        if median_speed and median_wait:
            # B*T/(T+H) >= R, solved for T.
            need = (rate * median_wait) / (median_speed - rate) if median_speed > rate else None
            if need:
                print(f"{tag} burst needed       : >= {need:.0f}s of video per turn "
                      f"to survive a {median_wait:.0f}s handoff")
            else:
                print(f"{tag} burst needed       : impossible - server is slower than the bitrate")


if __name__ == "__main__":
    main()
