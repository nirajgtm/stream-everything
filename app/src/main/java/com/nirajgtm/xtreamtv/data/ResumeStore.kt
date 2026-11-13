package com.nirajgtm.xtreamtv.data

import org.json.JSONObject
import java.io.File

/**
 * Remembers playback position (and enough metadata to render a Continue
 * Watching rail) per item, so titles resume where they were left. Backed by a
 * single JSON file, capped at [maxEntries] most-recently-played items.
 */
class ResumeStore(private val file: File, private val maxEntries: Int = 5000) {

    data class Mark(
        val positionMs: Long, val durationMs: Long, val updatedAt: Long,
        val title: String, val poster: String, val kind: String, val playUrl: String,
        // For episodes: enough to reopen the series list at the right spot.
        val seriesId: Long = 0, val seriesName: String = "", val season: Int = 0, val episodeNum: Int = 0,
        // "Up next" episode queued after finishing the previous one (position 0).
        val nextUp: Boolean = false
    )

    private val marks = HashMap<String, Mark>()
    private val plays = HashMap<String, Int>() // play counts (e.g. live channels)
    private val liveLangs = HashMap<String, Long>() // live language -> last watched ms
    private val favorites = LinkedHashSet<Long>() // favorited live channel ids (insertion order)
    private val navAccess = HashMap<String, Long>() // live nav item key -> last opened ms
    private var subtitleEnabled = false             // remembered subtitle on/off
    private var subtitleLang = ""                   // remembered subtitle language
    private val sourceOverrides = HashMap<String, String>() // title key -> "idnameext"
    private var loaded = false

