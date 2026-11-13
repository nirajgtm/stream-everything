package com.nirajgtm.xtreamtv.data

import com.nirajgtm.xtreamtv.BuildConfig
import com.google.gson.JsonParser
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Watchmode reader used to reorder provider rails by accurate per-service
 * popularity (JustWatch-based). Free tier is 2500 requests/month, so responses
 * are cached 24h (nothing fetched twice a day) and a monthly budget guard stops
 * calling well before the cap — callers then fall back to TMDB.
 */
class WatchmodeClient(private val cacheDir: File) {

    private val key = BuildConfig.WATCHMODE_KEY
    val configured: Boolean get() = key.isNotBlank()

    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS).build()

    private val ttlMs = TimeUnit.HOURS.toMillis(24)
    private val monthlyCap = 2200 // leave headroom under the 2500 quota
    private val budgetFile = File(cacheDir, "watchmode_budget.json")

    @Synchronized
    private fun withinBudget(): Boolean {
        val month = java.util.Calendar.getInstance().let { "${it.get(java.util.Calendar.YEAR)}-${it.get(java.util.Calendar.MONTH)}" }
        return try {
            val o = if (budgetFile.exists()) JSONObject(budgetFile.readText()) else JSONObject()
            if (o.optString("month") != month) return true // new month, reset implicitly
            o.optInt("count") < monthlyCap
        } catch (_: Exception) { true }
    }

    @Synchronized
    private fun recordCall() {
        val month = java.util.Calendar.getInstance().let { "${it.get(java.util.Calendar.YEAR)}-${it.get(java.util.Calendar.MONTH)}" }
        try {
            val o = if (budgetFile.exists()) JSONObject(budgetFile.readText()) else JSONObject()
            val count = if (o.optString("month") == month) o.optInt("count") else 0
            budgetFile.writeText(JSONObject().put("month", month).put("count", count + 1).toString())
        } catch (_: Exception) {}
    }

    /** Popular-order ranks for a source (home rail + hub Popular Movies/Shows). */
    fun popularRanks(sourceId: Int): Map<Int, Int> =
        ranks("src_$sourceId", sourceId, "types=movie,tv_series&sort_by=popularity_desc")

    /** Newest-first ranks for a source (hub "New on X"). */
    fun newRanks(sourceId: Int): Map<Int, Int> =
        ranks("new_$sourceId", sourceId, "types=movie,tv_series&sort_by=release_date_desc")

    /** Popular ranks within a genre on a source (hub genre rows). */
    fun genreRanks(sourceId: Int, watchmodeGenreId: Int): Map<Int, Int> {
        if (watchmodeGenreId == 0) return emptyMap()
        return ranks("g${watchmodeGenreId}_$sourceId", sourceId,
            "types=movie,tv_series&genres=$watchmodeGenreId&sort_by=popularity_desc")
    }

    /**
     * tmdbId -> rank (0 = first) from a Watchmode list-titles query. Cached 24h
     * on disk; empty on any error, missing key, or exhausted monthly budget, so
     * callers keep TMDB ordering.
     */
    private fun ranks(cacheKey: String, sourceId: Int, params: String): Map<Int, Int> {
        if (!configured || sourceId == 0) return emptyMap()
        val file = File(cacheDir, "wm_$cacheKey.json")
        val fresh = file.exists() && System.currentTimeMillis() - file.lastModified() < ttlMs
        val body: String = if (fresh) {
            try { file.readText() } catch (_: Exception) { return emptyMap() }
        } else {
            if (!withinBudget()) return emptyMap()
            val url = "https://api.watchmode.com/v1/list-titles/?apiKey=$key" +
                "&source_ids=$sourceId&regions=US&limit=50&$params"
            try {
                val fetched = http.newCall(Request.Builder().url(url).build()).execute().use { r ->
                    if (!r.isSuccessful) return emptyMap()
                    r.body!!.string()
                }
                recordCall()
                try { file.writeText(fetched) } catch (_: Exception) {}
                fetched
            } catch (_: Exception) { return emptyMap() }
        }
        return try {
            val titles = JsonParser.parseString(body).asJsonObject.getAsJsonArray("titles") ?: return emptyMap()
            val out = HashMap<Int, Int>()
            var rank = 0
            for (el in titles) {
                val id = el.asJsonObject.get("tmdb_id")?.takeIf { it.isJsonPrimitive && !it.isJsonNull }?.asInt ?: continue
                if (!out.containsKey(id)) out[id] = rank++
            }
            out
        } catch (_: Exception) { emptyMap() }
    }
}
