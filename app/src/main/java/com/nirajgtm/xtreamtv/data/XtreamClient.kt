package com.nirajgtm.xtreamtv.data

import android.content.Context
import android.util.JsonReader
import android.util.JsonToken
import android.util.Log
import com.nirajgtm.xtreamtv.BuildConfig
import com.google.gson.JsonParser
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.io.FileReader
import java.util.concurrent.TimeUnit

data class Entry(
    val name: String, val id: Long, val ext: String = "",
    // Live-channel metadata (empty/0 for movies and series).
    val logo: String = "", val epgId: String = "", val archive: Int = 0,
    // Derived from [name]. They are constructor parameters so the disk cache can
    // hand back stored values: deriving them again for ~300k entries on every cold
    // start (accent stripping + the adult rules) took over half a minute.
    /** Lowercase, no spaces/punctuation/accents: "The Back-Rooms" -> "thebackrooms". */
    val norm: String = normalizeForSearch(name),
    /** Language/region code from a title prefix like "EN - " or "DE|", null if none. */
    val lang: String? = detectLang(name),
    /** Whether this title is hidden by the adult filter. */
    val adult: Boolean = AdultFilter.isAdult(name)
) {
    /** Cleaned display title. Computed on access: it is only read when a row is drawn. */
    val clean: String get() = TitleParser.parse(name).clean
}

private const val TAG = "XtreamClient"

private val combiningMarks = Regex("\\p{Mn}+")
private val langPrefix = Regex("^\\s*([A-Za-z]{2,3})\\s*[-|:]")

fun detectLang(name: String): String? =
    langPrefix.find(name)?.groupValues?.get(1)?.uppercase()

/** Title without its language prefix: "EN - Batman (2026)" -> "Batman (2026)". */
fun displayTitle(name: String): String =
    langPrefix.find(name)?.let { name.removeRange(it.range).trim() } ?: name

private val seasonEpisodeTag = Regex("(?i)\\b(s\\d{1,2}\\s*[.x-]?\\s*e\\d{1,3}|\\d{1,2}x\\d{1,3})\\b")

/** Episode title without redundant "S01E01"-style tags (already parsed into fields). */
fun cleanEpisodeTitle(title: String): String =
    seasonEpisodeTag.replace(title, " ")
        .replace(Regex("\\s{2,}"), " ")
        .trim(' ', '-', ':', '|', '.', '·', '–')

private val stopwords = setOf("the", "a", "an")

/**
 * Query words minus stopwords ("The backroom" matches like "backroom"), but
 * the stopword-included form still ranks exact titles first. If the query is
 * ONLY stopwords, they are kept as real tokens.
 */
class ParsedQuery(query: String) {
    private val allTokens = query.trim().split(Regex("\\s+"))
        .map { normalizeForSearch(it) }.filter { it.isNotEmpty() }
    val tokens: List<String> = allTokens.filterNot { it in stopwords }.ifEmpty { allTokens }
    /** All words joined, stopwords included: "thebackroom". */
    val whole: String = allTokens.joinToString("")
    /** Meaningful words joined: "backroom". */
    val core: String = tokens.joinToString("")
    val valid: Boolean = core.length >= 2

    fun matches(entry: Entry): Boolean = tokens.all { entry.norm.contains(it) }

    /** 0 = contains query verbatim, 1 = contains meaningful words joined, 2 = scattered words. */
    fun rank(entry: Entry): Int = when {
        entry.norm.contains(whole) -> 0
        entry.norm.contains(core) -> 1
        else -> 2
    }
}

fun normalizeForSearch(text: String): String {
    // Fast path: pure-ASCII titles skip the expensive Unicode decomposition.
    val isAscii = text.all { it.code < 128 }
    val base = if (isAscii) text
    else combiningMarks.replace(
        java.text.Normalizer.normalize(text, java.text.Normalizer.Form.NFD), "")
    val out = StringBuilder(base.length)
    for (c in base) if (c.isLetterOrDigit()) out.append(c.lowercaseChar())
    return out.toString()
}
data class Episode(
    val id: String, val title: String, val ext: String,
    val season: Int, val number: Int,
    val plot: String = "", val thumb: String = "", val durationSecs: Int = 0
)

/** On-demand rich detail for a movie, from get_vod_info. */
data class MovieInfo(
    val plot: String, val poster: String, val cast: String,
    val genre: String, val durationSecs: Int, val year: String, val trailer: String,
    val tmdbId: Int = 0, val backdrop: String = "", val rating: String = ""
)

enum class Kind { LIVE, MOVIE, SERIES }

data class SearchResult(val kind: Kind, val name: String, val id: Long, val ext: String = "")

/**
 * [context] is needed only by the disk-backed [CatalogDb] mirror, which is additive
 * and stays dormant without one. It is optional so the client can still be built
 * before a context is handy; [attachContext] supplies it later in that case.
 */
class XtreamClient(private val dataDir: File, context: Context? = null) {

    // Read from the saved account when there is one, else the build-time values.
    // Held as vars so Settings can swap accounts without recreating the client.
    @Volatile private var server = BuildConfig.XTREAM_SERVER.trimEnd('/')
    @Volatile private var user = BuildConfig.XTREAM_USER
    @Volatile private var pass = BuildConfig.XTREAM_PASS

    init {
        context?.let { applyCredentials(XtreamCredentials(it)) }
    }

    /** Point the client at [credentials]. */
    @Synchronized
    fun applyCredentials(credentials: XtreamCredentials) {
        server = credentials.server.trimEnd('/')
        user = credentials.username
        pass = credentials.password
    }

