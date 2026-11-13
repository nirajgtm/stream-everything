package com.nirajgtm.xtreamtv.data

import java.io.File

/**
 * How much you actually watch each streaming platform, used to order the home
 * rails (Netflix/Hulu/... rise as you use them).
 *
 * Scoring is an exponentially time-decayed play count rather than a running
 * counter, which gives the three properties we want:
 *
 *  - **No overflow.** Each play adds 1.0 to a `Double` that is continuously
 *    decayed toward zero, so the score settles around `plays-per-day / decay`
 *    instead of growing without bound. It is also hard-clamped.
 *  - **Adapts to changing taste.** A platform you hammered months ago decays
 *    away on its own ([halfLifeDays]); what you watch now rises.
 *  - **Not twitchy.** One play is a small nudge against an established score,
 *    and reordering needs a clear margin ([reorderMargin]), so the rails do not
 *    reshuffle just because of the single most recent thing you played.
 */
class PlatformAffinity(private val file: File) {

    private val halfLifeDays = 21.0          // a play is worth half as much 3 weeks later
    private val decayPerMs = Math.log(2.0) / (halfLifeDays * 24 * 60 * 60 * 1000)
    private val maxScore = 10_000.0          // hard clamp; normal use stays far below
    private val reorderMargin = 0.15         // hysteresis: ignore differences below this

    private class Entry(var score: Double, var updatedAt: Long)

    private val entries = HashMap<Int, Entry>()
    private var loaded = false

    @Synchronized
    private fun ensureLoaded() {
        if (loaded) return
        try {
            if (file.exists()) file.readLines().forEach { line ->
                val parts = line.split('\t')
                if (parts.size == 3) {
                    val key = parts[0].toIntOrNull()
                    val score = parts[1].toDoubleOrNull()
                    val at = parts[2].toLongOrNull()
                    if (key != null && score != null && at != null && score.isFinite())
                        entries[key] = Entry(score, at)
                }
            }
        } catch (_: Exception) {}
        loaded = true
    }

    @Synchronized
    private fun save() {
        try {
            file.writeText(entries.entries.joinToString("\n") {
                "${it.key}\t${it.value.score}\t${it.value.updatedAt}"
            })
        } catch (_: Exception) {}
    }

    /** Decay a stored score forward to [now] without touching the map. */
    private fun decayed(entry: Entry, now: Long): Double {
        val elapsed = (now - entry.updatedAt).coerceAtLeast(0)
        return entry.score * Math.exp(-decayPerMs * elapsed)
    }

    /** Count one play on [platformKey] (a [TmdbClient.Provider.key]). */
    @Synchronized
    fun recordPlay(platformKey: Int, now: Long = System.currentTimeMillis()) {
        if (platformKey <= 0) return
        ensureLoaded()
        val entry = entries.getOrPut(platformKey) { Entry(0.0, now) }
        entry.score = (decayed(entry, now) + 1.0).coerceAtMost(maxScore)
        entry.updatedAt = now
        save()
    }

    /** Current decayed score per platform (higher = watched more, more recently). */
    @Synchronized
    fun scores(now: Long = System.currentTimeMillis()): Map<Int, Double> {
        ensureLoaded()
        return entries.mapValues { decayed(it.value, now) }
    }

    /**
     * [items] reordered by affinity, most-watched first. Ties — and differences
     * too small to be meaningful — keep the original order, so the rails stay
     * stable until a real preference emerges.
     */
    fun <T> ordered(items: List<T>, now: Long = System.currentTimeMillis(), keyOf: (T) -> Int): List<T> {
        val scores = scores(now)
        if (scores.isEmpty()) return items
        return items.withIndex().sortedWith(compareBy(
            { -Math.floor((scores[keyOf(it.value)] ?: 0.0) / reorderMargin) }, // banded score
            { it.index }                                                       // stable within a band
        )).map { it.value }
    }
}
