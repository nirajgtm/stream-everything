package com.nirajgtm.xtreamtv.data

import com.nirajgtm.xtreamtv.BuildConfig
import com.google.gson.JsonParser
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** One trending title from TMDB, tagged with the streaming services that carry it. */
data class TmdbItem(
    val tmdbId: Int,
    val title: String,
    val year: String,
    val posterUrl: String,
    val overview: String,
    val isSeries: Boolean,
    val popularity: Double,
    val providerIds: Set<Int> = emptySet()
)

/**
 * TMDB reader for the home page. Everything is built from today's TRENDING list;
 * each trending title is tagged with the US streaming services that carry it, so
 * a provider rail is literally "what's trending today, on that service." Cached
 * on disk with a TTL to stay under the rate limit.
 */
class TmdbClient(private val cacheDir: File) {

    private val key = BuildConfig.TMDB_KEY
    val configured: Boolean get() = key.isNotBlank()

    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    private val imageBase = "https://image.tmdb.org/t/p/w342"
    private val ttlMs = TimeUnit.HOURS.toMillis(6)
    private val trendingPages = 4

    // Providers in rough popularity order. `ids` lists every TMDB watch-provider
    // id for the service (TMDB often splits one service into several).
    // watchmodeId = Watchmode source id (0 if unknown -> keeps TMDB ordering).
    data class Provider(val label: String, val ids: List<Int>, val watchmodeId: Int = 0) {
        val key get() = ids.first()
        val query get() = ids.joinToString("|")
    }
    val providers = listOf(
        Provider("Netflix", listOf(8), 203),
        Provider("Prime Video", listOf(9, 119), 26),
        Provider("Disney+", listOf(337), 372),
        Provider("Max", listOf(1899, 384), 387),
        Provider("Hulu", listOf(15), 157),
        Provider("Apple TV+", listOf(350), 371),
        Provider("Peacock", listOf(386, 387), 388),
        Provider("Paramount+", listOf(531, 2303, 2616), 444),
        Provider("Starz", listOf(43), 232),
        Provider("AMC+", listOf(526), 0),
        Provider("Crunchyroll", listOf(283), 80),
        Provider("Discovery+", listOf(520), 0),
        Provider("MGM+", listOf(34), 108),
        Provider("BritBox", listOf(151), 419),
        Provider("Tubi", listOf(73), 296),
        Provider("Pluto TV", listOf(300), 0),
        Provider("The Roku Channel", listOf(207), 452),
        Provider("Freevee", listOf(613), 365),
        Provider("Fubo", listOf(257), 0)
    )

