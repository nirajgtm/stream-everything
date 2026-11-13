package com.nirajgtm.xtreamtv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.TextView
import com.nirajgtm.xtreamtv.data.Episode
import com.nirajgtm.xtreamtv.data.TmdbClient
import com.nirajgtm.xtreamtv.data.cleanEpisodeTitle
import com.nirajgtm.xtreamtv.data.displayTitle
import com.nirajgtm.xtreamtv.ui.buildEpisodeCard
import kotlin.concurrent.thread

/**
 * Lightweight episode browser opened straight from a search result, so every
 * source found by the search can be opened on its own without collapsing into
 * one series page. Season tabs + episode strip only — no hero, and no source
 * override is written until something is actually played.
 */
class SearchEpisodesActivity : Activity() {

    private val client by lazy { (application as XtreamApp).client }
    private val tmdb by lazy { (application as XtreamApp).tmdb }
    private val resume by lazy { (application as XtreamApp).resume }

    private lateinit var titleView: TextView
    private lateinit var status: TextView
    private lateinit var otherSourcesButton: android.widget.Button
    private lateinit var seasonHeader: LinearLayout
    private lateinit var episodeStrip: LinearLayout
    private lateinit var episodeStripScroll: android.widget.HorizontalScrollView

    private var seriesId = 0L
    private var seriesName = ""          // raw provider name (source-specific)
    private var cleanName = ""           // display name
    private var seriesTmdbId = 0
    private var seriesCover = ""
    private var seasons: List<Pair<Int, List<Episode>>> = emptyList()
    private var currentEpisodes: List<Episode> = emptyList()
    private var currentMeta: Map<Int, TmdbClient.EpisodeMeta> = emptyMap()
    private var selectedSeasonIndex = 0
    private var sources: List<com.nirajgtm.xtreamtv.data.Entry> = emptyList()
    private var focusEpisodeNumber = -1  // episode to re-anchor on after playing

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        seriesId = intent.getLongExtra("seriesId", 0L)
        seriesName = intent.getStringExtra("seriesName").orEmpty()
        if (seriesId == 0L) { finish(); return }
        cleanName = displayTitle(seriesName)

