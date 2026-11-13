package com.nirajgtm.xtreamtv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.nirajgtm.xtreamtv.data.Kind
import com.nirajgtm.xtreamtv.data.SearchResult
import com.nirajgtm.xtreamtv.data.TmdbClient
import com.nirajgtm.xtreamtv.data.TmdbItem
import com.nirajgtm.xtreamtv.ui.ImageLoader
import kotlin.concurrent.thread

/** A per-provider browse screen: New / Popular / Top Rated / genre rails, all
 *  filtered to the catalog. Reused for every provider via the "providerKey" extra. */
class ProviderHubActivity : Activity() {

    private lateinit var rails: LinearLayout
    private lateinit var provider: TmdbClient.Provider
    private val tmdb by lazy { (application as XtreamApp).tmdb }
    private val client by lazy { (application as XtreamApp).client }
    private val voiceRequest = 4712

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val key = intent.getIntExtra("providerKey", -1)
        provider = tmdb.providers.firstOrNull { it.key == key }
            ?: run { finish(); return }

        val logo = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
            setBackgroundColor(Color.parseColor("#0B0F14"))
        }
        val name = TextView(this).apply {
            text = provider.label
            textSize = 26f
            setTextColor(Color.WHITE)
            setPadding(24, 0, 24, 0)
        }
        val mic = android.widget.Button(this).apply {
            text = "🎤 Search"
            isAllCaps = false
            setOnClickListener { launchVoiceSearch() }
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = android.view.Gravity.CENTER_VERTICAL
            setPadding(24, 20, 24, 12)
            addView(logo, LinearLayout.LayoutParams(120, 68))
            addView(name, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(mic)
        }

        rails = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#101820"))
            addView(header)
            addView(ScrollView(this@ProviderHubActivity).apply {
                isFillViewport = true; addView(rails)
            }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(root)

        thread {
            val logoUrl = tmdb.providerLogoUrl(provider)
            runOnUiThread { ImageLoader.load(logo, logoUrl, Color.parseColor("#0B0F14")) }
        }
        thread {
            if (!client.loaded) client.loadCatalogs { }
            if (!client.moviesLoaded) client.loadMovies { } // hub resolves movie titles
            runOnUiThread { buildRails() }
        }
    }

    private val hubCache by lazy {
        com.nirajgtm.xtreamtv.data.HomeCache(java.io.File(filesDir, "hub_${provider.key}.json"))
    }

    // Watchmode per-service ranks, preferred over TMDB order wherever present.
    // Each map is cached 24h on disk and budget-guarded; an empty map (error,
    // no key, or exhausted monthly quota) leaves the TMDB order untouched.
    private val watchmode by lazy { (application as XtreamApp).watchmode }
    private fun byRank(ranks: Map<Int, Int>, items: List<TmdbItem>): List<TmdbItem> =
        if (ranks.isEmpty()) items else items.sortedBy { ranks[it.tmdbId] ?: Int.MAX_VALUE }

    private fun buildRails() {
        val wm = provider.watchmodeId
        val specs: List<Pair<String, () -> List<TmdbItem>>> = buildList {
            add("New on ${provider.label}" to { byRank(watchmode.newRanks(wm), tmdb.newOn(provider)) })
            add("Popular Movies" to { byRank(watchmode.popularRanks(wm), tmdb.popularMovies(provider)) })
            add("Popular Shows" to { byRank(watchmode.popularRanks(wm), tmdb.popularShows(provider)) })
            add("Top Rated" to { tmdb.topRated(provider) }) // Watchmode has no rating sort
            for (g in tmdb.genres) add(g.label to { byRank(watchmode.genreRanks(wm, g.watchmodeId), tmdb.byGenre(provider, g)) })
        }
        // Reserve ordered slots now (UI thread).
        val slots = specs.map {
            LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }.also { rails.addView(it) }
        }
        // Instant render from the last snapshot, then refresh only if stale (>6h).
        val snap = hubCache.load()
        snap?.rails?.forEachIndexed { i, rail -> if (i < slots.size) renderRailData(slots[i], rail) }
        val stale = hubCache.age(System.currentTimeMillis()) > 6L * 60 * 60 * 1000
        if (snap != null && !stale) return

        thread {
            val collected = java.util.concurrent.ConcurrentHashMap<Int, com.nirajgtm.xtreamtv.data.RailData>()
            val pool = java.util.concurrent.Executors.newFixedThreadPool(4,
                com.nirajgtm.xtreamtv.util.Threads.lowPriorityFactory("hub"))
            specs.forEachIndexed { i, (title, fetch) ->
                pool.execute {
                    val items = try { fetch() } catch (_: Exception) { emptyList() }
                    fillRail(slots[i], title, items) { collected[i] = it }
                }
            }
            pool.shutdown()
            pool.awaitTermination(120, java.util.concurrent.TimeUnit.SECONDS)
            val ordered = specs.indices.mapNotNull { collected[it] }
            hubCache.save(com.nirajgtm.xtreamtv.data.HomeSnapshot(System.currentTimeMillis(), ordered))
        }
    }

    private fun fillRail(into: LinearLayout, title: String, items: List<TmdbItem>,
                         collector: (com.nirajgtm.xtreamtv.data.RailData) -> Unit) {
        val available = ArrayList<Pair<TmdbItem, SearchResult>>()
        for (item in items) {
            client.findByTitle(item.title, item.isSeries)?.let { available.add(item to it) }
            if (available.size >= 20) break
        }
        if (available.isEmpty()) return
        val store = (application as XtreamApp).resume
        fun started(r: SearchResult) = r.kind == Kind.MOVIE && store.hasResume("movie:${r.id}")
        val ordered = available.sortedByDescending { started(it.second) }
        collector(com.nirajgtm.xtreamtv.data.RailData(title, -1, "", ordered.map { (item, r) ->
            com.nirajgtm.xtreamtv.data.CardData(item.title, r.name, r.kind.ordinal, r.id, r.ext,
                item.posterUrl, item.overview, item.tmdbId, item.year)
        }))
        runOnUiThread {
            into.removeAllViews()
            into.addView(com.nirajgtm.xtreamtv.ui.buildRail(this, title, ordered.size,
                { card, i ->
                    val prefix = if (started(ordered[i].second)) "▶ " else ""
                    card.bind(prefix + ordered[i].first.title, ordered[i].first.posterUrl)
                },
                { i -> openResult(ordered[i].second) },
                expandFor = { i ->
                    val item = ordered[i].first
                    com.nirajgtm.xtreamtv.ui.ExpandData(item.title, item.year, item.isSeries,
                        item.overview) { tmdb.castFor(item.tmdbId, item.isSeries) }
                }))
        }
    }

    /** Render a rail from a saved snapshot (instant, no network). */
    private fun renderRailData(into: LinearLayout, rail: com.nirajgtm.xtreamtv.data.RailData) {
        if (rail.cards.isEmpty()) return
        val store = (application as XtreamApp).resume
        fun started(c: com.nirajgtm.xtreamtv.data.CardData) =
            c.kind == Kind.MOVIE.ordinal && store.hasResume("movie:${c.id}")
        into.removeAllViews()
        into.addView(com.nirajgtm.xtreamtv.ui.buildRail(this, rail.title, rail.cards.size,
            { card, i ->
                val c = rail.cards[i]
                card.bind((if (started(c)) "▶ " else "") + c.display, c.poster)
            },
            { i ->
                val c = rail.cards[i]
                openResult(SearchResult(Kind.values()[c.kind], c.name, c.id, c.ext))
            },
            expandFor = { i ->
                val c = rail.cards[i]
                if (c.overview.isBlank() && c.tmdbId == 0) null
                else com.nirajgtm.xtreamtv.ui.ExpandData(c.display, c.year,
                    c.kind == Kind.SERIES.ordinal, c.overview) { tmdb.castFor(c.tmdbId, c.kind == Kind.SERIES.ordinal) }
            }))
    }

    private var focusToRestore: View? = null

    override fun onResume() {
        super.onResume()
        focusToRestore?.let { v ->
            focusToRestore = null
            if (v.isAttachedToWindow) v.post { v.requestFocus() }
        }
    }

    private fun openResult(result: SearchResult) {
        focusToRestore = currentFocus
        // Watching from this hub ranks the platform on the home rails.
        (application as XtreamApp).affinity.recordPlay(provider.key)
        when (result.kind) {
            Kind.MOVIE -> startActivity(Intent(this, DetailActivity::class.java)
                .putExtra("id", result.id).putExtra("name", result.name).putExtra("ext", result.ext))
            Kind.SERIES -> startActivity(Intent(this, MainActivity::class.java)
                .putExtra("openSeriesId", result.id).putExtra("openSeriesName", result.name)
                .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP))
            Kind.LIVE -> {}
        }
    }

    private fun launchVoiceSearch() {
        val intent = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(android.speech.RecognizerIntent.EXTRA_PROMPT, "Speak to search")
        }
        try { startActivityForResult(intent, voiceRequest) } catch (_: Exception) {}
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == voiceRequest && resultCode == RESULT_OK) {
            val spoken = data?.getStringArrayListExtra(
                android.speech.RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
            if (!spoken.isNullOrBlank()) sendToSearch(spoken)
        }
    }

    private fun sendToSearch(query: String) {
        startActivity(Intent(this, MainActivity::class.java)
            .putExtra("prefillQuery", query)
            .addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_SEARCH, KeyEvent.KEYCODE_VOICE_ASSIST,
                KeyEvent.KEYCODE_ASSIST -> { launchVoiceSearch(); return true }
            }
        }
        return super.dispatchKeyEvent(event)
    }
}
