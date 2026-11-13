package com.nirajgtm.xtreamtv.data

import android.content.Context
import android.database.Cursor
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.util.JsonReader
import android.util.JsonToken
import android.util.LruCache
import java.io.Closeable
import java.io.File
import java.io.FileReader

/**
 * Disk-backed catalog. Replaces the in-RAM `List<Entry>` catalogs with SQLite so a
 * 200k+ row provider catalog costs a few MB of page cache instead of hundreds of MB
 * of Java objects, and so a cold start is an open() rather than a full parse.
 *
 * Design notes:
 *
 * - **All derived columns are computed at ingest time** (norm, lang, bucket, title
 *   keys, preference score) so queries never have to touch Kotlin code per row.
 *
 * - **LIKE, not FTS5.** [normalizeForSearch] strips every separator, so "The
 *   Back-Rooms" becomes the single token `thebackrooms`. Matching a query word
 *   against that needs *infix substring* search, which an FTS5 index cannot do (it
 *   is prefix-only). FTS5 is also not guaranteed to be compiled into the platform
 *   SQLite on API 21. A plain `norm LIKE '%token%'` scan over one narrow column is
 *   fast enough because the session streams a cursor instead of materializing hits.
 *
 * - **Nothing in here duplicates the catalog's business rules.** The derivation
 *   helpers ([normalizeForSearch], [detectLang], `preferenceScore`, `addTitleKeys`,
 *   [LiveCatalog.bucketOf]) live in `XtreamClient.kt` / `LiveCatalog.kt`; the two
 *   that are private there are supplied by the caller through [Derivations], so
 *   `XtreamClient` can pass its own implementations without this file forking them.
 *
 * Every method here does disk I/O: call them off the UI thread.
 */