    private fun cachedGet(cacheKey: String, path: String, params: String): String {
        val file = File(cacheDir, "tmdb_$cacheKey.json")
        if (file.exists() && System.currentTimeMillis() - file.lastModified() < ttlMs) {
            try { return file.readText() } catch (_: Exception) {}
        }
        // Build with a URL builder so values like "531|2303|2616" get encoded
        // properly (a raw "|" truncates the query in OkHttp).
        val builder = okhttp3.HttpUrl.Builder()
            .scheme("https").host("api.themoviedb.org")
            .addPathSegments("3/$path")
            .addQueryParameter("api_key", key)
        for (pair in params.split("&")) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            if (eq < 0) builder.addQueryParameter(pair, "")
            else builder.addQueryParameter(pair.substring(0, eq), pair.substring(eq + 1))
        }
        val body = http.newCall(Request.Builder().url(builder.build()).build()).execute().use { response ->
            if (!response.isSuccessful) error("TMDB HTTP ${response.code}")
            response.body!!.string()
        }
        try { file.writeText(body) } catch (_: Exception) {}
        return body
    }

    private fun parseResults(body: String): List<TmdbItem> {
        val results = JsonParser.parseString(body).asJsonObject
            .getAsJsonArray("results") ?: return emptyList()
        val out = ArrayList<TmdbItem>()
        for (el in results) {
            val o = el.asJsonObject
            fun s(k: String) = o.get(k)?.takeIf { it.isJsonPrimitive }?.asString ?: ""
            fun d(k: String) = o.get(k)?.takeIf { it.isJsonPrimitive }?.asDouble ?: 0.0
            fun i(k: String) = o.get(k)?.takeIf { it.isJsonPrimitive }?.asInt ?: 0
            val isSeries = s("media_type") == "tv" || o.has("first_air_date")
            val title = s("title").ifEmpty { s("name") }
            val date = s("release_date").ifEmpty { s("first_air_date") }
            val poster = s("poster_path")
            if (title.isBlank() || poster.isBlank() || i("id") == 0) continue
            out.add(TmdbItem(i("id"), title, date.take(4), imageBase + poster, s("overview"),
                isSeries, d("popularity")))
        }
        return out
    }

    /** US streaming services (flatrate/free/ads) that carry a title. Cached per title. */
    private fun providersForTitle(item: TmdbItem): Set<Int> {
        val type = if (item.isSeries) "tv" else "movie"
        val body = try {
            cachedGet("wp_${type}_${item.tmdbId}", "$type/${item.tmdbId}/watch/providers", "")
        } catch (_: Exception) { return emptySet() }
        return try {
            val us = JsonParser.parseString(body).asJsonObject
                .getAsJsonObject("results")?.getAsJsonObject("US") ?: return emptySet()
            val ids = HashSet<Int>()
            for (bucket in listOf("flatrate", "free", "ads")) {
                us.getAsJsonArray(bucket)?.forEach {
                    it.asJsonObject.get("provider_id")?.asInt?.let { id -> ids.add(id) }
                }
            }
            ids
        } catch (_: Exception) { emptySet() }
    }

    /** Today's trending titles, each tagged with the services that carry it. */
    fun trendingWithProviders(): List<TmdbItem> {
        val items = ArrayList<TmdbItem>()
        for (page in 1..trendingPages) {
            items += parseResults(cachedGet("trending_day_$page", "trending/all/day",
                "language=en-US&page=$page"))
        }
        val pool = Executors.newFixedThreadPool(8,
            com.nirajgtm.xtreamtv.util.Threads.lowPriorityFactory("tmdb-providers"))
        val tagged = try {
            items.map { item -> pool.submit<TmdbItem> { item.copy(providerIds = providersForTitle(item)) } }
                .map { it.get() }
        } finally { pool.shutdown() }
        return tagged
    }

    /** Whether a trending item is available on the given provider. */
    fun onProvider(item: TmdbItem, provider: Provider): Boolean =
        item.providerIds.any { it in provider.ids }

    /** Date ~4 months ago (YYYY-MM-DD) for the "recent" padding window. */
    private fun recentCutoff(): String {
        val cal = java.util.Calendar.getInstance()
        cal.add(java.util.Calendar.DAY_OF_YEAR, -120)
        return String.format("%tF", cal)
    }

    private fun discover(cacheKey: String, type: String, extra: String): List<TmdbItem> = try {
        parseResults(cachedGet(cacheKey, "discover/$type", "watch_region=US&language=en-US&$extra"))
    } catch (_: Exception) { emptyList() }

    private fun today(): String = String.format("%tF", java.util.Calendar.getInstance())

    /**
     * A provider's titles to pad a thin trending rail up to a full row. Recent
     * releases/airings (last ~4 months) come first so current-season originals
     * surface; general popularity fills any remainder.
     */
    fun popularOn(provider: Provider): List<TmdbItem> {
        val cutoff = recentCutoff()
        val recent = ArrayList<TmdbItem>()
        val general = ArrayList<TmdbItem>()
        // One call per id (no pipe-joined ids, which OkHttp mangles).
        for (id in provider.ids) {
            val p = "sort_by=popularity.desc&with_watch_providers=$id&vote_count.gte=15"
            recent += discover("p${id}_movie_recent", "movie", "$p&primary_release_date.gte=$cutoff")
            recent += discover("p${id}_tv_recent", "tv", "$p&air_date.gte=$cutoff")
            general += discover("p${id}_movie", "movie", p)
            general += discover("p${id}_tv", "tv", p)
        }
        recent.sortByDescending { it.popularity }
        general.sortByDescending { it.popularity }
        return (recent + general).distinctBy { it.tmdbId }
    }

    // ---- Provider hub ----

    // watchmodeId maps to Watchmode's genre id (0 = no mapping -> keep TMDB order).
    data class Genre(val label: String, val movieId: Int?, val tvId: Int?, val watchmodeId: Int = 0)
    val genres = listOf(
        Genre("Action", 28, 10759, 1), Genre("Comedy", 35, 35, 4), Genre("Drama", 18, 18, 7),
        Genre("Sci-Fi & Fantasy", 878, 10765, 40), Genre("Thriller", 53, null, 17),
        Genre("Horror", 27, null, 11), Genre("Romance", 10749, null, 14),
        Genre("Documentary", 99, 99, 6), Genre("Animation", 16, 16, 3),
        Genre("Kids & Family", 10751, 10762, 8)
    )

    /** Merge one discover query across all of a provider's ids and both types. */
    private fun railFor(provider: Provider, suffix: String, movieExtra: String?, tvExtra: String?): List<TmdbItem> {
        val out = ArrayList<TmdbItem>()
        for (id in provider.ids) {
            val wp = "with_watch_providers=$id"
            if (movieExtra != null) out += discover("h${id}_${suffix}_m", "movie", "$wp&$movieExtra")
            if (tvExtra != null) out += discover("h${id}_${suffix}_t", "tv", "$wp&$tvExtra")
        }
        return out.sortedByDescending { it.popularity }.distinctBy { it.tmdbId }
    }

    fun newOn(provider: Provider): List<TmdbItem> = railFor(provider, "new",
        "sort_by=primary_release_date.desc&primary_release_date.lte=${today()}&vote_count.gte=20",
        "sort_by=first_air_date.desc&first_air_date.lte=${today()}&vote_count.gte=20")

    fun popularMovies(provider: Provider): List<TmdbItem> = railFor(provider, "popmov",
        "sort_by=popularity.desc&vote_count.gte=15", null)

    fun popularShows(provider: Provider): List<TmdbItem> = railFor(provider, "poptv",
        null, "sort_by=popularity.desc&vote_count.gte=15")

    fun topRated(provider: Provider): List<TmdbItem> = railFor(provider, "top",
        "sort_by=vote_average.desc&vote_count.gte=300", "sort_by=vote_average.desc&vote_count.gte=200")

    fun byGenre(provider: Provider, genre: Genre): List<TmdbItem> = railFor(provider, "g${genre.movieId ?: genre.tvId}",
        genre.movieId?.let { "sort_by=popularity.desc&with_genres=$it&vote_count.gte=15" },
        genre.tvId?.let { "sort_by=popularity.desc&with_genres=$it&vote_count.gte=15" })

    // ---- Provider logos (official, from TMDB) ----

    @Volatile private var logoMap: Map<Int, String>? = null

    @Synchronized private fun ensureLogos() {
        if (logoMap != null) return
        val map = HashMap<Int, String>()
        try {
            val results = JsonParser.parseString(cachedGet("providers_movie", "watch/providers/movie", "watch_region=US"))
                .asJsonObject.getAsJsonArray("results")
            for (el in results) {
                val o = el.asJsonObject
                val id = o.get("provider_id")?.asInt ?: continue
                val path = o.get("logo_path")?.takeIf { it.isJsonPrimitive }?.asString ?: continue
                map[id] = path
            }
        } catch (_: Exception) {}
        logoMap = map
    }

    /** Top-billed cast names for a title (for the hover preview). Cached. */
    fun castFor(tmdbId: Int, isSeries: Boolean): String {
        if (tmdbId == 0) return ""
        val type = if (isSeries) "tv" else "movie"
        return try {
            val body = cachedGet("credits_${type}_$tmdbId", "$type/$tmdbId/credits", "language=en-US")
            val cast = JsonParser.parseString(body).asJsonObject.getAsJsonArray("cast") ?: return ""
            (0 until minOf(4, cast.size())).mapNotNull {
                cast[it].asJsonObject.get("name")?.takeIf { n -> n.isJsonPrimitive }?.asString
            }.joinToString(", ")
        } catch (_: Exception) { "" }
    }

    data class EpisodeMeta(val name: String, val overview: String, val still: String, val runtimeMin: Int)

    /** Real episode names/overviews/stills for a season (matched by episode number). */
    fun seasonEpisodes(tmdbId: Int, season: Int): Map<Int, EpisodeMeta> {
        if (tmdbId == 0) return emptyMap()
        return try {
            val body = cachedGet("tv_${tmdbId}_s$season", "tv/$tmdbId/season/$season", "language=en-US")
            val eps = JsonParser.parseString(body).asJsonObject.getAsJsonArray("episodes") ?: return emptyMap()
            val out = HashMap<Int, EpisodeMeta>()
            for (el in eps) {
                val o = el.asJsonObject
                fun s(k: String) = o.get(k)?.takeIf { it.isJsonPrimitive }?.asString ?: ""
                val num = o.get("episode_number")?.takeIf { it.isJsonPrimitive }?.asInt ?: continue
                val still = s("still_path")
                out[num] = EpisodeMeta(s("name"), s("overview"),
                    // w780: episode cards render ~340px wide and scale up on focus,
                    // so w300 looked soft on a 1080p TV.
                    if (still.isNotBlank()) "https://image.tmdb.org/t/p/w780$still" else "",
                    o.get("runtime")?.takeIf { it.isJsonPrimitive }?.asInt ?: 0)
            }
            out
        } catch (_: Exception) { emptyMap() }
    }

    data class CastMember(val name: String, val character: String, val profileUrl: String)

    /** Top cast with headshots (for an Apple TV-style cast row). */
    fun castWithImages(tmdbId: Int, isSeries: Boolean, limit: Int = 12): List<CastMember> {
        if (tmdbId == 0) return emptyList()
        val type = if (isSeries) "tv" else "movie"
        return try {
            val body = cachedGet("credits_${type}_$tmdbId", "$type/$tmdbId/credits", "language=en-US")
            val cast = JsonParser.parseString(body).asJsonObject.getAsJsonArray("cast") ?: return emptyList()
            (0 until minOf(limit, cast.size())).mapNotNull {
                val o = cast[it].asJsonObject
                val name = o.get("name")?.takeIf { n -> n.isJsonPrimitive }?.asString ?: return@mapNotNull null
                val character = o.get("character")?.takeIf { n -> n.isJsonPrimitive }?.asString ?: ""
                val path = o.get("profile_path")?.takeIf { n -> n.isJsonPrimitive }?.asString ?: ""
                CastMember(name, character, if (path.isNotBlank()) "https://image.tmdb.org/t/p/w185$path" else "")
            }
        } catch (_: Exception) { emptyList() }
    }

    fun providerLogoUrl(provider: Provider): String? {
        ensureLogos()
        val path = provider.ids.firstNotNullOfOrNull { logoMap?.get(it) } ?: return null
        return "https://image.tmdb.org/t/p/w300$path"
    }
}
