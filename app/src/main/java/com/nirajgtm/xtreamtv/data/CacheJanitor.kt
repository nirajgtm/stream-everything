package com.nirajgtm.xtreamtv.data

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.cache.SimpleCache
import java.io.File

/**
 * Keeps the video cache from quietly consuming the device.
 *
 * LRU eviction alone only reacts to the size cap, so cached video from titles
 * watched hours ago sits on disk until something else needs the room. On a box
 * with ~4 GB of user storage that is the difference between a healthy device and
 * a full one, so anything untouched for [ttlMs] is dropped, and the cache is also
 * trimmed whenever free space runs low regardless of age.
 */
@OptIn(UnstableApi::class)
class CacheJanitor(
    private val cache: SimpleCache,
    private val cacheDir: File,
    private val ttlMs: Long = 2 * 60 * 60 * 1000L,   // 2 hours
    private val keepFreeBytes: Long = 500L * 1024 * 1024
) {

    /**
     * Drop stale entries, then more if the device is still short on space.
     *
     * [protect] is never touched - typically the title on screen or paused. Its
     * bytes are exactly what makes resuming instant, and deleting them because a
     * timer expired while someone was paused would be the worst possible moment.
     */
    fun sweep(protect: Set<String> = emptySet(), aggressive: Boolean = false) {
        try {
            val now = System.currentTimeMillis()
            val byAge = ArrayList<Pair<String, Long>>()   // key -> last touched
            for (key in cache.keys.toList()) {
                if (key in protect) continue
                val spans = try { cache.getCachedSpans(key) } catch (_: Exception) { emptySet() }
                if (spans.isEmpty()) continue
                val touched = spans.maxOf { it.lastTouchTimestamp }
                // Aggressive: the title being watched needs the room now, so age
                // does not matter - anything else is fair game.
                if (aggressive || now - touched > ttlMs) {
                    remove(key)
                } else {
                    byAge.add(key to touched)
                }
            }
            // Still tight? Drop the oldest survivors until there is breathing room.
            byAge.sortBy { it.second }
            var index = 0
            while (index < byAge.size && freeBytes() < keepFreeBytes) {
                if (byAge[index].first in protect) { index++; continue }
                remove(byAge[index].first)
                index++
            }
        } catch (_: Exception) {
            // Housekeeping must never break playback.
        }
    }

    private fun remove(key: String) {
        try { cache.removeResource(key) } catch (_: Exception) {}
    }

    private fun freeBytes(): Long = try {
        android.os.StatFs(cacheDir.path).availableBytes
    } catch (_: Exception) { Long.MAX_VALUE }
}