class CatalogDb(context: Context) :
    SQLiteOpenHelper(context.applicationContext, DB_NAME, null, DB_VERSION) {

    init {
        // WAL: readers (browse/search) never block on the ingest writer.
        setWriteAheadLoggingEnabled(true)
    }

    /**
     * The per-row derivations, injected because two of them are private to
     * `XtreamClient` and this file must not fork them. [norm], [lang] and [bucket]
     * default to the public top-level helpers; implementors only have to supply the
     * two private ones.
     */
    interface Derivations {
        fun norm(name: String): String = normalizeForSearch(name)
        fun lang(name: String): String? = detectLang(name)
        fun bucket(name: String): String = LiveCatalog.bucketOf(name)

        /** `addTitleKeys` output: primary key first, article-stripped variant second. */
        fun titleKeys(name: String): List<String>

        /** `preferenceScore(name, ext)`: higher is the better duplicate. */
        fun preferenceScore(name: String, ext: String): Int
    }

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE entries (
                 row        INTEGER PRIMARY KEY AUTOINCREMENT,
                 kind       INTEGER NOT NULL,
                 stream_id  INTEGER NOT NULL,
                 name       TEXT    NOT NULL,
                 ext        TEXT    NOT NULL DEFAULT '',
                 logo       TEXT    NOT NULL DEFAULT '',
                 epg_id     TEXT    NOT NULL DEFAULT '',
                 archive    INTEGER NOT NULL DEFAULT 0,
                 norm       TEXT    NOT NULL,
                 lang       TEXT,
                 bucket     TEXT,
                 title_key  TEXT,
                 title_alt  TEXT,
                 pref_score INTEGER NOT NULL DEFAULT 0
               )"""
        )
        db.execSQL("CREATE INDEX idx_kind_lang     ON entries(kind, lang)")
        db.execSQL("CREATE INDEX idx_kind_streamid ON entries(kind, stream_id)")
        db.execSQL("CREATE INDEX idx_title_key     ON entries(kind, title_key)")
        db.execSQL("CREATE INDEX idx_title_alt     ON entries(kind, title_alt)")
        db.execSQL("CREATE INDEX idx_live_bucket   ON entries(bucket) WHERE kind = 0")
        db.execSQL(
            """CREATE TABLE catalog_meta (
                 kind INTEGER PRIMARY KEY, fetched_at INTEGER,
                 row_count INTEGER, schema_version INTEGER
               )"""
        )
    }

    /** The catalog is a cache of the provider's data: throw it away and re-ingest. */
    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        db.execSQL("DROP TABLE IF EXISTS entries")
        db.execSQL("DROP TABLE IF EXISTS catalog_meta")
        onCreate(db)
    }

    override fun onDowngrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) =
        onUpgrade(db, oldVersion, newVersion)

    // ---- Ingest ----

    /**
     * Stream [jsonFile] (a raw provider `get_live_streams` / `get_vod_streams` /
     * `get_series` response) straight into `entries`, one prepared INSERT per row
     * inside a single transaction. No `List<Entry>` is ever built, so peak RAM is
     * one row regardless of catalog size. Returns the number of rows written.
     *
     * Rows are appended: use [replaceKind] to swap a catalog atomically.
     */
    fun ingest(kind: Kind, jsonFile: File, derive: Derivations): Int {
        val db = writableDatabase
        db.beginTransaction()
        try {
            val count = ingestInto(db, kind, jsonFile, derive)
            db.setTransactionSuccessful()
            return count
        } finally {
            db.endTransaction()
        }
    }

    /**
     * Atomically swap one catalog: delete the old rows, ingest the new ones and
     * stamp `catalog_meta`, all in one transaction. An ingest that throws part-way
     * rolls the whole thing back, so a reader either sees the previous catalog or
     * (on a first run) sees [hasKind] == false — never a half-written one.
     */
    fun replaceKind(kind: Kind, jsonFile: File, derive: Derivations): Int {
        val db = writableDatabase
        db.beginTransaction()
        try {
            db.execSQL("DELETE FROM entries WHERE kind = ?", arrayOf<Any>(kind.ordinal))
            val count = ingestInto(db, kind, jsonFile, derive)
            db.execSQL(
                "INSERT OR REPLACE INTO catalog_meta(kind, fetched_at, row_count, schema_version)" +
                    " VALUES(?,?,?,?)",
                arrayOf<Any>(kind.ordinal, System.currentTimeMillis(), count, SCHEMA_VERSION)
            )
            db.setTransactionSuccessful()
            return count
        } finally {
            db.endTransaction()
        }
    }

    private fun ingestInto(db: SQLiteDatabase, kind: Kind, jsonFile: File, derive: Derivations): Int {
        val insert = db.compileStatement(
            "INSERT INTO entries(kind, stream_id, name, ext, logo, epg_id, archive," +
                " norm, lang, bucket, title_key, title_alt, pref_score)" +
                " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)"
        )
        var written = 0
        insert.use { statement ->
            JsonReader(FileReader(jsonFile)).use { reader ->
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
                            "name" -> name = reader.stringOrEmpty()
                            "stream_id" -> streamId = reader.nextLong()
                            "series_id" -> seriesId = reader.nextLong()
                            "container_extension" -> ext = reader.stringOrEmpty()
                            "stream_icon" -> logo = reader.stringOrEmpty()
                            "epg_channel_id" -> epgId = reader.stringOrEmpty()
                            "tv_archive" -> archive = reader.intOrZero()
                            else -> reader.skipValue()
                        }
                    }
                    reader.endObject()
                    val id = if (streamId != 0L) streamId else seriesId
                    if (name.isEmpty() || id == 0L) continue

                    val keys = if (kind == Kind.LIVE) emptyList() else derive.titleKeys(name)
                    statement.clearBindings()
                    statement.bindLong(1, kind.ordinal.toLong())
                    statement.bindLong(2, id)
                    statement.bindString(3, name)
                    statement.bindString(4, ext)
                    statement.bindString(5, logo)
                    statement.bindString(6, epgId)
                    statement.bindLong(7, archive.toLong())
                    statement.bindString(8, derive.norm(name))
                    statement.bindOrNull(9, derive.lang(name))
                    statement.bindOrNull(10, if (kind == Kind.LIVE) derive.bucket(name) else null)
                    statement.bindOrNull(11, keys.getOrNull(0)?.ifEmpty { null })
                    statement.bindOrNull(12, keys.getOrNull(1)?.ifEmpty { null })
                    statement.bindLong(13, derive.preferenceScore(name, ext).toLong())
                    statement.executeInsert()
                    written++
                }
                reader.endArray()
            }
        }
        return written
    }

    private fun JsonReader.stringOrEmpty(): String =
        if (peek() == JsonToken.NULL) { nextNull(); "" } else nextString()

    /** tv_archive comes back as a number, sometimes a string; tolerate both. */
    private fun JsonReader.intOrZero(): Int = when (peek()) {
        JsonToken.NULL -> { nextNull(); 0 }
        JsonToken.STRING -> nextString().toIntOrNull() ?: 0
        else -> try { nextInt() } catch (_: Exception) { 0 }
    }

    private fun android.database.sqlite.SQLiteStatement.bindOrNull(index: Int, value: String?) {
        if (value == null) bindNull(index) else bindString(index, value)
    }

    // ---- Catalog state ----

    /** True once [replaceKind] has committed a non-empty catalog for [kind]. */
    /** Wipe every catalogue row (used when switching Xtream accounts). */
    fun clearAll() {
        writableDatabase.apply {
            beginTransaction()
            try {
                delete("entries", null, null)
                delete("catalog_meta", null, null)
                setTransactionSuccessful()
            } finally { endTransaction() }
        }
    }

    fun hasKind(kind: Kind): Boolean = longOf(
        "SELECT row_count FROM catalog_meta WHERE kind = ?", arrayOf(kind.ordinal.toString())
    ) > 0

    fun count(kind: Kind): Int = longOf(
        "SELECT COUNT(*) FROM entries WHERE kind = ?", arrayOf(kind.ordinal.toString())
    ).toInt()

    /** Wall-clock millis of the last successful ingest, or 0 if never. */
    fun fetchedAt(kind: Kind): Long = longOf(
        "SELECT fetched_at FROM catalog_meta WHERE kind = ?", arrayOf(kind.ordinal.toString())
    )

    /**
     * The schema version the rows for [kind] were written with. Callers compare it
     * against [SCHEMA_VERSION] and re-ingest when the derivations have changed
     * (new bucket rules, a new preference score) even though the JSON has not.
     */
    fun schemaVersionOf(kind: Kind): Int = longOf(
        "SELECT schema_version FROM catalog_meta WHERE kind = ?", arrayOf(kind.ordinal.toString())
    ).toInt()

    /** True when [kind] is missing or was ingested by an older derivation set. */
    fun needsIngest(kind: Kind): Boolean =
        !hasKind(kind) || schemaVersionOf(kind) != SCHEMA_VERSION

    private fun longOf(sql: String, args: Array<String>): Long =
        readableDatabase.rawQuery(sql, args).use { if (it.moveToFirst()) it.getLong(0) else 0L }

    // ---- Search ----

    fun newSearch(query: String, kind: Kind? = null, lang: String? = null): DbSearchSession =
        DbSearchSession(query, kind, lang)

    /**
     * Paged search backed by one open cursor. Every query word must appear somewhere
     * in the normalized name ("back room" matches "The Backrooms"); names containing
     * the words joined together rank first. Untagged titles (no language prefix)
     * always pass the language filter.
     *
     * The cursor is opened once and walked forward across [next] calls, so paging
     * costs nothing extra — unlike LIMIT/OFFSET, which re-runs the scan per page.
     * Callers MUST [close] it.
     */
    inner class DbSearchSession(query: String, kind: Kind?, lang: String?) : Closeable {
        private val parsed = ParsedQuery(query)
        val valid: Boolean = parsed.valid

        var exhausted = !valid; private set

        private val cursor: Cursor? = if (!valid) null else run {
            val args = ArrayList<String>()
            args.add(likePattern(parsed.whole))
            args.add(likePattern(parsed.core))
            val where = StringBuilder()
            for (token in parsed.tokens) {
                if (where.isNotEmpty()) where.append(" AND ")
                where.append("norm LIKE ? ESCAPE '\\'")
                args.add(likePattern(token))
            }
            if (kind != null) {
                where.append(" AND kind = ?")
                args.add(kind.ordinal.toString())
            }
            if (lang != null) {
                where.append(" AND (lang IS NULL OR lang = ?)")
                args.add(lang)
            }
            readableDatabase.rawQuery(
                "SELECT kind, name, stream_id, ext," +
                    " CASE WHEN norm LIKE ? ESCAPE '\\' THEN 0" +
                    "      WHEN norm LIKE ? ESCAPE '\\' THEN 1 ELSE 2 END AS rank" +
                    " FROM entries WHERE $where ORDER BY rank, kind, row",
                args.toTypedArray()
            )
        }

        fun next(count: Int): List<SearchResult> {
            val cursor = cursor ?: return emptyList()
            if (exhausted) return emptyList()
            val page = ArrayList<SearchResult>(count)
            while (page.size < count) {
                if (!cursor.moveToNext()) {
                    exhausted = true
                    break
                }
                val kind = Kind.values()[cursor.getInt(0)]
                val ext = if (kind == Kind.MOVIE) cursor.getString(3).ifEmpty { "mp4" } else ""
                page.add(SearchResult(kind, cursor.getString(1), cursor.getLong(2), ext))
            }
            return page
        }

        override fun close() {
            cursor?.close()
        }
    }

    /**
     * Full-catalog counts for the query, used to show only filters that lead
     * somewhere. Cross-filtered: kind counts respect the language filter and
     * language counts respect the kind filter. [whole] and [core] are accepted for
     * parity with the search session's ranking but do not affect the counts.
     */
    @Suppress("UNUSED_PARAMETER")
    fun availability(
        tokens: List<String>, whole: String, core: String, kind: Kind?, lang: String?
    ): XtreamClient.Availability {
        val db = readableDatabase
        val tokenWhere = tokens.joinToString(" AND ") { "norm LIKE ? ESCAPE '\\'" }
            .ifEmpty { "1" }
        val tokenArgs = tokens.map { likePattern(it) }

        val kinds = HashMap<Kind, Int>()
        val kindArgs = ArrayList(tokenArgs)
        var kindWhere = tokenWhere
        if (lang != null) {
            kindWhere += " AND (lang IS NULL OR lang = ?)"
            kindArgs.add(lang)
        }
        db.rawQuery(
            "SELECT kind, COUNT(*) FROM entries WHERE $kindWhere GROUP BY kind",
            kindArgs.toTypedArray()
        ).use { cursor ->
            while (cursor.moveToNext()) kinds[Kind.values()[cursor.getInt(0)]] = cursor.getInt(1)
        }

        val langs = HashMap<String, Int>()
        var untagged = 0
        val langArgs = ArrayList(tokenArgs)
        var langWhere = tokenWhere
        if (kind != null) {
            langWhere += " AND kind = ?"
            langArgs.add(kind.ordinal.toString())
        }
        db.rawQuery(
            "SELECT lang, COUNT(*) FROM entries WHERE $langWhere GROUP BY lang",
            langArgs.toTypedArray()
        ).use { cursor ->
            while (cursor.moveToNext()) {
                if (cursor.isNull(0)) untagged = cursor.getInt(1)
                else langs[cursor.getString(0)] = cursor.getInt(1)
            }
        }
        return XtreamClient.Availability(kinds, langs, untagged)
    }

    /** Language codes present in the catalog, most common first. */
    fun languages(minCount: Int = 200): List<String> {
        val out = ArrayList<String>()
        readableDatabase.rawQuery(
            "SELECT lang, COUNT(*) c FROM entries WHERE lang IS NOT NULL" +
                " GROUP BY lang HAVING c >= ? ORDER BY c DESC",
            arrayOf(minCount.toString())
        ).use { cursor ->
            while (cursor.moveToNext()) out.add(cursor.getString(0))
        }
        return out
    }

    // ---- Title matching (external rails -> playable catalog entry) ----

    /**
     * The best catalog row whose title matches any of [keys] (`addTitleKeys` output
     * for the external title). "Best" is the highest `pref_score` — the same
     * quality/audio preference the in-RAM index applied when de-duplicating titles.
     * Returns (stream_id, name, ext), or null when the catalog can't play it.
     */
    fun findByTitle(kind: Kind, keys: List<String>): Triple<Long, String, String>? {
        val usable = keys.filter { it.isNotEmpty() }
        if (usable.isEmpty()) return null
        val holes = usable.joinToString(",") { "?" }
        val args = ArrayList<String>()
        args.add(kind.ordinal.toString())
        args.addAll(usable)
        args.addAll(usable)
        return readableDatabase.rawQuery(
            "SELECT stream_id, name, ext FROM entries" +
                " WHERE kind = ? AND (title_key IN ($holes) OR title_alt IN ($holes))" +
                " ORDER BY pref_score DESC LIMIT 1",
            args.toTypedArray()
        ).use { cursor ->
            if (cursor.moveToFirst())
                Triple(cursor.getLong(0), cursor.getString(1), cursor.getString(2))
            else null
        }
    }

    /**
     * Every catalog entry that is the same title as [key] (all source/quality/
     * language duplicates), best first. Powers the "Other sources" picker.
     */
    fun sourcesFor(kind: Kind, key: String): List<Entry> {
        if (key.isEmpty()) return emptyList()
        return readableDatabase.rawQuery(
            "SELECT $ENTRY_COLUMNS FROM entries" +
                " WHERE kind = ? AND (title_key = ? OR title_alt = ?)" +
                " ORDER BY pref_score DESC",
            arrayOf(kind.ordinal.toString(), key, key)
        ).use { it.toEntries() }
    }

    // ---- Live browse ----

    private val logoCache = LruCache<Long, String>(512)

    /** Channel logo URL by stream id; indexed single-row lookup, memoized. */
    fun liveLogo(streamId: Long): String {
        logoCache.get(streamId)?.let { return it }
        val logo = readableDatabase.rawQuery(
            "SELECT logo FROM entries WHERE kind = ? AND stream_id = ? LIMIT 1",
            arrayOf(Kind.LIVE.ordinal.toString(), streamId.toString())
        ).use { if (it.moveToFirst()) it.getString(0) else "" }
        logoCache.put(streamId, logo)
        return logo
    }

    /** Live language buckets with their channel counts, biggest first, "Other" last. */
    fun liveGroupCounts(): List<Pair<String, Int>> {
        val out = ArrayList<Pair<String, Int>>()
        readableDatabase.rawQuery(
            "SELECT bucket, COUNT(*) c FROM entries WHERE kind = ? AND bucket IS NOT NULL" +
                " GROUP BY bucket ORDER BY (bucket = 'Other'), c DESC",
            arrayOf(Kind.LIVE.ordinal.toString())
        ).use { cursor ->
            while (cursor.moveToNext()) out.add(cursor.getString(0) to cursor.getInt(1))
        }
        return out
    }

    /** One page of [liveBucketChannels], plus the cursor to pass as the next `afterRow`. */
    class Page(val items: List<Entry>, val nextRow: Long)

    /**
     * Keyset paging: `row > afterRow` walks an index range in constant time per
     * page, where a growing OFFSET would re-scan everything already shown. Start
     * with `afterRow = 0` and feed [Page.nextRow] back in for the next page.
     */
    fun liveBucketPage(bucket: String, afterRow: Long = 0, limit: Int): Page {
        var last = afterRow
        val items = readableDatabase.rawQuery(
            "SELECT row, $ENTRY_COLUMNS FROM entries" +
                " WHERE kind = ? AND bucket = ? AND row > ? ORDER BY row LIMIT ?",
            arrayOf(Kind.LIVE.ordinal.toString(), bucket, afterRow.toString(), limit.toString())
        ).use { cursor ->
            val out = ArrayList<Entry>(limit)
            while (cursor.moveToNext()) {
                last = cursor.getLong(0)
                out.add(cursor.toEntry(1))
            }
            out
        }
        return Page(items, last)
    }

    fun liveBucketChannels(bucket: String, afterRow: Long = 0, limit: Int): List<Entry> =
        liveBucketPage(bucket, afterRow, limit).items

    /** Channels matching a [LiveCatalog.SmartList]'s keys, in catalog order. */
    fun liveSmartList(keys: List<String>, limit: Int): List<Entry> {
        if (keys.isEmpty()) return emptyList()
        val args = ArrayList<String>()
        args.add(Kind.LIVE.ordinal.toString())
        val matches = keys.joinToString(" OR ") {
            args.add(likePattern(it)); "name LIKE ? ESCAPE '\\'"
        }
        args.add(limit.toString())
        return readableDatabase.rawQuery(
            "SELECT $ENTRY_COLUMNS FROM entries WHERE kind = ? AND ($matches)" +
                " ORDER BY row LIMIT ?",
            args.toTypedArray()
        ).use { it.toEntries() }
    }

    /** Favorited channels, in catalog order. Chunked to stay under the bind-var cap. */
    fun liveFavorites(ids: Collection<Long>): List<Entry> {
        if (ids.isEmpty()) return emptyList()
        val out = ArrayList<Entry>(ids.size)
        for (chunk in ids.chunked(BIND_LIMIT)) {
            val args = ArrayList<String>(chunk.size + 1)
            args.add(Kind.LIVE.ordinal.toString())
            chunk.forEach { args.add(it.toString()) }
            readableDatabase.rawQuery(
                "SELECT $ENTRY_COLUMNS FROM entries WHERE kind = ? AND stream_id IN (" +
                    chunk.joinToString(",") { "?" } + ") ORDER BY row",
                args.toTypedArray()
            ).use { out.addAll(it.toEntries()) }
        }
        return out
    }

    // ---- Row plumbing ----

    private fun Cursor.toEntry(offset: Int = 0) = Entry(
        getString(offset), getLong(offset + 1), getString(offset + 2),
        getString(offset + 3), getString(offset + 4), getInt(offset + 5)
    )

    private fun Cursor.toEntries(): List<Entry> {
        val out = ArrayList<Entry>(count)
        while (moveToNext()) out.add(toEntry())
        return out
    }

    companion object {
        private const val DB_NAME = "catalog.db"
        private const val DB_VERSION = 1

        /**
         * Bumped whenever a derived column's meaning changes (new bucket rules, a
         * new preference score, a new title-key shape). Callers compare it against
         * `catalog_meta.schema_version` via [needsIngest] and re-ingest the JSON.
         */
        const val SCHEMA_VERSION = 1

        /** SQLITE_MAX_VARIABLE_NUMBER is 999 on old platform SQLite; stay well under. */
        private const val BIND_LIMIT = 900

        private const val ENTRY_COLUMNS = "name, stream_id, ext, logo, epg_id, archive"

        /**
         * A `%value%` LIKE pattern with the wildcards in [value] neutralized. Query
         * tokens come out of [normalizeForSearch] (letters and digits only) so this
         * is belt-and-braces, but smart-list keys are raw text.
         */
        private fun likePattern(value: String): String =
            "%" + value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
    }
}
