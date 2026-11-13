package com.nirajgtm.xtreamtv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.nirajgtm.xtreamtv.data.MovieInfo
import com.nirajgtm.xtreamtv.data.TitleParser
import com.nirajgtm.xtreamtv.ui.ImageLoader
import com.nirajgtm.xtreamtv.ui.pillStrip
import kotlin.concurrent.thread

/** Movie detail: poster, plot, and Play / Resume / Trailer, before playing. */
class DetailActivity : Activity() {

    private lateinit var poster: ImageView
    private lateinit var backdropView: ImageView
    private lateinit var plotView: TextView
    private lateinit var metaView: TextView
    private lateinit var buttons: LinearLayout
    private lateinit var castLabel: TextView
    private lateinit var castRow: LinearLayout
    private lateinit var castScroll: android.widget.HorizontalScrollView
    private lateinit var posterProgress: View
    private lateinit var posterPrefetch: View // translucent: downloaded so far
    private var posterWatchedFrac = 0f
    private val prefetchTicker = android.os.Handler(android.os.Looper.getMainLooper())

    private var vodId = 0L
    private lateinit var rawName: String
    private lateinit var ext: String
    private var trailer: String = ""
    private var posterUrl: String = ""
    private var infoPlot: String = ""
    private var infoYear: String = ""
    private var infoCast: String = ""
    private lateinit var titleKey: String
    private var sources: List<com.nirajgtm.xtreamtv.data.Entry> = emptyList()

    private val resumeKey get() = "movie:$vodId"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        vodId = intent.getLongExtra("id", 0L)
        rawName = intent.getStringExtra("name") ?: ""
        ext = intent.getStringExtra("ext") ?: "mp4"
        titleKey = (application as XtreamApp).client.titleKeyOf(rawName)

        val parsed = TitleParser.parse(rawName)

