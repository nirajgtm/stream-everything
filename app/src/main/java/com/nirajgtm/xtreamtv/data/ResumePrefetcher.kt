package com.nirajgtm.xtreamtv.data

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import com.nirajgtm.xtreamtv.XtreamApp
import java.io.File
import java.util.Collections
import java.util.concurrent.Executors

/**
 * Warms the video cache with each recent item's file head (moov) plus a short
 * window at its saved resume point, so pressing Resume on a Continue Playing
 * item starts instantly. Bounds: top [topN] items, ~[windowMs] each (byte-capped),
 * a 24h TTL, and eviction of anything that drops out of the top N. Everything is
 * written into the same [XtreamApp.videoCache] that playback reads, under the
 * default cache key (the URL), so a warmed range is read straight from disk.
 */
@OptIn(UnstableApi::class)
class ResumePrefetcher(private val app: XtreamApp, private val metaFile: File) {

    data class Target(val url: String, val positionMs: Long, val durationMs: Long)

    private val topN = 8
    private val windowMs = 60_000L                     // ~1 min of cushion per item
    private val prerollMs = 15_000L                    // start the window this far BEFORE the saved
                                                       // point: playback resumes ~3s early and seeks
                                                       // to the nearest keyframe (a bit earlier still)
    private val headBytes = 2L * 1024 * 1024           // file head so the seek is instant
    private val tailBytes = 1L * 1024 * 1024           // MKV keeps its Cues seek index at the end;
                                                       // without it a seek costs a network round trip
    // Budget matters more than window length. Warming 8 items at 60 MB each is
    // ~480 MB of a 700 MB cache, so the prefetch evicts the very bytes it means to
    // protect — including the item you just watched. A few seconds of video is all
    // an instant start needs, so cap each item well below its share of the cache.
    private val maxWindowBytes = 12L * 1024 * 1024
    private val ttlMs = 24L * 60 * 60 * 1000            // 24h TTL

    private val exec = Executors.newSingleThreadExecutor { r ->
        Thread(r, "resume-prefetch").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }
    }
    @Volatile private var currentWriter: CacheWriter? = null
    @Volatile private var cancelled = false

    private class Warmed(val ts: Long, val pos: Long)

    // url -> (when warmed, resume position warmed for). Persisted so TTL + eviction
    // + drift detection survive restarts.
    private val warmedAt = Collections.synchronizedMap(LinkedHashMap<String, Warmed>())
    @Volatile private var loaded = false

    @Synchronized private fun ensureLoaded() {
        if (loaded) return
        try {
            if (metaFile.exists()) metaFile.readLines().forEach { line ->
                val parts = line.split('\t', limit = 3) // ts, pos, url
                if (parts.size == 3) {
                    val ts = parts[0].toLongOrNull(); val pos = parts[1].toLongOrNull()
                    if (ts != null && pos != null) warmedAt[parts[2]] = Warmed(ts, pos)
                }
            }
        } catch (_: Exception) {}
        loaded = true
    }

    @Synchronized private fun saveMeta() {
        try {
            metaFile.writeText(warmedAt.entries.joinToString("\n") { "${it.value.ts}\t${it.value.pos}\t${it.key}" })
        } catch (_: Exception) {}
    }

    /** Reconcile the warm cache to the top of [allTargets] (already recency-sorted).
     *  Cheap and idempotent when nothing has changed. */
    fun sync(allTargets: List<Target>) {
        ensureLoaded()
        cancelled = false
        val targets = allTargets.take(topN)
        val wanted = targets.map { it.url }.toSet()
        val now = System.currentTimeMillis()
        // Evict anything that fell out of the top N or aged past the TTL.
        synchronized(warmedAt) {
            warmedAt.entries.toList().forEach { (url, w) ->
                if (url !in wanted || now - w.ts > ttlMs) {
                    try { app.videoCache.removeResource(url) } catch (_: Exception) {}
                    warmedAt.remove(url)
                }
            }
        }
        saveMeta()
        exec.execute {
            for (t in targets) {
                if (cancelled) break
                val w = warmedAt[t.url]
                // Skip only if still warm AND the saved point hasn't drifted past the window.
                if (w != null && Math.abs(t.positionMs - w.pos) <= windowMs) continue
                try {
                    if (w != null) try { app.videoCache.removeResource(t.url) } catch (_: Exception) {} // stale window
                    warmOne(t)
                    if (!cancelled) { warmedAt[t.url] = Warmed(System.currentTimeMillis(), t.positionMs); saveMeta() }
                } catch (_: Exception) {}
            }
        }
    }

    /** Record that playback has already written this item to disk at [positionMs]
     *  (the player caches through the same [XtreamApp.videoCache]). The home warm-up
     *  then treats it as fresh and won't re-fetch it, so a quick back-and-return is
     *  instant. */
    fun markWarmed(url: String, positionMs: Long) {
        if (url.isBlank()) return
        ensureLoaded()
        warmedAt[url] = Warmed(System.currentTimeMillis(), positionMs)
        saveMeta()
    }

    /** Stop in-flight warming (call when leaving home to actually play something,
     *  so the active stream gets all the bandwidth). */
    fun pause() {
        cancelled = true
        try { currentWriter?.cancel() } catch (_: Exception) {}
    }

    private fun warmOne(t: Target) {
        cacheRange(t.url, 0, headBytes) // container header -> instant open
        if (cancelled) return
        if (t.positionMs > 0 && t.durationMs > 0) {
            val length = resolveLength(t.url)
            if (length > 0) {
                // These are .mkv: Matroska stores its Cues (the seek index) at the END
                // of the file, so seeking to a resume point reads the tail. Without it
                // cached, every resume pays a network round trip before the first frame.
                cacheRange(t.url, (length - tailBytes).coerceAtLeast(0), tailBytes)
                if (cancelled) return
                val bytesPerMs = length.toDouble() / t.durationMs
                // Begin a little before the saved point to cover the 3s resume pre-roll
                // and the keyframe ExoPlayer actually seeks back to.
                val startMs = (t.positionMs - prerollMs).coerceAtLeast(0)
                val start = (startMs * bytesPerMs).toLong().coerceIn(0, length - 1)
                val window = minOf(maxWindowBytes, ((prerollMs + windowMs) * bytesPerMs).toLong(), length - start)
                if (window > 0) cacheRange(t.url, start, window)
            }
        } else {
            cacheRange(t.url, 0, maxWindowBytes) // "Up next" (position 0): warm from the start
        }
    }

    private fun cacheRange(url: String, pos: Long, len: Long) {
        val ds = CacheDataSource.Factory()
            .setCache(app.videoCache)
            .setUpstreamDataSourceFactory(DefaultHttpDataSource.Factory())
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
            .createDataSource()
        val spec = DataSpec.Builder().setUri(url).setPosition(pos).setLength(len).build()
        val writer = CacheWriter(ds, spec, null, null)
        currentWriter = writer
        try { writer.cache() } finally { currentWriter = null }
    }

    /** Total content length via a quick open at position 0 (headers only, no body read). */
    private fun resolveLength(url: String): Long {
        val ds = DefaultHttpDataSource.Factory().createDataSource()
        return try {
            val len = ds.open(DataSpec.Builder().setUri(url).build())
            if (len == C.LENGTH_UNSET.toLong()) -1 else len
        } catch (_: Exception) { -1 } finally { try { ds.close() } catch (_: Exception) {} }
    }
}