        titleView = TextView(this).apply {
            text = cleanName
            textSize = 28f; setTextColor(Color.WHITE); letterSpacing = 0.02f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
            maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
        }
        otherSourcesButton = android.widget.Button(this).apply {
            text = "Other sources"; textSize = 15f
            setOnClickListener { showSourceDialog() }
            setOnFocusChangeListener { _, _ -> stylePillButton(this) }
            stylePillButton(this)
        }
        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(56, 28, 56, 8)
            addView(titleView, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(otherSourcesButton, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                .apply { marginStart = 24 })
        }
        status = TextView(this).apply {
            textSize = 15f; setTextColor(Color.parseColor("#80CBC4"))
            setPadding(56, 0, 56, 8)
            text = "Loading episodes..."
        }
        seasonHeader = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            clipChildren = false; clipToPadding = false
        }
        val seasonScroll = android.widget.HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            isFocusable = false; isFocusableInTouchMode = false // chips take focus, this just scrolls
            descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
            clipChildren = false; clipToPadding = false
            setPadding(48, 6, 56, 6)
            addView(seasonHeader)
        }
        episodeStrip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setPadding(56, 12, 40, 12)
            clipChildren = false; clipToPadding = false // let the focused card's scaled border show
        }
        episodeStripScroll = android.widget.HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false; clipChildren = false; clipToPadding = false
            // The scroll container must NOT hold focus — the episode cards do, and
            // it auto-scrolls to follow them.
            isFocusable = false; isFocusableInTouchMode = false
            descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
            addView(episodeStrip)
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#0B0F14"))
            clipChildren = false; clipToPadding = false
            addView(topBar)
            addView(status)
            addView(seasonScroll)
            addView(episodeStripScroll, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(root)

        loadSeries(seriesId, seriesName)
    }

    /** Rounded pill styling matching the series-page buttons. */
    private fun stylePillButton(button: android.widget.Button) {
        val focused = button.isFocused
        button.stateListAnimator = null
        button.elevation = 0f
        button.background = com.nirajgtm.xtreamtv.ui.Squircle(
            if (focused) Color.WHITE else Color.parseColor("#33FFFFFF"))
        button.setTextColor(if (focused) Color.parseColor("#0B0F14") else Color.WHITE)
        button.isAllCaps = false
        button.setPadding(44, 18, 44, 18)
        button.scaleX = if (focused) 1.04f else 1f
        button.scaleY = if (focused) 1.04f else 1f
    }

    private fun loadSeries(id: Long, rawName: String) {
        seriesId = id
        seriesName = rawName
        cleanName = displayTitle(rawName)
        titleView.text = cleanName
        status.visibility = View.VISIBLE
        status.text = "Loading $cleanName..."
        thread {
            try {
                val detail = client.seriesDetail(id)
                val fetched = detail.episodes
                runOnUiThread {
                    seriesTmdbId = detail.tmdbId
                    seriesCover = detail.cover
                    seasons = fetched.groupBy { it.season }.toSortedMap()
                        .map { (season, eps) -> season to eps.sortedBy { it.number } }
                    if (seasons.isEmpty()) {
                        seasonHeader.removeAllViews()
                        episodeStrip.removeAllViews()
                        currentEpisodes = emptyList()
                        status.text = "No episodes on this source — try Other sources"
                        otherSourcesButton.post { otherSourcesButton.requestFocus() }
                        return@runOnUiThread
                    }
                    status.visibility = View.GONE
                    focusEpisodeNumber = -1
                    renderSeasonChips()
                    showSeason(0)
                }
            } catch (e: Exception) {
                runOnUiThread {
                    status.visibility = View.VISIBLE
                    status.text = "Could not load episodes: ${e.message}"
                }
            }
        }
    }

    /** Build a tab per season; the active one is highlighted. Rebuilt per source. */
    private fun renderSeasonChips() {
        seasonHeader.removeAllViews()
        seasons.forEachIndexed { index, seasonPair ->
            val chip = android.widget.Button(this).apply {
                text = "Season ${seasonPair.first}"; isAllCaps = false; textSize = 17f
                setPadding(40, 14, 40, 14)
                setOnClickListener { if (index != selectedSeasonIndex) showSeason(index) }
                setOnFocusChangeListener { _, _ -> styleSeasonChip(this, index == selectedSeasonIndex) }
                styleSeasonChip(this, index == selectedSeasonIndex)
            }
            seasonHeader.addView(chip, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT)
                .apply { marginEnd = 14 })
        }
    }

    private fun updateSeasonChipStyles() {
        for (i in 0 until seasonHeader.childCount)
            (seasonHeader.getChildAt(i) as? android.widget.Button)?.let { styleSeasonChip(it, i == selectedSeasonIndex) }
    }

    private fun styleSeasonChip(button: android.widget.Button, active: Boolean) {
        val focused = button.isFocused
        // The default button elevation/state animator paints a square surface behind
        // our rounded drawable, so drop both. Do NOT clipToOutline: outline clipping
        // is not antialiased and leaves visibly hard edges where the curve starts —
        // the drawable below already paints smooth, antialiased corners on its own.
        button.stateListAnimator = null
        button.elevation = 0f
        button.outlineProvider = android.view.ViewOutlineProvider.BACKGROUND
        button.clipToOutline = false
        button.setTypeface(null, if (active) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL)
        button.background = com.nirajgtm.xtreamtv.ui.Squircle(when {
            focused -> Color.WHITE
            active -> Color.parseColor("#2A3540")
            else -> Color.parseColor("#1A2029") // subtle pill so the shape always reads
        })
        button.setTextColor(when {
            focused -> Color.parseColor("#0B0F14")
            active -> Color.WHITE
            else -> Color.parseColor("#8A93A0")
        })
    }

    private fun showSeason(seasonIndex: Int) {
        val season = seasons.getOrNull(seasonIndex) ?: return
        selectedSeasonIndex = seasonIndex
        currentEpisodes = season.second
        currentMeta = emptyMap()
        updateSeasonChipStyles()
        renderEpisodes(anchorFocus = true) // provider data instantly...
        // ...then enrich with real names/overviews/stills from TMDB.
        val tmdbId = seriesTmdbId; val seasonNum = season.first
        if (tmdbId != 0) thread {
            val meta = tmdb.seasonEpisodes(tmdbId, seasonNum)
            if (meta.isNotEmpty()) runOnUiThread {
                if (selectedSeasonIndex == seasonIndex) {
                    currentMeta = meta
                    renderEpisodes(anchorFocus = false)
                }
            }
        }
    }

    /** Rebuild the strip; keeps the focused card (or re-anchors the D-pad on one). */
    private fun renderEpisodes(anchorFocus: Boolean) {
        val keepIndex = episodeStrip.indexOfChild(episodeStrip.focusedChild).takeIf { it >= 0 }
        episodeStrip.removeAllViews()
        currentEpisodes.forEach { ep ->
            episodeStrip.addView(buildEpisodeCard(this, ep, currentMeta[ep.number], resume) { playEpisode(ep) })
        }
        val target = keepIndex
            ?: currentEpisodes.indexOfFirst { it.number == focusEpisodeNumber }.takeIf { it >= 0 }
            ?: 0
        if (keepIndex == null && anchorFocus) episodeStripScroll.scrollTo(0, 0)
        if (keepIndex != null || anchorFocus)
            episodeStrip.post { episodeStrip.getChildAt(target)?.requestFocus() }
    }

    private fun seriesSourceLabel(name: String): String {
        val prefix = name.substringBefore(" - ", "").trim()
        val country = Regex("\\(([A-Za-z]{2})\\)\\s*$").find(name)?.groupValues?.get(1)?.uppercase() ?: ""
        return listOf(prefix, country).filter { it.isNotBlank() }.joinToString("  ·  ").ifBlank { name }
    }

    private fun showSourceDialog() {
        if (sources.isEmpty()) {
            status.visibility = View.VISIBLE
            status.text = "Finding sources for $cleanName…"
            val name = seriesName
            thread {
                val list = client.sourcesFor(name, true)
                runOnUiThread {
                    sources = list
                    status.visibility = View.GONE
                    showSourceList()
                }
            }
        } else showSourceList()
    }

    private fun showSourceList() {
        if (sources.size < 2) {
            android.widget.Toast.makeText(this, "No other sources found", android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        val labels = sources.map { seriesSourceLabel(it.name) }.toTypedArray()
        android.app.AlertDialog.Builder(this)
            .setTitle("Other sources (${sources.size})")
            // Browsing only — the default source is set when you actually play.
            .setItems(labels) { _, which ->
                val entry = sources[which]
                loadSeries(entry.id, entry.name)
            }
            .show()
    }

    private fun episodeLabel(episode: Episode): String {
        val title = cleanEpisodeTitle(episode.title).ifEmpty { "Episode ${episode.number}" }
        return "$cleanName  S${episode.season} E${episode.number}  $title"
    }

    private fun playEpisode(episode: Episode) {
        val key = "ep:${episode.id}"
        val url = client.episodeUrl(episode)
        val label = episodeLabel(episode)
        focusEpisodeNumber = episode.number
        // Use the high-quality series cover, not the low-res episode still.
        val poster = seriesCover.ifBlank { episode.thumb }
        resume.remember(key, label, poster, "series", url,
            seriesId = seriesId, seriesName = cleanName,
            season = episode.season, episodeNum = episode.number)
        // Playing from this source makes it the default for this series.
        val titleKey = client.titleKeyOf(seriesName)
        if (titleKey.isNotBlank()) resume.setSourceOverride(titleKey, seriesId, cleanName, "")
        // NOTE: deliberately no pendingSeriesReturn here — that global makes
        // MainActivity take over and open the full series page on the way back.
        // Whole series in order (across all seasons) so the player can step
        // forward AND back between episodes and roll over season boundaries.
        val all = seasons.flatMap { it.second }
        val startIndex = all.indexOfFirst { it.id == episode.id }.coerceAtLeast(0)
        startActivity(Intent(this, PlayerActivity::class.java)
            .putExtra("url", url)
            .putExtra("title", label)
            .putExtra("resumeKey", key)
            .putExtra("resumePosition", resume.resumePosition(key))
            .putExtra("ovPoster", poster)
            .putExtra("ovTitle", label)
            .putExtra("ovPlot", episode.plot)
            .putExtra("ovSeriesId", seriesId)
            .putExtra("epStartIndex", startIndex)
            .putStringArrayListExtra("epUrls", ArrayList(all.map { client.episodeUrl(it) }))
            .putStringArrayListExtra("epTitles", ArrayList(all.map { episodeLabel(it) }))
            .putStringArrayListExtra("epKeys", ArrayList(all.map { "ep:${it.id}" }))
            .putStringArrayListExtra("epPlots", ArrayList(all.map { it.plot }))
            .putExtra("epSeasons", all.map { it.season }.toIntArray())
            .putExtra("epNums", all.map { it.number }.toIntArray()))
    }

    override fun onResume() {
        super.onResume()
        // Re-render so the watched-progress bars pick up what was just played.
        if (currentEpisodes.isNotEmpty()) renderEpisodes(anchorFocus = true)
    }
}