    // Disk writes are coalesced onto a background thread so frequent updates
    // (e.g. bumpPlay on every channel zap) never serialize/write on the caller.
    private val ioExec = java.util.concurrent.Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "resume-io").apply { isDaemon = true }
    }
    @Volatile private var flushPending = false

    @Synchronized
    private fun ensureLoaded() {
        if (loaded) return
        loaded = true
        if (!file.exists()) return
        try {
            val root = JSONObject(file.readText())
            val items = root.optJSONObject("items")
            if (items != null) for (key in items.keys()) {
                val o = items.getJSONObject(key)
                marks[key] = Mark(
                    o.getLong("p"), o.getLong("d"), o.getLong("t"),
                    o.optString("title"), o.optString("poster"),
                    o.optString("kind"), o.optString("url"),
                    o.optLong("sid"), o.optString("sname"), o.optInt("sea"), o.optInt("epn"),
                    o.optBoolean("nu")
                )
            }
            val playObj = root.optJSONObject("plays")
            if (playObj != null) for (key in playObj.keys()) plays[key] = playObj.getInt(key)
            val langObj = root.optJSONObject("livelangs")
            if (langObj != null) for (key in langObj.keys()) liveLangs[key] = langObj.getLong(key)
            val favArr = root.optJSONArray("favs")
            if (favArr != null) for (i in 0 until favArr.length()) favorites.add(favArr.getLong(i))
            val navObj = root.optJSONObject("nav")
            if (navObj != null) for (key in navObj.keys()) navAccess[key] = navObj.getLong(key)
            subtitleEnabled = root.optBoolean("subOn", false)
            subtitleLang = root.optString("subLang", "")
            val srcObj = root.optJSONObject("src")
            if (srcObj != null) for (key in srcObj.keys()) sourceOverrides[key] = srcObj.getString(key)
        } catch (_: Exception) {
            marks.clear(); plays.clear(); liveLangs.clear(); favorites.clear(); navAccess.clear()
        }
    }

    /** Record that a live nav list (a language or a category) was opened. */
    @Synchronized
    fun touchNav(key: String, now: Long) { ensureLoaded(); navAccess[key] = now; persist() }

    /** nav key -> last-opened time, for ranking recently-used lists to the top. */
    @Synchronized
    fun navAccessTimes(): Map<String, Long> { ensureLoaded(); return HashMap(navAccess) }

    /** Remembered subtitle preference: (enabled, language) applied to every video. */
    @Synchronized
    fun subtitlePref(): Pair<Boolean, String> { ensureLoaded(); return subtitleEnabled to subtitleLang }

    @Synchronized
    fun setSubtitlePref(enabled: Boolean, lang: String) {
        ensureLoaded(); subtitleEnabled = enabled; subtitleLang = lang; persist()
    }

    data class SourceChoice(val id: Long, val name: String, val ext: String)

    /** Chosen source for a title key (id + name/ext so it applies without a scan). */
    @Synchronized
    fun sourceOverride(titleKey: String): SourceChoice? {
        ensureLoaded()
        val parts = (sourceOverrides[titleKey] ?: return null).split('\u0001')
        val id = parts.getOrNull(0)?.toLongOrNull() ?: return null
        return SourceChoice(id, parts.getOrNull(1) ?: "", parts.getOrNull(2) ?: "")
    }

    @Synchronized
    fun setSourceOverride(titleKey: String, entryId: Long, name: String, ext: String) {
        ensureLoaded(); sourceOverrides[titleKey] = "$entryId\u0001$name\u0001$ext"; persist()
    }

    /** Live-channel favorites (cross category/language). */
    @Synchronized
    fun isFavorite(channelId: Long): Boolean { ensureLoaded(); return channelId in favorites }

    /** Toggle a channel's favorite state; returns the new state. */
    @Synchronized
    fun toggleFavorite(channelId: Long): Boolean {
        ensureLoaded()
        val nowFav = if (channelId in favorites) { favorites.remove(channelId); false }
            else { favorites.add(channelId); true }
        persist()
        return nowFav
    }

    /** Favorited channel ids, in the order they were added. */
    @Synchronized
    fun favoriteIds(): List<Long> { ensureLoaded(); return favorites.toList() }

    /** Record that a live channel of [lang] was watched (drives the home tiles). */
    @Synchronized
    fun touchLiveLang(lang: String, now: Long) {
        ensureLoaded()
        if (lang.isBlank() || lang == "Other") return
        liveLangs[lang] = now
        persist()
    }

    /** Live languages the user has watched, most-recent first. */
    @Synchronized
    fun recentLiveLangs(limit: Int = 12): List<String> {
        ensureLoaded()
        return liveLangs.entries.sortedByDescending { it.value }.take(limit).map { it.key }
    }

    /** Hide a watched-language tile from the home rail (comes back if replayed). */
    @Synchronized
    fun removeLiveLang(lang: String) {
        ensureLoaded()
        if (liveLangs.remove(lang) != null) persist()
    }

    /** Record a play (e.g. a live channel) to rank frequently-played first.
     *  Diminishing returns keep counts bounded while preserving the ordering:
     *  full credit to 100, then ~1 per 10 plays, then ~1 per 100 — so a single
     *  channel can't run its count off to infinity. */
    @Synchronized
    fun bumpPlay(key: String) {
        ensureLoaded()
        val count = plays[key] ?: 0
        val inc = when {
            count < 100 -> 1
            count < 300 -> if (kotlin.random.Random.nextInt(10) == 0) 1 else 0
            else -> if (kotlin.random.Random.nextInt(100) == 0) 1 else 0
        }
        if (inc > 0) { plays[key] = count + inc; persist() }
    }

    @Synchronized
    fun playCount(key: String): Int {
        ensureLoaded()
        return plays[key] ?: 0
    }

    /** channelId -> play count for every live channel actually played (for ranking). */
    @Synchronized
    fun livePlayCounts(): Map<Long, Int> {
        ensureLoaded()
        val out = HashMap<Long, Int>()
        for ((key, count) in plays) if (key.startsWith("live:"))
            key.removePrefix("live:").toLongOrNull()?.let { out[it] = count }
        return out
    }

    /** Record what is about to play, so Continue Watching can show it. Stamps
     *  updatedAt NOW and persists: starting playback makes this the most recent
     *  item immediately (so replaying an older episode moves the resume suggestion
     *  to it), and it survives leaving before the first periodic position save. */
    @Synchronized
    fun remember(key: String, title: String, poster: String, kind: String, playUrl: String,
                 seriesId: Long = 0, seriesName: String = "", season: Int = 0, episodeNum: Int = 0) {
        ensureLoaded()
        val existing = marks[key]
        marks[key] = Mark(
            existing?.positionMs ?: 0, existing?.durationMs ?: 0,
            System.currentTimeMillis(), title, poster, kind, playUrl,
            seriesId, seriesName, season, episodeNum, existing?.nextUp ?: false
        )
        persist()
    }

    /** Queue the next episode into Continue Watching after finishing the previous. */
    @Synchronized
    fun rememberNextUp(key: String, title: String, poster: String, playUrl: String,
                       seriesId: Long, seriesName: String, season: Int, episodeNum: Int, now: Long) {
        ensureLoaded()
        val existing = marks[key]
        // Don't override an episode already in progress / already watched.
        if (existing != null && (existing.positionMs > 5_000 || existing.nextUp)) return
        marks[key] = Mark(0, 0, now, title, poster, "series", playUrl,
            seriesId, seriesName, season, episodeNum, nextUp = true)
        persist()
    }

    @Synchronized
    fun resumePosition(key: String): Long {
        ensureLoaded()
        val mark = marks[key] ?: return 0
        if (mark.durationMs > 0 && mark.positionMs > mark.durationMs - 15_000) return 0
        return mark.positionMs
    }

    @Synchronized
    fun hasResume(key: String): Boolean = resumePosition(key) > 5_000

    /** When this item was last played (0 if unknown) — for picking the current episode. */
    @Synchronized
    fun markUpdatedAt(key: String): Long { ensureLoaded(); return marks[key]?.updatedAt ?: 0 }

    /** True when under 2 minutes remain (i.e. suggest the next episode instead). */
    @Synchronized
    fun isNearlyFinished(key: String): Boolean {
        ensureLoaded()
        val m = marks[key] ?: return false
        return m.durationMs > 0 && m.positionMs > m.durationMs - 120_000
    }

    /** Fraction watched (0..1) for a progress bar; 0 if unknown or unwatched. */
    @Synchronized
    fun watchedFraction(key: String): Float {
        ensureLoaded()
        val m = marks[key] ?: return 0f
        if (m.durationMs <= 0) return 0f
        return (m.positionMs.toFloat() / m.durationMs).coerceIn(0f, 1f)
    }

    /** Continue Watching: in-progress items (newest first), excluding anything with
     *  under 2 minutes left; a finished episode is replaced by its queued next one. */
    @Synchronized
    fun recent(limit: Int = 20): List<Pair<String, Mark>> {
        ensureLoaded()
        return marks.entries
            .filter { (_, m) ->
                m.title.isNotBlank() && (m.nextUp ||
                    (m.positionMs > 5_000 && !nearlyFinished(m)))
            }
            .sortedByDescending { it.value.updatedAt }
            .take(limit)
            .map { it.key to it.value }
    }

    /** [recent], with all episodes of one series collapsed into a single card
     *  showing the most recently played episode (its progress bar and all). */
    @Synchronized
    fun recentCollapsed(limit: Int = 20): List<Pair<String, Mark>> {
        ensureLoaded()
        val seen = HashSet<Long>()
        return marks.entries
            .filter { (_, m) ->
                m.title.isNotBlank() && (m.nextUp ||
                    (m.positionMs > 5_000 && !nearlyFinished(m)))
            }
            .sortedByDescending { it.value.updatedAt } // newest first, so the kept
            .filter { (_, m) ->                        // episode is the latest played
                m.seriesId == 0L || seen.add(m.seriesId)
            }
            .take(limit)
            .map { it.key to it.value }
    }

    /** True when under 2 minutes remain (treated as finished). */
    private fun nearlyFinished(m: Mark) = m.durationMs > 0 && m.positionMs > m.durationMs - 120_000

    /** Forget one item (Continue Playing long-press remove). */
    @Synchronized
    fun remove(key: String) {
        ensureLoaded()
        if (marks.remove(key) != null) persist()
    }

    @Synchronized
    fun save(key: String, positionMs: Long, durationMs: Long, now: Long) {
        ensureLoaded()
        if (positionMs < 5_000) return
        val existing = marks[key]
        marks[key] = Mark(
            positionMs, durationMs, now,
            existing?.title ?: "", existing?.poster ?: "",
            existing?.kind ?: "", existing?.playUrl ?: "",
            existing?.seriesId ?: 0, existing?.seriesName ?: "",
            existing?.season ?: 0, existing?.episodeNum ?: 0,
            nextUp = false // now has real progress
        )
        if (marks.size > maxEntries) {
            marks.entries.sortedBy { it.value.updatedAt }
                .take(marks.size - maxEntries)
                .forEach { marks.remove(it.key) }
        }
        persist()
    }

    /** Force any pending changes to disk right now (call on exit for durability). */
    @Synchronized
    fun flushNow() {
        if (!loaded) return
        flushPending = false
        val json = buildJson()
        try {
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(json); file.delete()
            if (!tmp.renameTo(file)) { tmp.copyTo(file, overwrite = true); tmp.delete() }
        } catch (_: Exception) {}
    }

    /** Coalesce writes: schedule one background flush that snapshots latest state. */
    private fun persist() {
        if (flushPending) return
        flushPending = true
        try {
            ioExec.schedule({ flushToDisk() }, 400, java.util.concurrent.TimeUnit.MILLISECONDS)
        } catch (_: Exception) { flushPending = false; flushToDisk() }
    }

    private fun flushToDisk() {
        val json = synchronized(this) { flushPending = false; buildJson() }
        try {
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(json)
            file.delete()
            if (!tmp.renameTo(file)) { tmp.copyTo(file, overwrite = true); tmp.delete() }
        } catch (_: Exception) {}
    }

    /** Serialize the whole store to a JSON string (called under the lock). */
    private fun buildJson(): String {
        val items = JSONObject()
        for ((key, mark) in marks) {
            items.put(key, JSONObject()
                .put("p", mark.positionMs).put("d", mark.durationMs).put("t", mark.updatedAt)
                .put("title", mark.title).put("poster", mark.poster)
                .put("kind", mark.kind).put("url", mark.playUrl)
                .put("sid", mark.seriesId).put("sname", mark.seriesName)
                .put("sea", mark.season).put("epn", mark.episodeNum)
                .put("nu", mark.nextUp))
        }
        val playObj = JSONObject()
        for ((key, count) in plays) playObj.put(key, count)
        val langObj = JSONObject()
        for ((key, ts) in liveLangs) langObj.put(key, ts)
        val favArr = org.json.JSONArray()
        for (id in favorites) favArr.put(id)
        val navObj = JSONObject()
        for ((key, ts) in navAccess) navObj.put(key, ts)
        val srcObj = JSONObject()
        for ((key, value) in sourceOverrides) srcObj.put(key, value)
        return JSONObject().put("items", items).put("plays", playObj)
            .put("livelangs", langObj).put("favs", favArr).put("nav", navObj)
            .put("subOn", subtitleEnabled).put("subLang", subtitleLang)
            .put("src", srcObj).toString()
    }
}
