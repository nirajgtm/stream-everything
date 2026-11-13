package com.nirajgtm.xtreamtv.data

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** One resolved card in a saved rail (display text + how to open it). */
data class CardData(
    val display: String, val name: String, val kind: Int,
    val id: Long, val ext: String, val poster: String,
    val overview: String = "", val tmdbId: Int = 0, val year: String = ""
)

/** One saved rail. providerKey = -1 for non-provider rails (e.g. Trending). */
data class RailData(
    val title: String, val providerKey: Int, val logoUrl: String, val cards: List<CardData>
)

data class HomeSnapshot(val savedAt: Long, val rails: List<RailData>)

/**
 * Persists the home rails so the app opens to the last-known state instantly,
 * then refreshes in the background when the snapshot is older than the TTL.
 */
class HomeCache(private val file: File) {

    fun age(now: Long): Long {
        val snap = load() ?: return Long.MAX_VALUE
        return now - snap.savedAt
    }

    fun load(): HomeSnapshot? {
        if (!file.exists()) return null
        return try {
            val root = JSONObject(file.readText())
            val rails = root.getJSONArray("rails").let { arr ->
                (0 until arr.length()).map { i ->
                    val r = arr.getJSONObject(i)
                    val cards = r.getJSONArray("cards").let { ca ->
                        (0 until ca.length()).map { j ->
                            val c = ca.getJSONObject(j)
                            CardData(c.getString("d"), c.getString("n"), c.getInt("k"),
                                c.getLong("i"), c.getString("e"), c.getString("p"),
                                c.optString("o"), c.optInt("tid"), c.optString("y"))
                        }
                    }
                    RailData(r.getString("t"), r.optInt("pk", -1), r.optString("lu", ""), cards)
                }
            }
            HomeSnapshot(root.getLong("savedAt"), rails)
        } catch (_: Exception) { null }
    }

    fun save(snapshot: HomeSnapshot) {
        try {
            val rails = JSONArray()
            for (r in snapshot.rails) {
                val cards = JSONArray()
                for (c in r.cards) {
                    cards.put(JSONObject().put("d", c.display).put("n", c.name)
                        .put("k", c.kind).put("i", c.id).put("e", c.ext).put("p", c.poster)
                        .put("o", c.overview).put("tid", c.tmdbId).put("y", c.year))
                }
                rails.put(JSONObject().put("t", r.title).put("pk", r.providerKey)
                    .put("lu", r.logoUrl).put("cards", cards))
            }
            val root = JSONObject().put("savedAt", snapshot.savedAt).put("rails", rails)
            val tmp = File(file.parentFile, file.name + ".tmp")
            tmp.writeText(root.toString())
            file.delete()
            if (!tmp.renameTo(file)) { tmp.copyTo(file, overwrite = true); tmp.delete() }
        } catch (_: Exception) {}
    }
}