    /**
     * Switch accounts: adopt [credentials] and throw away everything cached for the
     * previous one. The catalogues, title indexes and category lists are all
     * account-specific, so keeping them would show another subscription's content.
     */
    @Synchronized
    fun switchAccount(credentials: XtreamCredentials) {
        applyCredentials(credentials)
        live = emptyList(); movies = emptyList(); series = emptyList()
        loaded = false; moviesLoaded = false
        languagesCache = null
        movieTitleIndex = null; seriesTitleIndex = null
        liveCategoriesCache = null
        categoryChannels.clear()
        LiveCatalog.invalidate()
        for (catalog in catalogs) {
            binFile(catalog).delete()
            File(dataDir, "${catalog.cacheName}.json").delete()
        }
        File(dataDir, "movie_index.bin").delete()
        File(dataDir, "series_index.bin").delete()
        try { db()?.clearAll() } catch (_: Exception) {}
    }

    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(180, TimeUnit.SECONDS)
        .build()

    @Volatile var live: List<Entry> = emptyList(); private set
    @Volatile var movies: List<Entry> = emptyList(); private set
    @Volatile var series: List<Entry> = emptyList(); private set

    /**
     * How many streams this account may run at once, from the provider.
     *
     * It matters because the app otherwise competes with itself: pre-caching the
     * next episode or warming Continue Playing opens a SECOND stream while you are
     * watching, and on a one-connection account the server throttles or refuses
     * one of them - which the viewer sees as playback stuttering every few
     * seconds. 0 means "not known yet"; callers should assume 1 until it is.
     */
    @Volatile var maxConnections = 0; private set

    /** True when a background download may run alongside active playback. */
    val canFetchWhilePlaying: Boolean get() = maxConnections > 1

    /** Ask the provider how many simultaneous streams we get. Network call. */
    fun refreshAccountLimits() {
        try {
            val body = http.newCall(Request.Builder().url(apiUrl("")).build())
                .execute().use { if (!it.isSuccessful) return; it.body!!.string() }
            val info = JsonParser.parseString(body).asJsonObject.getAsJsonObject("user_info")
            maxConnections = info?.get("max_connections")?.asString?.toIntOrNull() ?: 0
            Log.i(TAG, "account allows $maxConnections simultaneous stream(s)")
        } catch (_: Exception) {}
    }

    /** Hide adult titles from search and browsing. Mirrors [Settings.adultFilter]. */
    @Volatile var adultFilterOn = true

    @Volatile var loaded = false; private set          // live + series ready (app usable)
    @Volatile var moviesLoaded = false; private set    // the big movies catalog ready

    private val refreshAfterMs = TimeUnit.HOURS.toMillis(24)
    private val binVersion = 3 // v3: stores norm/lang/adult so a cold start derives nothing

    private class Catalog(
        val cacheName: String, val action: String, val label: String, val kind: Kind
    )

    private val liveCatalog = Catalog("live", "get_live_streams", "live channels", Kind.LIVE)
    private val moviesCatalog = Catalog("vod", "get_vod_streams", "movies", Kind.MOVIE)
    private val seriesCatalog = Catalog("series", "get_series", "series", Kind.SERIES)
    private val catalogs = listOf(liveCatalog, moviesCatalog, seriesCatalog)

    private fun apiUrl(action: String, extra: String = ""): String =
        "$server/player_api.php?username=$user&password=$pass&action=$action$extra"

    private fun binFile(catalog: Catalog) = File(dataDir, "${catalog.cacheName}.bin")

    /** Read one catalog from its binary cache (any age), or fetch if missing/corrupt. */
    private fun loadOne(catalog: Catalog, onProgress: (String) -> Unit): List<Entry> {
        val bin = binFile(catalog)
        if (bin.exists()) {
            onProgress("Opening ${catalog.label}...")
            try {
                val startedAt = android.os.SystemClock.elapsedRealtime()
                val entries = readBin(bin)
                android.util.Log.i("XtreamPerf", "catalog ${catalog.cacheName}: ${entries.size} entries " +
                    "from disk in ${android.os.SystemClock.elapsedRealtime() - startedAt}ms")
                return entries
            } catch (_: Exception) {
                bin.delete() // corrupt or old format: refetch below
            }
        }
        return fetchAndIndex(catalog, onProgress)
    }

    /**
     * Fast startup path: load ONLY live + series (the small catalogs) so the app
     * is usable in a fraction of a second. The big movies catalog is loaded
     * separately by [loadMovies] in the background. Uses the binary cache at ANY
     * age; only hits the network for a catalog that has no cache at all.
     */
    @Synchronized
    fun loadCatalogs(onProgress: (String) -> Unit) {
        if (loaded) return
        live = loadOne(liveCatalog, onProgress)
        series = loadOne(seriesCatalog, onProgress)
        loaded = true
    }

    /**
     * Background path for the large movies catalog (23 MB), so it never blocks
     * startup or holds up navigation. Safe to call once startup is under way.
     */
    @Synchronized
    fun loadMovies(onProgress: (String) -> Unit) {
        if (moviesLoaded) return
        movies = loadOne(moviesCatalog, onProgress)
        moviesLoaded = true
        languagesCache = null      // recompute with movies included
        movieTitleIndex = null     // rebuild the movie index over the full list
    }

    fun isStale(): Boolean = catalogs.any { catalog ->
        val bin = binFile(catalog)
        !bin.exists() || System.currentTimeMillis() - bin.lastModified() > refreshAfterMs
    }

    /**
     * Background path: re-downloads everything only when the newest data on
     * disk is older than a day. Returns true when a refresh actually ran.
     */
    @Synchronized
    fun refreshIfStale(onProgress: (String) -> Unit): Boolean {
        if (!isStale()) return false
        publish(catalogs.map { fetchAndIndex(it, onProgress) })
        moviesLoaded = true // a full refresh re-fetches movies too
        return true
    }

