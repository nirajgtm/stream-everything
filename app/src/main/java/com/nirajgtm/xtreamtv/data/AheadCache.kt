package com.nirajgtm.xtreamtv.data

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.HttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.ContentMetadata
import com.nirajgtm.xtreamtv.XtreamApp
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Pulls the title being watched down to disk ahead of playback, in a few large
 * bursts with long silent gaps between them.
 *
 * The account allows exactly one connection at a time, and the provider keeps a
 * session alive for roughly half a minute after each request, so the only thing
 * that frees the line for another device is a genuinely idle stretch. Downloading
 * runs several times faster than playback, which is what makes that possible:
 * race through a big cushion while the line is held, then let go of it entirely
 * and live off the disk for many minutes. Fetching a little and often would be
 * the worst of both - the session never lapses and nothing is ever banked.
 *
 * Two rules follow from that and are worth stating plainly:
 *
 *  - Every request is a COMPLETE, closed 24 MB range. A range that is abandoned
 *    part-way leaves the provider holding the slot for minutes; one that runs to
 *    the end releases it in about a second. Anything much over 50 MB gets
 *    truncated by the server, which amounts to the same thing.
 *  - What counts as "banked" is only what is cached CONTIGUOUSLY from the byte
 *    playback has reached. Fragments scattered elsewhere in the file are worth
 *    nothing to a player reading forward, and counting them is what previously
 *    convinced this class it could sit idle while the player streamed.
 */
@OptIn(UnstableApi::class)
class AheadCache(private val app: XtreamApp) {

    /** How the player learns that the provider is refusing us for now. */
    interface Listener {
        /**
         * The allowed connections are all in use elsewhere. [attempt] is how many
         * retries have happened, [bankedSeconds] how much video is already on disk
         * ahead of the playhead - with a deep cushion this is invisible to the
         * viewer and not worth telling them about.
         */
        fun onConnectionBusy(attempt: Int, bankedSeconds: Long)
        /** A fetch got through again. */
        fun onConnectionFree()
    }

    @Volatile var listener: Listener? = null

    private companion object {
        const val TAG = "AheadCache"
        /** Small enough that the server never truncates the response. */
        const val CHUNK_BYTES = 24L * 1024 * 1024
        const val DEMAND_BYTES = 3L * 1024 * 1024  // per-piece size for player-blocking reads

        /** Front-loaded on every new title so a RESUME can seek instantly: the MKV
         *  header/SeekHead/Tracks (and cues, if the muxer put them up front) live in
         *  the first few MB; the cues index of a seekable MKV usually lives in the
         *  last few. Without these on disk, ExoPlayer's first seek to the resume
         *  point stalls the player through 2-3 sequential fetches over the one slow
         *  connection - measured at 6-22s to first frame. */
        const val HEADER_PRIME_BYTES = 4L * 1024 * 1024
        const val CUES_PRIME_BYTES = 8L * 1024 * 1024

        /** Burst sizes escalate: a small first fetch gets playback started almost
         *  immediately, then each successive burst grows so the session count
         *  stays low while the cushion deepens. Reset on title switch and seeks. */
        val BURST_LADDER_BYTES = longArrayOf(
            10L shl 20, 20L shl 20, 30L shl 20, 50L shl 20,
            100L shl 20, 150L shl 20, 200L shl 20)

        /** Rewind window kept BEHIND the playhead. Everything older is trimmed to
         *  make room for what is ahead; a rewind past it simply re-downloads from
         *  that point (the blocking reader requests the range like any other). */
        const val KEEP_BEHIND_SECONDS = 30L

        /** Opening goal once a title is opened: ten minutes from the resume point. */
        const val OPENING_SECONDS = 600L
        /** A couple of minutes into playback, aim twenty minutes ahead. */
        const val ROLLING_SECONDS = 1_200L
        /** Past this much banked, take the whole title as far as space allows. */
        const val BANKED_SECONDS = 600L
        const val ROLLING_AFTER_MS = 120_000L

        /** Come back to the wire once the cushion is down to this much video. At
         *  four to six times real time, refilling takes a small fraction of it. */
        const val REFILL_AT_SECONDS = 300L
        /** Ceiling on one burst, measured in video rather than bytes so it scales
         *  with the bitrate. Big on purpose: one long session costs the provider
         *  less than several short ones. */
        const val MAX_BURST_SECONDS = 2_700L

        /** Head of the next episode to bank before the switch. */
        const val NEXT_EPISODE_SECONDS = 300L

        const val MIN_IDLE_MS = 3_000L
        const val MAX_IDLE_MS = 10 * 60_000L
        const val RETRY_MS = 30_000L
        /** Cushion fetches are not blocking the player: retry a few times, then idle
         *  and reassess. A demand range the player is waiting on is never given up on. */
        const val MAX_CUSHION_ATTEMPTS = 4
        /** 458 is the provider's "connection limit reached". Wait a minute, retry. */
        const val BUSY_RETRY_MS = 60_000L
        const val CONNECTION_LIMIT_CODE = 458

        /** Never squeeze the device below this. */
        const val KEEP_FREE_BYTES = 500L * 1024 * 1024
        /** Bytes kept behind playback before they may be reclaimed (short rewinds). */
        const val KEEP_BEHIND_BYTES = 64L * 1024 * 1024
        /** Until the real rate is known, assume ~6 Mbps. */
        const val ASSUMED_BYTES_PER_SECOND = 750L * 1024

        const val USER_AGENT = "VLC/3.0.20 LibVLC/3.0.20"
        /** A seek bigger than this invalidates the measurement; wake up and redo it. */
        const val SEEK_JUMP_MS = 30_000L
    }