        // Dimmed backdrop behind everything (Apple TV-style hero).
        backdropView = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP; alpha = 0.30f
        }
        val scrim = View(this).apply { setBackgroundColor(Color.parseColor("#D90B0F14")) }

        poster = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            setBackgroundColor(Color.parseColor("#22303C"))
        }
        posterPrefetch = View(this).apply {
            setBackgroundColor(Color.parseColor("#59FFFFFF")); visibility = View.GONE
        }
        posterProgress = View(this).apply {
            setBackgroundColor(Color.parseColor("#80CBC4")); visibility = View.GONE
        }
        val posterWrap = android.widget.FrameLayout(this).apply {
            addView(poster, android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(posterPrefetch, android.widget.FrameLayout.LayoutParams(
                0, 8, Gravity.BOTTOM or Gravity.START))
            addView(posterProgress, android.widget.FrameLayout.LayoutParams(
                0, 8, Gravity.BOTTOM or Gravity.START))
        }
        val title = TextView(this).apply {
            text = parsed.clean; textSize = 34f; setTextColor(Color.WHITE)
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        val pills = pillStrip(this, parsed.pills)
        metaView = TextView(this).apply {
            textSize = 15f; setTextColor(Color.parseColor("#9FB3C0")); setPadding(0, 10, 0, 12)
        }
        buttons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setPadding(0, 4, 0, 16)
        }
        plotView = TextView(this).apply {
            text = "Loading details..."; textSize = 16f
            setTextColor(Color.parseColor("#CCD6DD")); setLineSpacing(6f, 1f)
        }
        castLabel = TextView(this).apply {
            text = "Cast"; textSize = 15f; setTextColor(Color.WHITE)
            setPadding(0, 24, 0, 10); visibility = View.GONE
        }
        castRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        castScroll = android.widget.HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false; addView(castRow); visibility = View.GONE
        }
        val scrollBody = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(plotView); addView(castLabel); addView(castScroll)
        }
        val rightCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 0, 0, 0)
            addView(title); addView(pills); addView(metaView); addView(buttons)
            addView(ScrollView(this@DetailActivity).apply { addView(scrollBody) },
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        val contentRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(56, 48, 56, 40)
            addView(posterWrap, LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 0.30f))
            addView(rightCol, LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 0.70f))
        }
        val root = android.widget.FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor("#0B0F14"))
            addView(backdropView, android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(scrim, android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(contentRow, android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        setContentView(root)

        // Apply a saved source choice cheaply (no catalog scan), then load info.
        (application as XtreamApp).resume.sourceOverride(titleKey)?.takeIf {
            it.name.isNotBlank() && it.id != vodId
        }?.let { vodId = it.id; rawName = it.name; ext = it.ext.ifEmpty { "mp4" } }
        refreshButtons()
        loadInfo()
    }

    private fun sourceLabel(name: String): String {
        val prefix = name.substringBefore(" - ", "").trim()
        val country = Regex("\\(([A-Za-z]{2})\\)\\s*$").find(name)?.groupValues?.get(1)?.uppercase() ?: ""
        return listOf(prefix, country).filter { it.isNotBlank() }.joinToString("  ·  ").ifBlank { name }
    }

    /** Scan for sources only when asked (the scan is expensive on a big catalog). */
    private fun showSourceDialog() {
        if (sources.isEmpty()) {
            android.widget.Toast.makeText(this, "Finding sources…", android.widget.Toast.LENGTH_SHORT).show()
            thread {
                val list = (application as XtreamApp).client.sourcesFor(rawName, false)
                runOnUiThread { sources = list; showSourceList() }
            }
        } else showSourceList()
    }

    private fun showSourceList() {
        if (sources.size < 2) {
            android.widget.Toast.makeText(this, "No other sources found", android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        val labels = sources.map { sourceLabel(it.name) }.toTypedArray()
        android.app.AlertDialog.Builder(this)
            .setTitle("Other sources (${sources.size})")
            .setItems(labels) { _, which -> switchSource(sources[which]) }
            .show()
    }

    private fun switchSource(entry: com.nirajgtm.xtreamtv.data.Entry) {
        vodId = entry.id; rawName = entry.name; ext = entry.ext.ifEmpty { "mp4" }
        infoPlot = ""; infoYear = ""; infoCast = ""; trailer = ""
        plotView.text = "Loading details..."
        android.widget.Toast.makeText(this, "Source: ${sourceLabel(entry.name)}", android.widget.Toast.LENGTH_SHORT).show()
        loadInfo(); refreshButtons()
    }

    private fun addButton(text: String, isPrimary: Boolean = false, onClick: () -> Unit): Button {
        val button = Button(this).apply {
            this.text = text
            textSize = 16f
            setOnClickListener { onClick() }
            setOnFocusChangeListener { _, _ -> styleHeroButton(this, isPrimary) }
            styleHeroButton(this, isPrimary)
        }
        buttons.addView(button, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = 16 })
        return button
    }

    /** Pill-shaped hero button matching the series landing page. */
    private fun styleHeroButton(button: Button, isPrimary: Boolean) {
        val filled = isPrimary || button.isFocused
        button.stateListAnimator = null
        button.elevation = 0f
        button.background = com.nirajgtm.xtreamtv.ui.Squircle(
            if (filled) Color.WHITE else Color.parseColor("#33FFFFFF"))
        button.setTextColor(if (filled) Color.parseColor("#0B0F14") else Color.WHITE)
        button.isAllCaps = false
        button.setPadding(44, 18, 44, 18)
        button.scaleX = if (button.isFocused) 1.04f else 1f
        button.scaleY = if (button.isFocused) 1.04f else 1f
    }

    private fun refreshButtons() {
        buttons.removeAllViews()
        val store = (application as XtreamApp).resume
        if (store.hasResume(resumeKey)) {
            val mins = store.resumePosition(resumeKey) / 60000
            addButton("▶  Resume (${mins}m)", isPrimary = true) { play(fromStart = false) }.also { it.requestFocus() }
            addButton("Play from start") { play(fromStart = true) }
        } else {
            addButton("▶  Play", isPrimary = true) { play(fromStart = true) }.also { it.requestFocus() }
        }
        if (trailer.isNotBlank()) addButton("Trailer") { openTrailer() }
        addButton("Other sources") { showSourceDialog() }
        // Watched (teal) + downloaded (translucent) along the poster's bottom edge.
        // Widths are applied by the repeating ticker so a cold, unmeasured poster
        // (width 0 on first layout) still fills once it has been measured.
        posterWatchedFrac = store.watchedFraction(resumeKey)
        posterProgress.visibility = if (posterWatchedFrac > 0.02f) View.VISIBLE else View.GONE
    }

    private fun loadInfo() {
        thread {
            val info: MovieInfo? = try {
                (application as XtreamApp).client.movieInfo(vodId)
            } catch (_: Exception) { null }
            runOnUiThread {
                if (info == null) {
                    plotView.text = "Details unavailable (provider offline). You can still play."
                    return@runOnUiThread
                }
                posterUrl = info.poster
                infoPlot = info.plot; infoYear = info.year; infoCast = info.cast
                ImageLoader.load(poster, info.poster, Color.parseColor("#22303C"))
                ImageLoader.load(backdropView, info.backdrop.ifBlank { info.poster }, Color.parseColor("#0B0F14"), maxDim = 1280)
                plotView.text = info.plot.ifBlank { "No description available." }
                metaView.text = listOfNotNull(
                    info.year.ifBlank { null },
                    info.genre.ifBlank { null },
                    if (info.durationSecs > 0) "${info.durationSecs / 60} min" else null,
                    info.rating.ifBlank { null }?.let { "★ $it" }
                ).joinToString("   •   ")
                trailer = info.trailer
                refreshButtons()
                loadCast(info.tmdbId, info.cast)
            }
        }
    }

    /** Apple TV-style cast row: circular headshots from TMDB, or names as a fallback. */
    private fun loadCast(tmdbId: Int, fallbackNames: String) {
        thread {
            val members = (application as XtreamApp).tmdb.castWithImages(tmdbId, isSeries = false)
            runOnUiThread {
                castRow.removeAllViews()
                if (members.isNotEmpty()) {
                    members.forEach { castRow.addView(com.nirajgtm.xtreamtv.ui.buildCastCard(this, it.name, it.character, it.profileUrl)) }
                    castLabel.visibility = View.VISIBLE; castScroll.visibility = View.VISIBLE
                } else if (fallbackNames.isNotBlank()) {
                    fallbackNames.split(",").map { it.trim() }.filter { it.isNotEmpty() }
                        .forEach { castRow.addView(com.nirajgtm.xtreamtv.ui.buildCastCard(this, it, "", "")) }
                    castLabel.visibility = View.VISIBLE; castScroll.visibility = View.VISIBLE
                } else {
                    castLabel.visibility = View.GONE; castScroll.visibility = View.GONE
                }
            }
        }
    }


    override fun onPause() {
        super.onPause()
        prefetchTicker.removeCallbacksAndMessages(null)
        // Only stop when leaving the app entirely; going into the player must keep
        // the fill running, since that is what playback reads from.
        if (isFinishing) (application as XtreamApp).aheadCache.stop()
    }

    /** Paint the translucent downloaded segment along the poster's bottom edge. */
    private fun setBar(v: View, px: Int) {
        v.layoutParams = (v.layoutParams as android.widget.FrameLayout.LayoutParams).apply { width = px }
        v.requestLayout()
    }

    private fun startPrefetchTicker() {
        prefetchTicker.removeCallbacksAndMessages(null)
        val tick = object : Runnable {
            override fun run() {
                val w = poster.width
                if (w > 0) {
                    if (posterWatchedFrac > 0.02f)
                        setBar(posterProgress, (w * posterWatchedFrac).toInt())
                    val span = (application as XtreamApp).aheadCache.prefetchedSpanFractions()
                    if (span != null) {
                        posterPrefetch.visibility = View.VISIBLE
                        setBar(posterPrefetch, (w * span.second).toInt())
                    }
                }
                prefetchTicker.postDelayed(this, 1_000)
            }
        }
        prefetchTicker.post(tick)
    }

    private fun play(fromStart: Boolean) {
        val store = (application as XtreamApp).resume
        val position = if (fromStart) 0L else store.resumePosition(resumeKey)
        val url = (application as XtreamApp).client.movieUrl(vodId, ext)
        val title = TitleParser.parse(rawName).clean
        store.remember(resumeKey, title, posterUrl, "movie", url)
        store.setSourceOverride(titleKey, vodId, rawName, ext) // becomes the default for this movie
        startActivity(Intent(this, PlayerActivity::class.java)
            .putExtra("url", url)
            .putExtra("title", title)
            .putExtra("resumeKey", resumeKey)
            .putExtra("resumePosition", position)
            .putExtra("ovPoster", posterUrl)
            .putExtra("ovTitle", title)
            .putExtra("ovYear", infoYear)
            .putExtra("ovPlot", infoPlot)
            .putExtra("ovCast", infoCast))
    }

    private fun openTrailer() {
        val uri = if (trailer.startsWith("http")) Uri.parse(trailer)
        else Uri.parse("https://www.youtube.com/watch?v=$trailer")
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
        } catch (_: Exception) {
            metaView.text = "No app available to play the trailer."
        }
    }

    override fun onResume() {
        super.onResume()
        // Start pulling this title down now, so pressing Play reads from disk
        // rather than opening a connection and waiting for it to buffer.
        run { // always: pressing Play should read from disk, not the network
            val app = application as XtreamApp
            // Resume point as a fraction, so the fill starts where playback will.
            val fraction = app.resume.watchedFraction(resumeKey).toDouble()
            val url = app.client.movieUrl(vodId, ext)
            app.activeMediaUrl = url            // on screen: its cache is protected
            app.aheadCache.prepare(url, fraction)
        }
        startPrefetchTicker()
        refreshButtons() // reflect a position saved while watching
    }
}