    private fun publish(lists: List<List<Entry>>) {
        live = lists[0]
        movies = lists[1]
        series = lists[2]
    }

    private fun fetchAndIndex(catalog: Catalog, onProgress: (String) -> Unit): List<Entry> {
        onProgress("Downloading ${catalog.label}...")
        val json = downloadJson(catalog)
        onProgress("Indexing ${catalog.label}...")
        val entries = parseEntries(json)
        writeBin(binFile(catalog), entries)
        ingestIntoDb(catalog, json)
        json.delete()
        return entries
    }

    private fun downloadJson(catalog: Catalog): File {
        // A json left behind by an interrupted run is reused if very recent.
        val file = File(dataDir, "${catalog.cacheName}.json")
        val reusable = file.exists() && file.length() > 2 &&
            System.currentTimeMillis() - file.lastModified() < TimeUnit.HOURS.toMillis(2)
        if (reusable) return file

        val request = Request.Builder().url(apiUrl(catalog.action)).build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("HTTP ${response.code} fetching ${catalog.action}")
            val temp = File(dataDir, "${catalog.cacheName}.tmp")
            temp.outputStream().use { out -> response.body!!.byteStream().copyTo(out) }
            file.delete()
            if (!temp.renameTo(file)) {
                temp.copyTo(file, overwrite = true)
                temp.delete()
            }
        }
        return file
    }

    private fun parseEntries(file: File): List<Entry> {
        val out = ArrayList<Entry>(4096)
        JsonReader(FileReader(file)).use { reader ->
            reader.beginArray()
            while (reader.hasNext()) {
                var name = ""
                var streamId = 0L
                var seriesId = 0L
                var ext = ""
                var logo = ""
                var epgId = ""
                var archive = 0
                reader.beginObject()
                while (reader.hasNext()) {
                    when (reader.nextName()) {
                        "name" -> name = reader.nextStringOrEmpty()
                        "stream_id" -> streamId = reader.nextLong()
                        "series_id" -> seriesId = reader.nextLong()
                        "container_extension" -> ext = reader.nextStringOrEmpty()
                        "stream_icon" -> logo = reader.nextStringOrEmpty()
                        "epg_channel_id" -> epgId = reader.nextStringOrEmpty()
                        "tv_archive" -> archive = reader.nextIntOrZero()
                        else -> reader.skipValue()
                    }
                }
                reader.endObject()
                val id = if (streamId != 0L) streamId else seriesId
                if (name.isNotEmpty() && id != 0L) out.add(Entry(name, id, ext, logo, epgId, archive))
            }
            reader.endArray()
        }
        return out
    }

    private fun JsonReader.nextStringOrEmpty(): String =
        if (peek() == JsonToken.NULL) { nextNull(); "" } else nextString()

    /** tv_archive comes back as a number, sometimes a string; tolerate both. */
    private fun JsonReader.nextIntOrZero(): Int = when (peek()) {
        JsonToken.NULL -> { nextNull(); 0 }
        JsonToken.STRING -> nextString().toIntOrNull() ?: 0
        else -> try { nextInt() } catch (_: Exception) { 0 }
    }

    private fun writeBin(file: File, entries: List<Entry>) {
        val temp = File(file.parentFile, file.name + ".tmp")
        DataOutputStream(temp.outputStream().buffered(1 shl 16)).use { out ->
            out.writeInt(binVersion)
            out.writeInt(entries.size)
            for (entry in entries) {
                out.writeUTF(entry.name)
                out.writeLong(entry.id)
                out.writeUTF(entry.ext)
                out.writeUTF(entry.logo)
                out.writeUTF(entry.epgId)
                out.writeInt(entry.archive)
                out.writeUTF(entry.norm)
                out.writeUTF(entry.lang ?: "")
                out.writeBoolean(entry.adult)
            }
        }
        file.delete()
        if (!temp.renameTo(file)) {
            temp.copyTo(file, overwrite = true)
            temp.delete()
        }
    }

    private fun readBin(file: File): List<Entry> {
        var upgrade = false
        val entries = DataInputStream(file.inputStream().buffered(1 shl 16)).use { input ->
            val version = input.readInt()
            require(version == binVersion || version == 2) { "cache format changed" }
            val count = input.readInt()
            val out = ArrayList<Entry>(count)
            // Most ext/logo/epgId/lang values are empty or one of a few codes; sharing
            // them avoids hundreds of thousands of duplicate little strings.
            val shared = HashMap<String, String>()
            fun small(value: String): String =
                if (value.isEmpty()) "" else if (value.length > 8) value else shared.getOrPut(value) { value }
            if (version == binVersion) {
                repeat(count) {
                    val name = input.readUTF()
                    val id = input.readLong()
                    val ext = small(input.readUTF())
                    val logo = small(input.readUTF())
                    val epgId = small(input.readUTF())
                    val archive = input.readInt()
                    val norm = input.readUTF()
                    val lang = small(input.readUTF()).ifEmpty { null }
                    out.add(Entry(name, id, ext, logo, epgId, archive, norm, lang, input.readBoolean()))
                }
            } else {
                // Previous format without the derived fields: derive once, then rewrite.
                repeat(count) {
                    out.add(Entry(input.readUTF(), input.readLong(), small(input.readUTF()),
                        small(input.readUTF()), small(input.readUTF()), input.readInt()))
                }
                upgrade = true
            }
            out
        }
        if (upgrade) try { writeBin(file, entries) } catch (_: Exception) {}
        return entries
    }

    // ---- Disk-backed catalog mirror (CatalogDb) ----
    //
    // Phase 1: the fetch path fills the DB alongside the .bin cache, and the db*
    // readers below expose it, but nothing reads from it yet — the in-RAM lists stay
    // authoritative. Every entry point is guarded so a broken DB degrades to a no-op.

    @Volatile private var appContext: Context? = context?.applicationContext
    @Volatile private var catalogDb: CatalogDb? = null
    @Volatile private var dbUnavailable = false

    /**
     * Hand the client an Application context after construction, for callers that
     * build it before one is handy. Safe to call repeatedly; ignored once the DB is open.
     */
    fun attachContext(context: Context) {
        if (appContext == null) appContext = context.applicationContext
    }

    /**
     * The derived columns the DB stores are computed by the *same* private functions
     * the in-RAM index uses, so on-disk and in-RAM search can never drift apart.
     */
    private val derivations = object : CatalogDb.Derivations {
        override fun titleKeys(name: String): List<String> {
            val keys = ArrayList<String>(2)
            addTitleKeys(name) { keys.add(it) }
            return keys
        }

        override fun preferenceScore(name: String, ext: String): Int =
            this@XtreamClient.preferenceScore(name, ext)
    }

    /** Opens the DB on first use; null (permanently) if it can't be opened. */
    @Synchronized
    private fun db(): CatalogDb? {
        catalogDb?.let { return it }
        if (dbUnavailable) return null
        val context = appContext ?: return null
        return try {
            CatalogDb(context).also { catalogDb = it }
        } catch (e: Throwable) {
            dbUnavailable = true
            Log.w(TAG, "catalog db unavailable", e)
            null
        }
    }

    /** Runs a DB read, falling back to [fallback] when the DB is missing or throws. */
    private inline fun <T> withDb(fallback: T, body: (CatalogDb) -> T): T {
        val db = db() ?: return fallback
        return try {
            body(db)
        } catch (e: Throwable) {
            Log.w(TAG, "catalog db query failed", e)
            fallback
        }
    }

    /**
     * Mirror the freshly downloaded JSON into the DB. Runs on the background fetch
     * thread, streams row by row, and swallows failures: the .bin path above has
     * already produced the catalog the app actually uses.
     */
    private fun ingestIntoDb(catalog: Catalog, json: File) {
        val db = db() ?: return
        try {
            db.replaceKind(catalog.kind, json, derivations)
        } catch (e: Throwable) {
            Log.w(TAG, "catalog db ingest failed for ${catalog.cacheName}", e)
        }
    }

    // ---- DB readers (parallel to the in-RAM API; no call site uses them yet) ----

    /** True once a DB ingest for [kind] has committed rows. */
    fun dbHasKind(kind: Kind): Boolean = withDb(false) { it.hasKind(kind) }

    fun dbCount(kind: Kind): Int = withDb(0) { it.count(kind) }

    /** Cursor-backed search session; null when the DB can't serve it. Callers must close it. */
    fun dbSearch(query: String, kind: Kind? = null, lang: String? = null): CatalogDb.DbSearchSession? =
        withDb(null) { it.newSearch(query, kind, lang) }

    fun dbAvailability(query: String, kind: Kind?, lang: String?): Availability? {
        val parsed = ParsedQuery(query)
        if (!parsed.valid) return null
        return withDb(null) {
            it.availability(parsed.tokens, parsed.whole, parsed.core, kind, lang)
        }
    }

    fun dbLanguages(minCount: Int = 200): List<String> = withDb(emptyList()) { it.languages(minCount) }

    fun dbFindByTitle(title: String, isSeries: Boolean): SearchResult? {
        val kind = if (isSeries) Kind.SERIES else Kind.MOVIE
        return withDb(null) { db ->
            db.findByTitle(kind, derivations.titleKeys(title))?.let { (id, name, ext) ->
                SearchResult(kind, name, id, if (kind == Kind.MOVIE) ext.ifEmpty { "mp4" } else "")
            }
        }
    }

    fun dbSourcesFor(name: String, isSeries: Boolean): List<Entry> = withDb(emptyList()) {
        it.sourcesFor(if (isSeries) Kind.SERIES else Kind.MOVIE, titleKeyOf(name))
    }

    fun dbLiveLogo(streamId: Long): String = withDb("") { it.liveLogo(streamId) }

    fun dbLiveGroupCounts(): List<Pair<String, Int>> = withDb(emptyList()) { it.liveGroupCounts() }

    fun dbLiveBucketChannels(bucket: String, afterRow: Long = 0, limit: Int): List<Entry> =
        withDb(emptyList()) { it.liveBucketChannels(bucket, afterRow, limit) }

    /** Keyset page: feed [CatalogDb.Page.nextRow] back in as the next `afterRow`. */
    fun dbLiveBucketPage(bucket: String, afterRow: Long = 0, limit: Int): CatalogDb.Page =
        withDb(CatalogDb.Page(emptyList(), afterRow)) { it.liveBucketPage(bucket, afterRow, limit) }

    fun dbLiveSmartList(keys: List<String>, limit: Int): List<Entry> =
        withDb(emptyList()) { it.liveSmartList(keys, limit) }

    fun dbLiveFavorites(ids: Collection<Long>): List<Entry> =
        withDb(emptyList()) { it.liveFavorites(ids) }

    @Volatile private var languagesCache: List<String>? = null

    /** Language codes present in the catalogs, most common first. */
    fun languages(): List<String> {
        languagesCache?.let { return it }
        val counts = HashMap<String, Int>()
        for (catalog in listOf(live, movies, series)) {
            for (entry in catalog) {
                entry.lang?.let { counts[it] = (counts[it] ?: 0) + 1 }
            }
        }
        val langs = counts.filterValues { it >= 200 }
            .entries.sortedByDescending { it.value }.map { it.key }
        languagesCache = langs
        return langs
    }

    fun newSearch(query: String, kind: Kind? = null, lang: String? = null): SearchSession =
        SearchSession(query, kind, lang)

    class Availability(val kinds: Map<Kind, Int>, val langs: Map<String, Int>, val untagged: Int)

    /**
     * Full-catalog counts for the query, used to show only filters that lead
     * somewhere. Cross-filtered: kind counts respect the language filter and
     * language counts respect the kind filter.
     */
    fun availability(query: String, kind: Kind?, lang: String?): Availability? {
        val parsed = ParsedQuery(query)
        if (!parsed.valid) return null

        val kindCounts = HashMap<Kind, Int>()
        val langCounts = HashMap<String, Int>()
        var untagged = 0
        for ((entries, entriesKind) in listOf(
            live to Kind.LIVE, movies to Kind.MOVIE, series to Kind.SERIES)) {
            // Facet counts must match what search will actually show.
            for (entry in entries) {
                if (!parsed.matches(entry)) continue
                if (adultFilterOn && entry.adult) continue
                val langOk = lang == null || entry.lang == null || entry.lang == lang
                if (langOk) kindCounts[entriesKind] = (kindCounts[entriesKind] ?: 0) + 1
                if (kind == null || entriesKind == kind) {
                    val entryLang = entry.lang
                    if (entryLang == null) untagged++
                    else langCounts[entryLang] = (langCounts[entryLang] ?: 0) + 1
                }
            }
        }
        return Availability(kindCounts, langCounts, untagged)
    }

    /**
     * Paged scan over the catalogs. Every query word must appear somewhere in
     * the normalized name ("back room" matches "The Backrooms"); within a page,
     * names containing the words joined together rank first. Each next() call
     * resumes the scan where the previous page stopped.
     */
    inner class SearchSession(query: String, private val kind: Kind?, private val lang: String?) {
        private val parsed = ParsedQuery(query)

        val valid: Boolean = parsed.valid

        private val sources: List<Pair<List<Entry>, Kind>> =
            listOf(live to Kind.LIVE, movies to Kind.MOVIE, series to Kind.SERIES)
                .filter { kind == null || it.second == kind }
        private var sourceIndex = 0
        private var position = 0

        var exhausted = !valid; private set

        fun next(count: Int): List<SearchResult> {
            if (exhausted) return emptyList()
            val page = ArrayList<Pair<Int, SearchResult>>(count)
            while (page.size < count && sourceIndex < sources.size) {
                val (entries, kind) = sources[sourceIndex]
                while (position < entries.size && page.size < count) {
                    val entry = entries[position++]
                    // No-prefix titles always pass the language filter.
                    if (lang != null && entry.lang != null && entry.lang != lang) continue
                    // Adult check runs LAST: it is far more expensive than the text
                    // match, so it must only see the few entries that already match,
                    // not all ~286k on every keystroke.
                    if (parsed.matches(entry)) {
                        if (adultFilterOn && entry.adult) continue
                        val ext = if (kind == Kind.MOVIE) entry.ext.ifEmpty { "mp4" } else ""
                        page.add(parsed.rank(entry) to SearchResult(kind, entry.name, entry.id, ext))
                    }
                }
                if (position >= entries.size) {
                    sourceIndex++
                    position = 0
                }
            }
            if (sourceIndex >= sources.size) exhausted = true
            return page.sortedBy { it.first }.map { it.second }
        }
    }

    /** Series episodes plus the high-quality series cover/poster. */
    data class SeriesDetail(val cover: String, val episodes: List<Episode>,
        val plot: String = "", val cast: String = "", val genre: String = "",
        val year: String = "", val rating: String = "",
        val tmdbId: Int = 0, val backdrop: String = "")

    fun seriesDetail(seriesId: Long): SeriesDetail {
        val request = Request.Builder()
            .url(apiUrl("get_series_info", "&series_id=$seriesId")).build()
        val body = http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("HTTP ${response.code} fetching series info")
            response.body!!.string()
        }
        val root = JsonParser.parseString(body).asJsonObject
        val seriesInfo = root.get("info")?.takeIf { it.isJsonObject }?.asJsonObject
        fun sInfo(k: String) = seriesInfo?.get(k)?.takeIf { it.isJsonPrimitive }?.asString ?: ""
        val cover = listOf("cover", "cover_big", "movie_image", "backdrop_path").firstNotNullOfOrNull { k ->
            seriesInfo?.get(k)?.takeIf { it.isJsonPrimitive }?.asString?.takeIf { it.isNotBlank() }
        } ?: ""
        val plot = sInfo("plot").ifEmpty { sInfo("overview") }
        val cast = sInfo("cast").ifEmpty { sInfo("actors") }
        val genre = sInfo("genre")
        val year = sInfo("releaseDate").ifEmpty { sInfo("releasedate") }.take(4).ifEmpty { sInfo("year") }
        val rating = sInfo("rating")
        val tmdbId = sInfo("tmdb").toIntOrNull() ?: sInfo("tmdb_id").toIntOrNull() ?: 0
        val backdrop = seriesInfo?.get("backdrop_path")?.let { bd ->
            when {
                bd.isJsonArray -> bd.asJsonArray.firstOrNull()?.takeIf { it.isJsonPrimitive }?.asString
                bd.isJsonPrimitive -> bd.asString
                else -> null
            }
        } ?: ""
        val episodesNode = root.get("episodes")
            ?: return SeriesDetail(cover, emptyList(), plot, cast, genre, year, rating, tmdbId, backdrop)
        if (!episodesNode.isJsonObject)
            return SeriesDetail(cover, emptyList(), plot, cast, genre, year, rating, tmdbId, backdrop)
        val out = ArrayList<Episode>()
        for ((seasonKey, seasonEpisodes) in episodesNode.asJsonObject.entrySet()) {
            if (!seasonEpisodes.isJsonArray) continue
            // The object key IS the season number in Xtream; trust it over the
            // per-episode "season" field, which providers often omit or flatten to 1.
            val keySeason = seasonKey.toIntOrNull()
            for (element in seasonEpisodes.asJsonArray) {
                val obj = element.asJsonObject
                val info = obj.get("info")?.takeIf { it.isJsonObject }?.asJsonObject
                fun infoStr(key: String) =
                    info?.get(key)?.takeIf { it.isJsonPrimitive }?.asString ?: ""
                out.add(
                    Episode(
                        id = obj.get("id").asString,
                        title = obj.get("title")?.takeIf { it.isJsonPrimitive }?.asString ?: "Episode",
                        ext = obj.get("container_extension")?.takeIf { it.isJsonPrimitive }?.asString ?: "mp4",
                        season = keySeason ?: obj.get("season")?.takeIf { it.isJsonPrimitive }?.asInt ?: 0,
                        number = obj.get("episode_num")?.takeIf { it.isJsonPrimitive }?.asInt ?: 0,
                        plot = infoStr("plot").ifEmpty { infoStr("overview") },
                        thumb = infoStr("movie_image").ifEmpty { infoStr("cover_big") },
                        durationSecs = infoStr("duration_secs").toIntOrNull() ?: 0
                    )
                )
            }
        }
        return SeriesDetail(cover, out.sortedWith(compareBy({ it.season }, { it.number })),
            plot, cast, genre, year, rating, tmdbId, backdrop)
    }

    /** On-demand rich detail for one movie. Network call; use off the UI thread. */
    fun movieInfo(vodId: Long): MovieInfo {
        val request = Request.Builder()
            .url(apiUrl("get_vod_info", "&vod_id=$vodId")).build()
        val body = http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("HTTP ${response.code} fetching movie info")
            response.body!!.string()
        }
        val info = JsonParser.parseString(body).asJsonObject
            .get("info")?.takeIf { it.isJsonObject }?.asJsonObject
        fun str(key: String) = info?.get(key)?.takeIf { it.isJsonPrimitive }?.asString ?: ""
        // backdrop_path is often an array of URLs; take the first.
        val backdrop = info?.get("backdrop_path")?.let { bd ->
            when {
                bd.isJsonArray -> bd.asJsonArray.firstOrNull()?.takeIf { it.isJsonPrimitive }?.asString
                bd.isJsonPrimitive -> bd.asString
                else -> null
            }
        } ?: ""
        return MovieInfo(
            plot = str("plot").ifEmpty { str("description") },
            poster = str("movie_image").ifEmpty { str("cover_big") },
            cast = str("cast").ifEmpty { str("actors") },
            genre = str("genre"),
            durationSecs = str("duration_secs").toIntOrNull() ?: 0,
            year = str("releasedate").take(4).ifEmpty { str("year") },
            trailer = str("youtube_trailer"),
            tmdbId = str("tmdb_id").toIntOrNull() ?: 0,
            backdrop = backdrop,
            rating = str("rating")
        )
    }

    // ---- Title index for matching external (TMDB) titles to the catalog ----

    // Lightweight index value (just what findByTitle needs — no norm/lang recompute).
    private class IndexRec(val name: String, val id: Long, val ext: String)
    private var movieTitleIndex: HashMap<String, IndexRec>? = null
    private var seriesTitleIndex: HashMap<String, IndexRec>? = null

    /**
     * Allocation-light match keys for the index (runs on 227k rows). Drops the
     * "TAG - " provider/quality prefix and a trailing "(year)"/"(CC)", then
     * normalizes; also a leading-article-stripped variant. No regex/split.
     */
    private fun addTitleKeys(name: String, into: (String) -> Unit) {
        // Body after the last " - " (the provider/quality prefix boundary).
        val dash = name.lastIndexOf(" - ")
        var start = if (dash >= 0) dash + 3 else 0
        var end = name.length
        // Trim ALL trailing short "(....)" groups. Catalog names carry both a year
        // and a country code, e.g. "House of the Dragon (2022) (US)" — stripping
        // only one would leave "2022" in the key and never match a clean title.
        // The 6-char cap keeps a real parenthetical title (e.g. "(Extended Cut)").
        while (true) {
            while (end > start && name[end - 1] == ' ') end--
            if (end <= start || name[end - 1] != ')') break
            val open = name.lastIndexOf('(', end - 1)
            if (open <= start || end - 1 - open > 6) break
            end = open
        }
        // Full key.
        into(normalizeForSearch(name.substring(start, end)))
        // Leading-article-stripped key: skip "the "/"a "/"an " at the body start.
        while (start < end && name[start] == ' ') start++
        val lower = name.substring(start, minOf(start + 4, end)).lowercase()
        val skip = when {
            lower.startsWith("the ") -> 4
            lower.startsWith("an ") -> 3
            lower.startsWith("a ") -> 2
            else -> 0
        }
        if (skip > 0) into(normalizeForSearch(name.substring(start + skip, end)))
    }

    @Synchronized
    private fun indexFor(kind: Kind): HashMap<String, IndexRec> {
        val cached = if (kind == Kind.MOVIE) movieTitleIndex else seriesTitleIndex
        if (cached != null) return cached
        val list = if (kind == Kind.MOVIE) movies else series
        // Movies may not be loaded yet (deferred at startup) — don't cache an
        // empty index; rebuild once the catalog is in.
        if (list.isEmpty()) return HashMap()
        val file = File(dataDir, if (kind == Kind.MOVIE) "movie_index.bin" else "series_index.bin")
        // Load from disk if it matches the current catalog (skips the rebuild).
        readIndex(file, list.size)?.let {
            if (kind == Kind.MOVIE) movieTitleIndex = it else seriesTitleIndex = it
            return it
        }
        // Among duplicate entries of the same title, keep the best one (highest
        // quality, English/original audio, multi-language/subtitle bonus).
        val map = HashMap<String, IndexRec>(list.size * 2)
        val bestScore = HashMap<String, Int>(list.size * 2)
        for (entry in list) {
            val score = preferenceScore(entry.name, entry.ext)
            addTitleKeys(entry.name) { key ->
                if (key.isEmpty()) return@addTitleKeys
                val existing = bestScore[key]
                if (existing == null || score > existing) {
                    map[key] = IndexRec(entry.name, entry.id, entry.ext)
                    bestScore[key] = score
                }
            }
        }
        if (kind == Kind.MOVIE) movieTitleIndex = map else seriesTitleIndex = map
        writeIndex(file, list.size, map)
        return map
    }

    /** The primary (non-article-stripped) title key for an entry name. */
    fun titleKeyOf(name: String): String {
        var key = ""
        addTitleKeys(name) { if (key.isEmpty()) key = it }
        return key
    }

    /**
     * All catalog entries that are the same title as [name] (every source/quality/
     * language duplicate), best first. Powers the "Other sources" picker.
     */
    fun sourcesFor(name: String, isSeries: Boolean): List<Entry> {
        val target = titleKeyOf(name)
        if (target.isEmpty()) return emptyList()
        val list = if (isSeries) series else movies
        val matches = ArrayList<Entry>()
        for (entry in list) {
            var hit = false
            addTitleKeys(entry.name) { if (!hit && it == target) hit = true }
            if (hit) matches.add(entry)
        }
        return matches.sortedByDescending { preferenceScore(it.name, it.ext) }
    }

    // Non-English dub prefixes to deprioritize when choosing among duplicates
    // (Indian-subcontinent, Nepali, and English variants are intentionally absent).
    private val foreignAudioPrefixes = setOf(
        "DE", "IT", "FR", "ES", "TR", "AR", "RU", "PT", "NL", "PL", "GR", "SE", "NO",
        "DK", "FI", "CZ", "HU", "RO", "IR", "IL", "HR", "RS", "BG", "UA", "VN", "TH",
        "ID", "MY", "KR", "JP", "CN", "EG", "MA", "AL", "EXYU", "BR", "MX", "SK", "SI")

    /**
     * Rank a catalog entry by desirability from the signals actually present in
     * this catalog: resolution (4K > 1080 > 720 > SD), HDR/Dolby Vision, an mkv
     * container (usually higher bitrate than mp4), multi-audio and subtitles, and
     * a big penalty for a foreign-dub prefix so English/original audio wins. The
     * catalog carries no file size/bitrate, so those can't factor in here.
     */
    private fun preferenceScore(name: String, ext: String = ""): Int {
        val u = name.uppercase()
        var score = 0
        val prefix = name.substringBefore(" - ").substringBefore("|").trim().uppercase()
            .removePrefix("4K-").removePrefix("UHD-").removePrefix("FHD-").removePrefix("HD-")
        if (prefix in foreignAudioPrefixes) score -= 1000
        score += when {
            u.contains("2160") || u.contains("4K") || u.contains("UHD") -> 400
            u.contains("1080") || u.contains("FHD") -> 300
            u.contains("720") || u.contains(" HD") -> 200
            u.contains("480") || u.contains(" SD") -> 100
            else -> 0
        }
        if (u.contains("REMUX")) score += 200                          // top tier (rare)
        if (u.contains("HDR") || u.contains("DOLBY VISION") || u.contains(" DV ")) score += 120
        if (u.contains("BLURAY") || u.contains("BLU-RAY")) score += 80
        if (ext.equals("mkv", true)) score += 40                       // mkv ~ higher bitrate than mp4
        if (u.contains("MULTI") || u.contains("DUAL")) score += 60     // multiple audio tracks
        if (u.contains("SUB")) score += 30                             // subtitles available
        return score
    }

    /** Persist key -> (name/id/ext) so cold starts skip the ~12s parse. */
    private fun writeIndex(file: File, catalogSize: Int, map: HashMap<String, IndexRec>) {
        try {
            val temp = File(file.parentFile, file.name + ".tmp")
            DataOutputStream(temp.outputStream().buffered()).use { out ->
                out.writeInt(4)              // format version (4: quality-scored best selection)
                out.writeInt(catalogSize)    // invalidation tag
                out.writeInt(map.size)
                for ((key, e) in map) {
                    out.writeUTF(key); out.writeUTF(e.name); out.writeLong(e.id); out.writeUTF(e.ext)
                }
            }
            file.delete()
            if (!temp.renameTo(file)) { temp.copyTo(file, overwrite = true); temp.delete() }
        } catch (_: Exception) {}
    }

    private fun readIndex(file: File, catalogSize: Int): HashMap<String, IndexRec>? {
        if (!file.exists()) return null
        return try {
            DataInputStream(file.inputStream().buffered()).use { input ->
                if (input.readInt() != 4) return null
                if (input.readInt() != catalogSize) return null // catalog changed
                val count = input.readInt()
                val map = HashMap<String, IndexRec>(count)
                repeat(count) {
                    val key = input.readUTF()
                    map[key] = IndexRec(input.readUTF(), input.readLong(), input.readUTF())
                }
                map
            }
        } catch (_: Exception) { null }
    }

    /** Pre-build both title indexes on one thread before rails query them. */
    fun warmTitleIndexes() {
        indexFor(Kind.MOVIE)
        indexFor(Kind.SERIES)
    }

    /**
     * Find a catalog entry whose title matches [title] (exact after
     * normalization, articles optional). Returns null if the catalog has nothing
     * matching, so external rails can hide titles you can't actually play.
     */
    fun findByTitle(title: String, isSeries: Boolean): SearchResult? {
        val kind = if (isSeries) Kind.SERIES else Kind.MOVIE
        val index = indexFor(kind)
        var found: IndexRec? = null
        addTitleKeys(title) { key -> if (found == null) found = index[key] }
        return found?.let {
            val ext = if (kind == Kind.MOVIE) it.ext.ifEmpty { "mp4" } else ""
            SearchResult(kind, it.name, it.id, ext)
        }
    }

    // ---- Live categories, category channels, and EPG (for Sports hub + guide) ----

    data class LiveCategoryInfo(val id: String, val name: String)
    data class EpgEntry(val title: String, val start: String, val end: String, val nowPlaying: Boolean)

    @Volatile private var liveCategoriesCache: List<LiveCategoryInfo>? = null
    private val categoryChannels = HashMap<String, List<Entry>>()
    private val epgCache = HashMap<Long, Pair<Long, List<EpgEntry>>>() // streamId -> (fetchedAt, entries)

    fun liveCategories(): List<LiveCategoryInfo> {
        liveCategoriesCache?.let { return it }
        val body = http.newCall(Request.Builder().url(apiUrl("get_live_categories")).build())
            .execute().use { if (!it.isSuccessful) return emptyList(); it.body!!.string() }
        val out = ArrayList<LiveCategoryInfo>()
        try {
            for (el in JsonParser.parseString(body).asJsonArray) {
                val o = el.asJsonObject
                val id = o.get("category_id")?.asString ?: continue
                val name = o.get("category_name")?.asString ?: continue
                if (adultFilterOn && AdultFilter.isAdultCategory(name)) continue
                out.add(LiveCategoryInfo(id, name))
            }
        } catch (_: Exception) {}
        liveCategoriesCache = out
        return out
    }

    @Synchronized
    fun channelsInCategory(categoryId: String): List<Entry> {
        categoryChannels[categoryId]?.let { return it }
        val body = http.newCall(Request.Builder()
            .url(apiUrl("get_live_streams", "&category_id=$categoryId")).build())
            .execute().use { if (!it.isSuccessful) return emptyList(); it.body!!.string() }
        val out = ArrayList<Entry>()
        try {
            for (el in JsonParser.parseString(body).asJsonArray) {
                val o = el.asJsonObject
                val id = o.get("stream_id")?.takeIf { it.isJsonPrimitive }?.asLong ?: continue
                val name = o.get("name")?.takeIf { it.isJsonPrimitive }?.asString ?: continue
                fun str(k: String) = o.get(k)?.takeIf { it.isJsonPrimitive }?.asString ?: ""
                val archive = o.get("tv_archive")?.takeIf { it.isJsonPrimitive }?.let {
                    try { it.asInt } catch (_: Exception) { 0 }
                } ?: 0
                out.add(Entry(name, id, "", str("stream_icon"), str("epg_channel_id"), archive))
            }
        } catch (_: Exception) {}
        categoryChannels[categoryId] = out
        return out
    }

    /** Cached now/next only (no network) — for adapters to skip work on cache hits. */
    fun shortEpgCached(streamId: Long): List<EpgEntry>? {
        synchronized(epgCache) {
            epgCache[streamId]?.let { (at, entries) ->
                if (System.currentTimeMillis() - at < 10 * 60 * 1000) return entries
            }
        }
        return null
    }

    /** Now/next program guide for a channel; cached ~10 min. Empty if unavailable. */
    fun shortEpg(streamId: Long): List<EpgEntry> {
        synchronized(epgCache) {
            epgCache[streamId]?.let { (at, entries) ->
                if (System.currentTimeMillis() - at < 10 * 60 * 1000) return entries
            }
        }
        val entries = try {
            val body = http.newCall(Request.Builder()
                .url(apiUrl("get_short_epg", "&stream_id=$streamId&limit=4")).build())
                .execute().use { if (!it.isSuccessful) return emptyList(); it.body!!.string() }
            val listings = JsonParser.parseString(body).asJsonObject.getAsJsonArray("epg_listings")
                ?: return emptyList()
            listings.mapNotNull { el ->
                val o = el.asJsonObject
                fun s(k: String) = o.get(k)?.takeIf { it.isJsonPrimitive }?.asString ?: ""
                val title = try {
                    String(android.util.Base64.decode(s("title"), android.util.Base64.DEFAULT))
                } catch (_: Exception) { s("title") }
                if (title.isBlank()) null
                else EpgEntry(title, s("start"), s("end"), o.get("now_playing")?.asString == "1")
            }
        } catch (_: Exception) { emptyList() }
        synchronized(epgCache) { epgCache[streamId] = System.currentTimeMillis() to entries }
        return entries
    }

    fun liveUrl(streamId: Long) = "$server/live/$user/$pass/$streamId.m3u8"
    fun movieUrl(streamId: Long, ext: String) = "$server/movie/$user/$pass/$streamId.$ext"
    fun episodeUrl(episode: Episode) = "$server/series/$user/$pass/${episode.id}.${episode.ext}"
}