    private enum class Outcome { DONE, REFUSED, FAILED }

    private val exec = Executors.newSingleThreadExecutor { r ->
        Thread(r, "ahead-cache").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }
    }

    @Volatile private var cancelled = false
    @Volatile private var pumping = false
    @Volatile private var generation = 0
    /** The thread currently running the fill loop, so stop() can interrupt a
     *  blocking download the moment the player needs the connection. */
    @Volatile private var worker: Thread? = null
    @Volatile private var wakeRequested = false

    /** The title being filled, and the next episode queued behind it. */
    @Volatile private var currentUrl = ""
    /** Index into BURST_LADDER_BYTES; climbs per successful burst. */
    @Volatile private var burstRung = 0
    /** Whether header + cues have been queued for the current title. */
    @Volatile private var primed = false
    @Volatile private var nextUrl = ""

    /** Latest playback position, fed by the player. */
    @Volatile private var positionMs = 0L
    @Volatile private var durationMs = 0L
    /** Where to start when playback has not reported a position yet (a resume point). */
    @Volatile private var startFraction = 0.0

    /** Set when a burst wrote bytes the evictor immediately took back. */
    @Volatile private var evictionPressure = false
    /** Consecutive 458 refusals, shown to the viewer. */
    @Volatile private var busyAttempts = 0
    /** Seconds of video cached contiguously ahead of the playhead, last time we looked. */
    @Volatile private var bankedSeconds = 0L

    private val lengths = ConcurrentHashMap<String, Long>()

    /**
     * Byte ranges the player's data source is BLOCKED on, each as [start, end).
     * Merged, kept sorted, and serviced before any read-ahead cushion work. A range
     * is only dropped once the bytes are genuinely on disk, so a demand the player
     * is waiting on is retried indefinitely.
     */
    private val pending = ArrayList<LongArray>()
    @Volatile private var pendingFailures = 0

    // ---- public surface ----

    /**
     * Begin filling [url], from [fromFraction] of the way in when playback has not
     * started yet. Called the moment a title is opened, so that pressing Play
     * reads from disk instead of racing the network.
     *
     * Switching titles drops the previous one's bytes: on a device this small,
     * keeping both only starves the thing actually being watched.
     */
    fun prepare(url: String, fromFraction: Double = 0.0) {
        if (url.isBlank()) return
        if (url == currentUrl) {
            if (!pumping) restart()   // same title, fill had finished unwinding
            return
        }
        val previous = currentUrl
        currentUrl = url
        nextUrl = ""
        startFraction = fromFraction.coerceIn(0.0, 0.99)
        burstRung = 0    // new title: first burst small, so playback starts fast
        primed = false   // re-prime header + cues for the new title
        positionMs = 0
        durationMs = 0
        android.util.Log.i(TAG, "prepare url=…${url.takeLast(28)} resumeFrac=" +
            "%.3f".format(startFraction))
        clearBusy()
        synchronized(pending) { pending.clear() }   // the old title's demands are moot
        if (previous.isNotBlank() && previous != url && previous != app.activeMediaUrl) {
            try { app.videoCache.removeResource(previous) } catch (_: Exception) {}
            lengths.remove(previous)
        }
        restart()
    }

    /**
     * Queue the next episode's head. It jumps the queue: the switch happens in
     * seconds and there is no cushion for it at all, whereas the episode on screen
     * already has one.
     */
    fun queueNext(url: String) {
        if (url.isBlank() || url == currentUrl) return
        if (url == nextUrl) return
        nextUrl = url
        wakeRequested = true
    }

    fun updatePosition(position: Long, duration: Long) {
        val previous = positionMs
        positionMs = position
        durationMs = duration
        // A seek throws the measurement away, and the cushion may now be behind us.
        // Old demand ranges are abandoned too - the data source re-requests for the
        // new position, so a seek redirects the one connection instead of finishing
        // work nobody is waiting on any more.
        if (kotlin.math.abs(position - previous) > SEEK_JUMP_MS) {
            burstRung = 0   // after a seek the first burst must land fast, not big
            synchronized(pending) { pending.clear() }
            wakeRequested = true
        }
    }

    /**
     * Ask the downloader, at HIGH priority, to have [minBytes] on disk starting at
     * [startByte] - the range a player data source is blocked on. The pump services
     * these before any read-ahead cushion work, fetching from [startByte] in the
     * usual 24 MB chunks until the range is covered. Overlapping requests are merged,
     * and a sleeping pump is woken at once. Serviced against the title currently being
     * filled (the one on screen), which is what the player is reading.
     */
    fun requestRange(startByte: Long, minBytes: Long) {
        if (startByte < 0) return
        val s = startByte
        val e = startByte + minBytes.coerceAtLeast(1)
        synchronized(pending) {
            pending.add(longArrayOf(s, e))
            pending.sortBy { it[0] }
            val merged = ArrayList<LongArray>(pending.size)
            for (r in pending) {
                val last = merged.lastOrNull()
                if (last != null && r[0] <= last[1]) last[1] = maxOf(last[1], r[1])
                else merged.add(longArrayOf(r[0], r[1]))
            }
            pending.clear(); pending.addAll(merged)
        }
        wakeRequested = true
    }

    /**
     * Total byte length of [url] if it is ALREADY known without touching the network
     * (from what the fill has resolved, or the cache's stored content length). Returns
     * -1 when not known yet; the caller must NOT open a connection for it - the pump
     * resolves it as soon as it starts filling. Lets the data source decide EOF and
     * bytes-remaining while staying entirely off the wire.
     */
    fun knownLength(url: String): Long {
        lengths[url]?.let { if (it > 0) return it }
        val meta = try {
            ContentMetadata.getContentLength(app.videoCache.getContentMetadata(url))
        } catch (_: Exception) { C.LENGTH_UNSET.toLong() }
        if (meta > 0) { lengths[url] = meta; return meta }
        return -1L
    }

    /**
     * Stand down. A request already in flight is allowed to RUN TO THE END first -
     * a few seconds at these speeds. Killing it would leave the provider holding
     * the one connection slot for minutes, which is a far worse thing to leave
     * behind than a chunk nobody asked for.
     */
    fun stop() {
        generation++
        cancelled = true
        // A blocking CacheWriter.cache() will otherwise hold the one connection the
        // account allows for its full read-timeout (tens of seconds), stalling the
        // player that just took over. Interrupting aborts that read at once and frees
        // the slot; the pump sees `cancelled` and exits cleanly.
        try { worker?.interrupt() } catch (_: Exception) {}
    }

    // ---- the fill loop ----

    private fun restart() {
        generation++
        val mine = generation
        cancelled = true                       // let any running pump unwind
        // Single-threaded on purpose: this task cannot begin until the previous one
        // has left, so there is never more than one connection open from here, and
        // the previous request always finishes rather than being torn down.
        try { exec.execute { pump(mine) } } catch (_: Exception) {}
    }

    private fun pump(mine: Int) {
        if (mine != generation) return
        cancelled = false
        pumping = true
        worker = Thread.currentThread()
        try {
            while (!cancelled && mine == generation) {
                val idleMs = try { step() } catch (_: Exception) { RETRY_MS }
                // Refresh the UI span on this background thread so the page's
                // translucent "prefetched" bar reflects what is actually on disk
                // without the main thread ever walking the cache.
                try { refreshSpanForUi() } catch (_: Exception) {}
                if (cancelled || mine != generation) break
                sleep(idleMs)
            }
        } finally {
            pumping = false
            worker = null
            // Clear any pending interrupt so the pooled thread is clean for reuse.
            Thread.interrupted()
        }
    }

    /** One decision and at most one burst. Returns how long to stay off the wire. */
    private fun step(): Long {
        // Anything the player is BLOCKED on comes before all cushion work: it is the
        // one thing a viewer is actually waiting to see.
        val url = currentUrl
        if (url.isNotBlank()) {
            val length = lengthOf(url)
            if (length > 0) {
                if (!primed) {
                    // Header up front, cues at the tail: both must be on disk for a
                    // resume seek to be instant, and both are tiny next to the film.
                    requestRange(0, HEADER_PRIME_BYTES)
                    requestRange((length - CUES_PRIME_BYTES).coerceAtLeast(0), CUES_PRIME_BYTES)
                    primed = true
                    android.util.Log.i(TAG, "primed header+cues, length=" +
                        "%.2fGB".format(length / 1e9))
                }
                servicePending(url, length)?.let { return it }
            }
        }
        val queued = nextUrl
        // The next episode only jumps the queue while the episode on screen is
        // comfortable. Something on screen with nothing banked always wins, so a
        // next episode that cannot be fetched can never starve it.
        if (queued.isNotBlank() && bankedSeconds >= 60) fillNextHead(queued)?.let { return it }
        return fillCurrent()
    }

    /**
     * Fetch, ahead of cushion work, one chunk of the first range the player is
     * blocked on, verifying the bytes into the cache. The request stays queued until
     * it is genuinely satisfied, so across pump iterations a demand is retried until
     * it lands (or a seek clears it). Returns null when nothing is outstanding.
     */
    private fun servicePending(url: String, length: Long): Long? {
        val hole = firstPendingHole(url, length) ?: return null
        if (!makeRoom(url, playbackByteOfCurrent())) return RETRY_MS
        val start = hole[0]
        // Demands are what the player is BLOCKED on, so fetch them in small pieces
        // (the player often needs only a few MB - cues, a resume cluster - to carry
        // on). A 24MB chunk here means a 5-6s stall for bytes it did not all need;
        // 3MB unblocks it in ~1s, and the cushion bursts still do the bulk work.
        val want = (hole[1] - start).coerceAtMost(DEMAND_BYTES)
        if (want <= 0) { prunePending(url, length); return MIN_IDLE_MS }
        val have = cachedCoverage(url, start, want)
        val startedAt = System.currentTimeMillis()
        val outcome = cacheRange(url, start + have, want - have)
        android.util.Log.i(TAG, "DEMAND @${start / 1_000_000}MB +" +
            "${(want - have) / 1_000_000}MB -> $outcome " +
            "(${System.currentTimeMillis() - startedAt}ms)")
        return when (outcome) {
            Outcome.DONE -> { clearBusy(); pendingFailures = 0; prunePending(url, length); MIN_IDLE_MS }
            Outcome.REFUSED -> { waitOutBusyConnection(); MIN_IDLE_MS }
            Outcome.FAILED -> backoffIdle(++pendingFailures)
        }
    }

    /** First outstanding [holeStart, rangeEnd) among the pending demands, or null. */
    private fun firstPendingHole(url: String, length: Long): LongArray? {
        synchronized(pending) {
            val it = pending.iterator()
            while (it.hasNext()) {
                val r = it.next()
                val s = r[0].coerceIn(0, length)
                val e = r[1].coerceAtMost(length)
                if (s >= e) { it.remove(); continue }
                val have = contiguousCachedEnd(url, s, e)
                if (have >= e) { it.remove(); continue }   // already fully cached
                return longArrayOf(have, e)                // hole starts at `have`
            }
        }
        return null
    }

    /** Drop demand ranges now fully on disk (or emptied by a length clamp). */
    private fun prunePending(url: String, length: Long) {
        synchronized(pending) {
            pending.removeAll { r ->
                val s = r[0].coerceIn(0, length); val e = r[1].coerceAtMost(length)
                s >= e || contiguousCachedEnd(url, s, e) >= e
            }
        }
    }

    /** Returns null once the next episode's head is banked, so the feature resumes. */
    private fun fillNextHead(url: String): Long? {
        val length = lengthOf(url)
        if (length <= 0) return RETRY_MS
        val target = minOf(length, NEXT_EPISODE_SECONDS * bytesPerSecond(length))
        val have = contiguousCachedEnd(url, 0, length)
        if (have >= target) return null
        if (!makeRoom(currentUrl, playbackByteOfCurrent())) return RETRY_MS
        val got = burst(url, have, (target - have).coerceAtMost(roomBytes()))
        return if (got > 0) MIN_IDLE_MS else RETRY_MS
    }

    private fun fillCurrent(): Long {
        val url = currentUrl
        if (url.isBlank()) return RETRY_MS
        val length = lengthOf(url)
        if (length <= 0) return RETRY_MS

        val perSecond = bytesPerSecond(length)
        val played = playbackByte(length)
        val cachedTo = contiguousCachedEnd(url, played, length)
        val ahead = cachedTo - played
        val banked = ahead / perSecond
        bankedSeconds = banked

        trimBehind(url, played, perSecond)

        val target = targetAheadBytes(banked, perSecond, played, length)
        if (ahead >= target) return idleFor(banked)

        // Room first. A cushion written and evicted at the same rate is exactly the
        // failure this class exists to prevent, and it looks like progress.
        if (!makeRoom(url, played)) return RETRY_MS

        val rung = BURST_LADDER_BYTES[burstRung.coerceIn(0, BURST_LADDER_BYTES.size - 1)]
        val wanted = (target - ahead)
            .coerceAtMost(length - cachedTo)
            .coerceAtMost(MAX_BURST_SECONDS * perSecond)
            .coerceAtMost(rung)
            .coerceAtMost(roomBytes())
        if (wanted <= 0) return idleFor(banked)
        // Scraps are not worth a session of their own - unless they are the end of
        // the file, in which case there will never be a bigger piece to wait for.
        val nearEnd = length - cachedTo <= CHUNK_BYTES
        if (wanted < CHUNK_BYTES && !nearEnd && banked > REFILL_AT_SECONDS) return idleFor(banked)

        val got = burst(url, cachedTo, wanted)
        if (got <= 0) return RETRY_MS
        if (got >= wanted) burstRung++          // healthy: next burst can be bigger
        val newBank = (ahead + got) / perSecond
        android.util.Log.i(TAG, "BURST +${got / 1_000_000}MB rung=$burstRung " +
            "banked=${newBank}s -> idle ${idleFor(newBank) / 1000}s")
        return idleFor(newBank)
    }

    /**
     * Stay off the wire until the cushion is down to [REFILL_AT_SECONDS] of video.
     * Playback burns one second of cushion per second, so that is simply how much
     * is banked minus the safety margin.
     */
    /**
     * Keep only [KEEP_BEHIND_SECONDS] of already-watched video behind the playhead.
     * Watched bytes are the least valuable thing in the cache, but LRU sees them as
     * freshly-touched (playback just read them) and evicts the unwatched cushion
     * ahead instead. Trimming them ourselves turns that storage into more runway.
     * A rewind past the window is served like any other hole: the blocking reader
     * requests the range and the downloader re-fetches from that point.
     */
    private fun trimBehind(url: String, playedByte: Long, perSecond: Long) {
        try {
            val keepFrom = playedByte - KEEP_BEHIND_SECONDS * perSecond
            if (keepFrom <= 0) return
            for (span in app.videoCache.getCachedSpans(url)) {
                val end = span.position + span.length
                if (end <= keepFrom) app.videoCache.removeSpan(span)
            }
        } catch (_: Exception) { /* housekeeping only */ }
    }

    private fun idleFor(bankedSeconds: Long): Long =
        ((bankedSeconds - REFILL_AT_SECONDS) * 1000L).coerceIn(MIN_IDLE_MS, MAX_IDLE_MS)

    private fun targetAheadBytes(
        bankedSeconds: Long, perSecond: Long, playedBytes: Long, length: Long
    ): Long {
        val rest = length - playedBytes
        // Never aim past what the LRU cache will actually RETAIN. The device may
        // have free disk while the cache is at its byte limit; fetching beyond
        // that limit just hands bytes straight to the evictor - measured on the
        // TV as a 12-minute churn loop (fill to ~1GB, sweep, refill the same
        // bytes) that held the connection continuously and re-downloaded the
        // same content over and over. The film that fits is the film we take.
        val retainable = (app.videoCacheLimit * 7 / 10).takeIf { it > 0 } ?: Long.MAX_VALUE
        val hardCap = minOf(rest, retainable)
        if (growthBlockedUntil > System.currentTimeMillis())
            return minOf(hardCap, ROLLING_SECONDS * perSecond)  // maintain, don't grow
        if (bankedSeconds >= BANKED_SECONDS) return hardCap     // banked deep: take what fits
        val seconds = if (positionMs >= ROLLING_AFTER_MS) ROLLING_SECONDS else OPENING_SECONDS
        return minOf(hardCap, seconds * perSecond)
    }

    /** Set when eviction pressure hits while growing: the cache is as full as it
     *  gets, so stop expanding for a while and let the connection stay closed. */
    @Volatile private var growthBlockedUntil = 0L

    /**
     * One burst: complete 24 MB ranges back to back until [wanted] bytes are in
     * hand, then the caller goes quiet. Back to back is deliberate - the provider
     * charges us a lingering session per burst regardless of its size, so one long
     * pull is cheaper than several short ones, and the download outruns playback
     * by enough that a deep cushion is bought in a couple of minutes.
     */
    private fun burst(url: String, from: Long, wanted: Long): Long {
        var at = from
        var remaining = wanted
        var fetched = 0L
        while (remaining > 0 && !cancelled) {
            val piece = minOf(CHUNK_BYTES, remaining)
            val before = cacheSpace()
            if (!fetchChunk(url, at, piece)) break   // verified + retried; gave up this pass
            // Grew by much less than we wrote: the evictor is taking it straight
            // back, so the cache is at its limit and no amount of fetching helps.
            if (cacheSpace() - before < piece / 2) {
                evictionPressure = true
                // The evictor is taking back what we write: the cache is at its
                // limit. Growing further is churn, so stand down for a while.
                growthBlockedUntil = System.currentTimeMillis() + 10 * 60_000L
            }
            at += piece
            remaining -= piece
            fetched += piece
            if (evictionPressure) break          // reclaim first, then carry on
        }
        return fetched
    }

    /**
     * Fetch [start, start+len) as one closed chunk, VERIFYING the bytes actually
     * landed in the cache (a truncated transfer that pins the slot must not pass for
     * success) and retrying transient failures with escalating, jittered backoff.
     * Bounded - cushion work is not blocking the player - so it gives up after a few
     * attempts and lets the pump reassess. Returns true once the range is verified.
     */
    private fun fetchChunk(url: String, start: Long, len: Long): Boolean {
        var attempt = 0
        while (!cancelled) {
            val have = cachedCoverage(url, start, len)
            if (have >= len) { clearBusy(); return true }
            when (cacheRange(url, start + have, len - have)) {
                Outcome.DONE -> {
                    clearBusy()
                    val after = cachedCoverage(url, start, len)
                    if (after >= len) return true
                    if (after > have) { attempt = 0; continue }   // progress; pull the rest
                    // DONE but nothing verifiably landed (truncated / evicted at once):
                    // fall through to backoff and retry the same range.
                }
                Outcome.REFUSED -> {
                    waitOutBusyConnection()                       // notifies, waits ~60s
                    if (++attempt > MAX_CUSHION_ATTEMPTS) return false
                    continue
                }
                Outcome.FAILED -> Unit
            }
            if (++attempt > MAX_CUSHION_ATTEMPTS) return false
            backoffSleep(attempt)
        }
        return false
    }

    /** Contiguous cached bytes starting at [start], capped at [len]. Cache-only. */
    private fun cachedCoverage(url: String, start: Long, len: Long): Long =
        (contiguousCachedEnd(url, start, start + len) - start).coerceIn(0, len)

    /** Jittered, escalating backoff (cap ~60s) that stays interruptible by a wake. */
    private fun backoffSleep(attempt: Int) {
        val base = (1_000L shl minOf(attempt, 6)).coerceAtMost(60_000L)
        val jitter = (Math.random() * base * 0.3).toLong()
        sleep((base + jitter).coerceAtMost(60_000L))
    }

    /** Same backoff shape as an idle return, for a failed demand the pump re-services. */
    private fun backoffIdle(attempt: Int): Long {
        val base = (1_000L shl minOf(attempt, 6))
        val jitter = (Math.random() * base * 0.3).toLong()
        return (base + jitter).coerceIn(MIN_IDLE_MS, 60_000L)
    }

    private fun cacheRange(url: String, start: Long, len: Long): Outcome {
        return try {
            val source = CacheDataSource.Factory()
                .setCache(app.videoCache)
                .setUpstreamDataSourceFactory(
                    DefaultHttpDataSource.Factory()
                        .setUserAgent(USER_AGENT)
                        .setAllowCrossProtocolRedirects(true)
                        .setConnectTimeoutMs(30_000)
                        .setReadTimeoutMs(30_000))
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
                .createDataSource()
            val spec = DataSpec.Builder().setUri(url).setPosition(start).setLength(len).build()
            CacheWriter(source, spec, null, null)
                .cache()                         // returns only when the range is complete
            Outcome.DONE
        } catch (e: Exception) {
            if (isConnectionRefused(e)) Outcome.REFUSED else Outcome.FAILED
        }
    }

    /**
     * How far the current title is downloaded, as milliseconds of media reachable
     * contiguously from [positionMs]. Feeds the seek bar's buffered indicator, so
     * the viewer can see how much is safely on disk.
     */
    fun downloadedUpToMs(): Long {
        return try {
            val url = currentUrl
            val length = lengths[url] ?: return 0L
            val duration = durationMs
            if (length <= 0 || duration <= 0) return 0L
            val bytesPerMs = length.toDouble() / duration
            val playedByte = (positionMs * bytesPerMs).toLong()
            val end = contiguousCachedEnd(url, playedByte, length)
            (end / bytesPerMs).toLong().coerceIn(0, duration)
        } catch (_: Exception) { 0L }
    }

    // ---- measurement ----

    /**
     * End of the run of cached bytes starting exactly at [from].
     *
     * getCachedLength reports the length of the cached block at that position when
     * data IS there, and a NEGATIVE hole size when it is not. Anything at or below
     * zero therefore means the run ends here - never "the rest must be present".
     * Reading this from the cache, at the playback offset, rather than from a
     * counter of what was fetched, is the correction that matters: the evictor can
     * take bytes back at any moment, and a file full of fragments elsewhere buys
     * a player reading forward nothing at all.
     */
    private fun contiguousCachedEnd(url: String, from: Long, length: Long): Long {
        var at = from.coerceIn(0, length)
        var guard = 0
        while (at < length && guard++ < 4096) {
            val span = try {
                app.videoCache.getCachedLength(url, at, length - at)
            } catch (_: Exception) { 0L }
            if (span <= 0) break
            at += span
        }
        return at
    }

    /**
     * The stretch of the current title that is on disk, as fractions of its full
     * length: from the point playback would start to the end of the contiguous
     * cached run. Drives the translucent "prefetched" segment on the page progress
     * bars, so the viewer can watch the download landing before pressing Play.
     * Null until the downloader has resolved the file length.
     */
    // Computed by the background pump each pass and read cheaply by the UI ticker.
    // The span walk touches the disk cache; doing it on the main thread every second
    // is what made the whole app feel sluggish, so the UI never walks the cache now.
    @Volatile private var spanFrom: Float = -1f
    @Volatile private var spanTo: Float = -1f

    fun prefetchedSpanFractions(): Pair<Float, Float>? {
        val f = spanFrom; val t = spanTo
        return if (f < 0f || t <= f) null else f to t
    }

    /** Refresh the cached span for the UI - called from the pump thread only. */
    private fun refreshSpanForUi() {
        val url = currentUrl
        val length = lengths[url] ?: -1L
        if (length <= 0) { spanFrom = -1f; spanTo = -1f; return }
        val from = playbackByte(length)
        val to = contiguousCachedEnd(url, from, length)
        if (to <= from) { spanFrom = -1f; spanTo = -1f }
        else { spanFrom = from.toFloat() / length; spanTo = to.toFloat() / length }
    }

    /**
     * How far [url] is downloaded from [fromFraction], as an end fraction of the
     * whole title - for progress bars on cards that are not the current title.
     * Cache-only (no network); null until a length is known for the url.
     */
    fun prefetchedEndFraction(url: String, fromFraction: Double): Float? = try {
        val length = knownLength(url)
        if (length <= 0) null else {
            val from = (length * fromFraction.coerceIn(0.0, 1.0)).toLong()
            val to = contiguousCachedEnd(url, from, length)
            if (to <= from) null else to.toFloat() / length
        }
    } catch (_: Exception) { null }

    private fun playbackByteOfCurrent(): Long {
        val length = lengths[currentUrl] ?: return 0L
        return playbackByte(length)
    }

    private fun playbackByte(length: Long): Long {
        val duration = durationMs
        val position = positionMs
        val fraction = if (duration > 0 && position > 0) position.toDouble() / duration
            else startFraction
        return (length * fraction).toLong().coerceIn(0, length)
    }

    private fun bytesPerSecond(length: Long): Long {
        val duration = durationMs
        if (duration > 60_000) {
            val rate = length / (duration / 1000)
            if (rate > 0) return rate
        }
        return ASSUMED_BYTES_PER_SECOND
    }

    /** Length of [url], preferring what the cache already recorded over a request. */
    private fun lengthOf(url: String): Long {
        lengths[url]?.let { if (it > 0) return it }
        val known = try {
            ContentMetadata.getContentLength(app.videoCache.getContentMetadata(url))
        } catch (_: Exception) { C.LENGTH_UNSET.toLong() }
        if (known > 0) { lengths[url] = known; return known }
        val measured = resolveLength(url)
        if (measured > 0) lengths[url] = measured
        return measured
    }

    /**
     * Ask the server how long the file is with a one-byte range.
     *
     * Opening the whole file and closing it straight away would be an abandoned
     * request, and those are what pin the single connection slot for minutes. A
     * one-byte range finishes, so the slot comes back in about a second.
     */
    private fun resolveLength(url: String): Long {
        val source = DefaultHttpDataSource.Factory()
            .setUserAgent(USER_AGENT)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(30_000)
            .setReadTimeoutMs(30_000)
            .createDataSource()
        return try {
            source.open(DataSpec.Builder().setUri(url).setPosition(0).setLength(1).build())
            val total = contentRangeTotal(source.responseHeaders)
            try { source.read(ByteArray(1), 0, 1) } catch (_: Exception) {}  // finish it cleanly
            clearBusy()
            total
        } catch (e: Exception) {
            if (isConnectionRefused(e)) waitOutBusyConnection()
            -1L
        } finally {
            try { source.close() } catch (_: Exception) {}
        }
    }

    /** "bytes 0-0/3489660928" -> 3489660928. */
    private fun contentRangeTotal(headers: Map<String, List<String>>): Long {
        for ((name, values) in headers) {
            if (!name.equals("Content-Range", ignoreCase = true)) continue
            val value = values.firstOrNull() ?: continue
            val total = value.substringAfterLast('/').trim().toLongOrNull()
            if (total != null && total > 0) return total
        }
        return -1L
    }

    // ---- space ----

    private fun cacheSpace(): Long = try { app.videoCache.cacheSpace } catch (_: Exception) { 0L }

    /** Spare bytes on the device beyond the floor we always leave free. */
    private fun roomBytes(): Long = try {
        (android.os.StatFs(app.cacheDir.path).availableBytes - KEEP_FREE_BYTES).coerceAtLeast(0)
    } catch (_: Exception) { 0L }

    /**
     * Take space back so the cushion can actually grow, and say whether there is
     * now somewhere to put it.
     *
     * First the other titles: stale bytes for something nobody is watching are
     * worth far less than a cushion for what is on screen, so the sweep runs
     * aggressively (ignoring the age limit) while protecting this title and the
     * next episode. If that yields nothing the cache holds little but this title,
     * and the only room left is behind the playhead - which is also the part the
     * evictor would NOT take, because playback keeps touching it while the cushion
     * ahead goes untouched and gets dropped instead.
     */
    private fun makeRoom(url: String, playedBytes: Long): Boolean {
        if (!evictionPressure && roomBytes() >= CHUNK_BYTES) return true
        evictionPressure = false
        var freed = sweepOtherTitles()
        if (freed < CHUNK_BYTES) freed += dropWatchedBytes(url, playedBytes)
        return freed >= CHUNK_BYTES || roomBytes() >= CHUNK_BYTES
    }

    private fun sweepOtherTitles(): Long {
        val before = cacheSpace()
        try {
            val protect = setOfNotNull(
                currentUrl.ifBlank { null },
                nextUrl.ifBlank { null },
                app.activeMediaUrl.ifBlank { null })
            app.cacheJanitor.sweep(protect = protect, aggressive = true)
        } catch (_: Exception) { return 0L }
        return (before - cacheSpace()).coerceAtLeast(0)
    }

    /** Drop this title's own bytes from well behind the playhead. */
    private fun dropWatchedBytes(url: String, playedBytes: Long): Long {
        val cutoff = playedBytes - KEEP_BEHIND_BYTES
        if (url.isBlank() || cutoff <= 0) return 0L
        var freed = 0L
        try {
            for (span in app.videoCache.getCachedSpans(url).toList()) {
                if (span.position + span.length > cutoff) continue
                val size = span.length
                try { app.videoCache.removeSpan(span); freed += size } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
        return freed
    }

    // ---- the single connection ----

    private fun isConnectionRefused(error: Throwable?): Boolean {
        var at = error
        var depth = 0
        while (at != null && depth++ < 8) {
            if (at is HttpDataSource.InvalidResponseCodeException &&
                at.responseCode == CONNECTION_LIMIT_CODE) return true
            at = at.cause
        }
        return false
    }

    private fun waitOutBusyConnection() {
        busyAttempts++
        val attempt = busyAttempts
        val banked = bankedSeconds
        try { listener?.onConnectionBusy(attempt, banked) } catch (_: Exception) {}
        sleep(BUSY_RETRY_MS)
    }

    private fun clearBusy() {
        if (busyAttempts == 0) return
        busyAttempts = 0
        try { listener?.onConnectionFree() } catch (_: Exception) {}
    }

    /** Idle, but come back at once if something happened while we were fetching
     *  (a seek, or an episode queued) - otherwise a ten-minute gap would swallow it. */
    private fun sleep(ms: Long) {
        val until = System.currentTimeMillis() + ms
        while (!cancelled && System.currentTimeMillis() < until) {
            if (wakeRequested) break
            try { Thread.sleep(250) } catch (_: InterruptedException) { return }
        }
        wakeRequested = false
    }
}
