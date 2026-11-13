package com.nirajgtm.xtreamtv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextWatcher
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import com.nirajgtm.xtreamtv.data.Episode
import com.nirajgtm.xtreamtv.data.Kind
import com.nirajgtm.xtreamtv.data.SearchResult
import com.nirajgtm.xtreamtv.data.XtreamClient
import com.nirajgtm.xtreamtv.data.cleanEpisodeTitle
import com.nirajgtm.xtreamtv.data.detectLang
import com.nirajgtm.xtreamtv.data.displayTitle
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class MainActivity : Activity() {

    private enum class Mode { HOME, RESULTS, SERIES }

    private lateinit var client: XtreamClient
    private lateinit var status: TextView
    private lateinit var searchBox: EditText
    private lateinit var filterRow: LinearLayout
    private lateinit var resultsList: ListView
    private lateinit var seriesPane: View
    private lateinit var topChrome: LinearLayout
    private lateinit var seriesMetaView: TextView
    private lateinit var seriesStarringView: TextView
    private lateinit var seasonHeader: LinearLayout // holds the season tab chips
    private lateinit var resumeProgressTrack: android.widget.FrameLayout
    private lateinit var resumeProgressFill: View
    private lateinit var resumePrefetchFill: View // translucent: how much is downloaded
    private var heroWatchedFrac = 0f
    private val prefetchBarHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private lateinit var episodeStrip: LinearLayout
    private lateinit var episodeStripScroll: android.widget.HorizontalScrollView
    private lateinit var playButton: android.widget.Button
    private var selectedSeasonIndex = 0
    private lateinit var homeScroll: android.widget.ScrollView
    private lateinit var homeRails: LinearLayout

    private var mode = Mode.HOME
    private var homeBuilt = false
    private val tmdb by lazy { (application as XtreamApp).tmdb }

    private val results = mutableListOf<SearchResult>()
    private var resultsAdapter: ResultsAdapter? = null
    private var resultsPreview: com.nirajgtm.xtreamtv.ui.ChannelPreviewController? = null
    private var liveByIdCache: Map<Long, com.nirajgtm.xtreamtv.data.Entry>? = null

    /** id -> live Entry (for logos in search results); empty until the catalog loads. */
    private fun liveById(): Map<Long, com.nirajgtm.xtreamtv.data.Entry> {
        liveByIdCache?.let { return it }
        if (!client.loaded) return emptyMap()
        return client.live.associateBy { it.id }.also { liveByIdCache = it }
    }
    private var session: XtreamClient.SearchSession? = null
    private var loadingMore = false
    private var searchGen = 0

    private var selectedKind: Kind? = null
    private var selectedLang: String? = null // no language filter by default
    private var availability: XtreamClient.Availability? = null
    private val kindButtons = mutableMapOf<Kind?, android.widget.Button>()
    private lateinit var langButton: android.widget.Button
    private lateinit var clearButton: android.widget.Button

    private var seasons: List<Pair<Int, List<Episode>>> = emptyList()
    private var currentEpisodes: List<Episode> = emptyList()
    private var currentSeriesName = ""
    private var currentSeriesId = 0L
    private lateinit var otherSourcesButton: android.widget.Button
    private lateinit var seriesInfoView: TextView
    private lateinit var seriesBackdrop: ImageView
    private lateinit var seriesTitleView: TextView
    private var currentSeriesTmdbId = 0
    private var currentSeriesBackdrop = ""
    private var seriesSources: List<com.nirajgtm.xtreamtv.data.Entry> = emptyList()
    private var seriesTitleKey = ""
    private var currentSeriesPlot = ""
    private var currentSeriesCast = ""
    private var currentSeriesMeta = ""
    private var currentSeriesCover = ""
    private var focusSeason = -1     // season to preselect when the series opens
    private var focusEpisodeNum = -1 // episode to focus when the series opens
    private var pendingReturnToSeries: com.nirajgtm.xtreamtv.data.ResumeStore.Mark? = null

    private var catalogsReady = false

    private val pageSize = 100
    private val searchDebounceMs = 200L
    private val refreshCheckIntervalMs = 2L * 60 * 60 * 1000
    private val refreshHandler = Handler(Looper.getMainLooper())
    private val searchHandler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        client = (application as XtreamApp).client

        status = TextView(this).apply {
            textSize = 16f
            setTextColor(Color.parseColor("#80CBC4"))
            setPadding(24, 16, 24, 8)
            text = "Starting..."
        }
        searchBox = EditText(this).apply {
            hint = "Search channels, movies, series"
            setHintTextColor(Color.parseColor("#557788"))
            setTextColor(Color.WHITE)
            textSize = 20f
            isSingleLine = true
            setPadding(24, 16, 24, 16)
            // Enabled from the start so it's the default focus; the text watcher
            // ignores input until catalogs are ready.
            // Do NOT auto-raise the on-screen keyboard when this field gains focus.
            // On a TV the field is focused on startup and on every return from the
            // player; auto-binding the IME each time leaves it in an "evicted" state
            // that silently swallows every D-pad press, freezing the remote. The
            // keyboard still opens when the user actually clicks the field to type.
            showSoftInputOnFocus = false
        }
        val micButton = android.widget.Button(this).apply {
            text = "🎤"
            textSize = 20f
            setOnClickListener { launchVoiceSearch() }
            setOnFocusChangeListener { v, f ->
                v.setBackgroundColor(Color.parseColor(if (f) "#80CBC4" else "#22303C"))
            }
            setBackgroundColor(Color.parseColor("#22303C"))
        }
        val settingsButton = android.widget.Button(this).apply {
            text = "⚙"
            textSize = 20f
            contentDescription = "Settings"
            isFocusable = true
            setOnClickListener { startActivityForResult(SettingsActivity.intent(this@MainActivity), SETTINGS_REQUEST) }
            setOnFocusChangeListener { v, f ->
                v.setBackgroundColor(Color.parseColor(if (f) "#80CBC4" else "#22303C"))
            }
            setBackgroundColor(Color.parseColor("#22303C"))
        }
        val searchRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(searchBox, LinearLayout.LayoutParams(0,
                LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            addView(micButton)
            addView(settingsButton)
        }

        filterRow = buildFilterRow()

        resultsList = ListView(this)
        otherSourcesButton = android.widget.Button(this).apply {
            text = "Other sources"; textSize = 15f
            setOnClickListener { showSeriesSourceDialog() }
            setOnFocusChangeListener { _, _ -> styleHeroButton(this, isPrimary = false) }
            styleHeroButton(this, isPrimary = false)
        }
        playButton = android.widget.Button(this).apply {
            text = "Play"; textSize = 17f
            setOnClickListener { playHeroEpisode() }
            setOnFocusChangeListener { _, _ -> styleHeroButton(this, isPrimary = true) }
            styleHeroButton(this, isPrimary = true)
        }
        // ---- Full-bleed hero (top) : backdrop + gradient + title/meta/desc/buttons ----
        seriesBackdrop = ImageView(this).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            setBackgroundColor(Color.parseColor("#0B0F14"))
        }
        val heroGradient = View(this).apply {
            background = android.graphics.drawable.GradientDrawable(
                android.graphics.drawable.GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(Color.parseColor("#000B0F14"), Color.parseColor("#B30B0F14"), Color.parseColor("#FF0B0F14")))
        }
        seriesTitleView = TextView(this).apply {
            textSize = 42f; setTextColor(Color.WHITE); letterSpacing = 0.04f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        }
        seriesMetaView = TextView(this).apply {
            textSize = 14f; setTextColor(Color.parseColor("#9FB3C0")); setPadding(0, 8, 0, 8)
        }
        seriesInfoView = TextView(this).apply {
            textSize = 15f; setTextColor(Color.parseColor("#C7D3DA")); setLineSpacing(4f, 1f)
            maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END
        }
        seriesStarringView = TextView(this).apply {
            textSize = 14f; setTextColor(Color.parseColor("#9FB3C0"))
            gravity = Gravity.END; maxLines = 3; ellipsize = android.text.TextUtils.TruncateAt.END
        }
        val heroButtons = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setPadding(0, 20, 0, 0)
            addView(playButton)
            addView(otherSourcesButton, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                .apply { marginStart = 20 })
        }
        // Watched-progress bar under the Resume button (how far into the episode).
        resumeProgressFill = View(this).apply { setBackgroundColor(Color.parseColor("#80CBC4")) }
        resumePrefetchFill = View(this).apply { setBackgroundColor(Color.parseColor("#59FFFFFF")) }
        resumeProgressTrack = android.widget.FrameLayout(this).apply {
            setBackgroundColor(Color.parseColor("#40FFFFFF"))
            visibility = View.GONE
            addView(resumePrefetchFill, android.widget.FrameLayout.LayoutParams(0, 8))
            addView(resumeProgressFill, android.widget.FrameLayout.LayoutParams(0, 8))
        }
        val heroTextCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(seriesTitleView); addView(seriesInfoView); addView(seriesMetaView); addView(heroButtons)
            addView(resumeProgressTrack, LinearLayout.LayoutParams(360, 8)
                .apply { topMargin = 16 })
        }
        val heroOverlay = android.widget.FrameLayout(this).apply {
            setPadding(56, 40, 56, 28)
            addView(heroTextCol, android.widget.FrameLayout.LayoutParams(
                (resources.displayMetrics.widthPixels * 0.62f).toInt(),
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.START))
            addView(seriesStarringView, android.widget.FrameLayout.LayoutParams(
                (resources.displayMetrics.widthPixels * 0.28f).toInt(),
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM or Gravity.END))
        }
        val heroFrame = android.widget.FrameLayout(this).apply {
            addView(seriesBackdrop, android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(heroGradient, android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(heroOverlay, android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        // ---- Bottom : visible season tabs + horizontal episode strip ----
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
        val bottomSection = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#0B0F14"))
            setPadding(0, 14, 0, 20)
            clipChildren = false; clipToPadding = false
            addView(seasonScroll)
            addView(episodeStripScroll, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        // Simple, robust two-section layout: hero on top, episode strip below —
        // both visible, no translation/clip tricks (those broke focus + scrolling).
        seriesPane = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            visibility = View.GONE
            setBackgroundColor(Color.parseColor("#0B0F14"))
            addView(heroFrame, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 0.47f))
            addView(bottomSection, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 0.53f))
        }

        homeRails = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        homeScroll = android.widget.ScrollView(this).apply {
            isFillViewport = true
            addView(homeRails)
        }

        val content = android.widget.FrameLayout(this).apply {
            addView(homeScroll)
            addView(resultsList)
            addView(seriesPane)
        }

        topChrome = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(status); addView(searchRow); addView(filterRow)
        }
        val layout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#101820"))
            addView(topChrome)
            addView(content, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(layout)

        searchBox.addTextChangedListener(object : TextWatcher {
            override fun afterTextChanged(s: Editable?) {
                if (!catalogsReady || mode == Mode.SERIES) return
                val query = s?.toString().orEmpty()
                checkFilterPhrase(query)
                if (query.isBlank()) showHome() else { showResults(); scheduleSearch(query) }
            }
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        })

        resultsList.setOnItemClickListener { _, _, position, _ ->
            results.getOrNull(position)?.let { onSearchResultClicked(it) }
        }
        resultsList.setOnScrollListener(object : AbsListView.OnScrollListener {
            override fun onScroll(view: AbsListView?, first: Int, visible: Int, total: Int) {
                val current = session ?: return
                if (mode != Mode.RESULTS || loadingMore || current.exhausted) return
                if (total > 0 && first + visible >= total - 20) loadMore(current)
            }
            override fun onScrollStateChanged(view: AbsListView?, state: Int) {}
        })
        // Live search results preview (with sound) on the focused row.
        resultsPreview = com.nirajgtm.xtreamtv.ui.ChannelPreviewController(this, resultsList) { pos ->
            results.getOrNull(pos)?.takeIf { it.kind == Kind.LIVE }?.let { it.id to client.liveUrl(it.id) }
        }.also { it.attach() }

        applyAdultFilter(settings.adultFilter) // ON unless previously unlocked
        buildHomeSkeleton()
        showHome()
        searchBox.requestFocus()
        // With no account there is nothing to load: ask for one first. Builds with
        // credentials baked in skip straight past this.
        if (!credentials.isConfigured) {
            status.text = "Set up your Xtream account to get started."
            startActivityForResult(SettingsActivity.intent(this), SETTINGS_REQUEST)
            return
        }
        loadCatalogs()
        handleLaunchExtras(intent)
    }

    private val credentials by lazy { com.nirajgtm.xtreamtv.data.XtreamCredentials(this) }

    // Opened from a provider hub: prefill search or open a specific series.
    private var pendingQuery: String? = null
    private var pendingSeries: Pair<Long, String>? = null

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleLaunchExtras(intent)
    }

    private fun handleLaunchExtras(intent: Intent?) {
        intent?.getStringExtra("prefillQuery")?.let {
            pendingQuery = it; intent.removeExtra("prefillQuery")
        }
        val sid = intent?.getLongExtra("openSeriesId", 0L) ?: 0L
        if (sid != 0L) {
            pendingSeries = sid to (intent!!.getStringExtra("openSeriesName") ?: "")
            intent.removeExtra("openSeriesId")
        }
        applyPendingIfReady()
    }

    private fun applyPendingIfReady() {
        if (!catalogsReady) return
        pendingQuery?.let { q ->
            pendingQuery = null
            if (mode == Mode.SERIES) exitSeriesMode()
            searchBox.setText(q); searchBox.setSelection(q.length); searchBox.requestFocus()
        }
        pendingSeries?.let { (id, name) ->
            pendingSeries = null
            openSeries(SearchResult(Kind.SERIES, name, id))
        }
    }

    // ---- Filters ----

    private fun buildFilterRow(): LinearLayout {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(16, 0, 16, 8)
        }
        fun chip(text: String, onClick: () -> Unit): android.widget.Button =
            android.widget.Button(this).apply {
                this.text = text
                textSize = 14f
                isAllCaps = false
                setOnClickListener { onClick() }
                setOnFocusChangeListener { _, _ -> styleFilterButtons() }
                row.addView(this, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT).apply { marginEnd = 8 })
            }

        kindButtons[null] = chip("All") { selectKind(null) }
        kindButtons[Kind.LIVE] = chip("Live") { selectKind(Kind.LIVE) }
        kindButtons[Kind.MOVIE] = chip("Movies") { selectKind(Kind.MOVIE) }
        kindButtons[Kind.SERIES] = chip("Series") { selectKind(Kind.SERIES) }
        langButton = chip("Lang: All") { pickLanguage() }
        clearButton = chip("Clear") {
            searchBox.setText("")
            searchBox.requestFocus()
        }
        styleFilterButtons()
        return row
    }

    private fun selectKind(kind: Kind?) {
        selectedKind = kind
        styleFilterButtons()
        scheduleSearch(searchBox.text.toString())
    }

    private fun pickLanguage() {
        val counts = availability
        val langs: List<String>
        val labels: Array<String>
        if (counts != null) {
            langs = counts.langs.entries.sortedByDescending { it.value }.map { it.key }
            val untaggedNote = if (counts.untagged > 0) " (+${counts.untagged} untagged)" else ""
            labels = arrayOf("All languages$untaggedNote") +
                langs.map { "$it (${counts.langs[it]})" }.toTypedArray()
        } else {
            langs = client.languages()
            labels = arrayOf("All languages") + langs.toTypedArray()
        }
        val checked = if (selectedLang == null) 0 else (langs.indexOf(selectedLang) + 1)
        android.app.AlertDialog.Builder(this)
            .setTitle("Language (titles without a language tag always show)")
            .setSingleChoiceItems(labels, checked) { dialog, which ->
                selectedLang = if (which == 0) null else langs[which - 1]
                langButton.text = "Lang: ${selectedLang ?: "All"}"
                dialog.dismiss()
                scheduleSearch(searchBox.text.toString())
            }
            .show()
    }

    private fun styleFilterButtons() {
        for ((kind, button) in kindButtons) applyChipStyle(button, kind == selectedKind)
        applyChipStyle(langButton, false)
        applyChipStyle(clearButton, false)
    }

    /**
     * Selected chip: teal fill. Focused chip (where the D-pad cursor is):
     * white border and lighter fill. Both can apply at once.
     */
    private fun applyChipStyle(button: android.widget.Button, selected: Boolean) {
        val focused = button.isFocused
        val fill = when {
            selected -> "#80CBC4"
            focused -> "#3A5064"
            else -> "#22303C"
        }
        button.stateListAnimator = null // the default elevation paints a square surface
        button.elevation = 0f
        button.background = com.nirajgtm.xtreamtv.ui.Squircle(
            fillColor = Color.parseColor(fill),
            strokeColor = if (focused) Color.WHITE else Color.TRANSPARENT,
            strokeWidthPx = if (focused) 4f else 0f)
        button.setTextColor(Color.parseColor(if (selected) "#101820" else "#FFFFFF"))
    }

    private fun updateFilterAvailability() {
        val counts = availability
        for ((kind, button) in kindButtons) {
            if (kind == null) {
                button.text = "All"
                button.visibility = View.VISIBLE
                continue
            }
            val count = counts?.kinds?.get(kind)
            val base = when (kind) {
                Kind.LIVE -> "Live"; Kind.MOVIE -> "Movies"; Kind.SERIES -> "Series"
            }
            when {
                counts == null -> { button.text = base; button.visibility = View.VISIBLE }
                count == null || count == 0 ->
                    button.visibility = if (selectedKind == kind) View.VISIBLE else View.GONE
                else -> { button.text = "$base ($count)"; button.visibility = View.VISIBLE }
            }
        }
    }

    // ---- Catalog loading ----

    private fun loadCatalogs() {
        if (client.loaded) {
            setReady()
            loadMoviesInBackground()
            return
        }
        thread {
            android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND)
            try {
                client.loadCatalogs { message -> runOnUiThread { status.text = message } }
                runOnUiThread { setReady() }
                loadMoviesInBackground()
            } catch (e: Exception) {
                runOnUiThread { status.text = "Load failed: ${e.message}. Restart app to retry." }
            }
        }
    }

    /** The big movies catalog loads after the app is already usable; when it lands,
     *  refresh the count, re-run any active search, and start the stale-check timer. */
    private fun loadMoviesInBackground() {
        // Queued, not a free-for-all thread: the movies catalog, title indexing and
        // the TMDB rail rebuild used to run at once and saturate the device exactly
        // while the user was trying to navigate.
        (application as XtreamApp).background.submit {
            try { client.refreshAccountLimits() } catch (_: Exception) {} // gates prefetching
            try { client.loadMovies { } } catch (_: Exception) {}
            try { client.warmTitleIndexes() } catch (_: Exception) {} // movie hubs/rails ready
            runOnUiThread {
                updateReadyStatus()
                if (mode == Mode.RESULTS) scheduleSearch(searchBox.text.toString())
                scheduleRefreshCheck(0)
            }
        }
    }

    private fun setReady() {
        catalogsReady = true
        thread { android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_BACKGROUND); liveById() } // warm the 57k id->channel map off the UI thread
        searchBox.hint = "Search channels, movies, series"
        updateReadyStatus()
        focusSearchBar()
        // Refresh the TMDB rails only if the on-disk snapshot is missing or older than 6h.
        val sixHours = 6L * 60 * 60 * 1000
        val stale = (application as XtreamApp).homeCache.age(System.currentTimeMillis()) > sixHours
        if (stale) rebuildTmdbRails()
        // else: title indexes are warmed by loadMoviesInBackground() once movies land.
        applyPendingIfReady()
    }

    /** Home status line; shows movie count once the deferred catalog is in. */
    private fun updateReadyStatus() {
        if (mode != Mode.HOME) return
        val moviesPart = if (client.moviesLoaded) "${client.movies.size} movies" else "indexing movies…"
        status.text = "Type to search  ·  ${client.live.size} channels, " +
            "$moviesPart, ${client.series.size} series"
    }

    /** Default focus on home is the search bar, not the mic or a rail card. */
    private fun focusSearchBar() {
        if (mode == Mode.HOME) searchBox.post { if (mode == Mode.HOME) searchBox.requestFocus() }
    }

    // ---- View mode switching ----

    private fun showHome() {
        // Leaving the results list must silence its preview: this is a view swap
        // inside one Activity, so onPause never fires and the channel would keep
        // playing over the home screen.
        resultsPreview?.pause()
        mode = Mode.HOME
        topChrome.visibility = View.VISIBLE
        homeScroll.visibility = View.VISIBLE
        resultsList.visibility = View.GONE
        seriesPane.visibility = View.GONE
        filterRow.visibility = View.GONE
    }

    private fun showResults() {
        mode = Mode.RESULTS
        topChrome.visibility = View.VISIBLE
        homeScroll.visibility = View.GONE
        resultsList.visibility = View.VISIBLE
        seriesPane.visibility = View.GONE
        filterRow.visibility = View.VISIBLE
    }

    // ---- Home page ----

    // Fixed home order: Trending, Live TV, Continue Playing, then providers.
    private lateinit var trendingSlot: LinearLayout
    private lateinit var liveSlot: LinearLayout
    private lateinit var continueSlot: LinearLayout
    private lateinit var providersSlot: LinearLayout
    private lateinit var providerSubSlots: List<LinearLayout>

    /** Built once in onCreate (no catalogs needed) so home shows instantly. */
    private fun buildHomeSkeleton() {
        if (homeBuilt) return
        homeBuilt = true
        homeRails.removeAllViews()
        trendingSlot = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        liveSlot = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        continueSlot = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        providersSlot = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        homeRails.addView(trendingSlot)
        homeRails.addView(liveSlot)
        homeRails.addView(continueSlot)
        homeRails.addView(providersSlot)
        providerSubSlots = tmdb.providers.map {
            LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
                .also { providersSlot.addView(it) }
        }
        fillLiveTvRail()
        refreshContinuePlaying()
        renderSnapshot()
        applyProviderOrder()
    }

    /** Order the platform rails by how much you actually watch each one. Skipped
     *  while focus is inside them, so the rails never move under the cursor. */
    private fun applyProviderOrder() {
        if (!homeBuilt) return
        if (currentFocus?.let { isDescendantOf(it, providersSlot) } == true) return
        val ordered = (application as XtreamApp).affinity
            .ordered(tmdb.providers.indices.toList()) { tmdb.providers[it].key }
        if (ordered == tmdb.providers.indices.toList() && providersSlot.childCount > 0) return
        providersSlot.removeAllViews()
        ordered.forEach { providersSlot.addView(providerSubSlots[it]) }
    }

    private fun isDescendantOf(view: View, parent: ViewGroup): Boolean {
        var p = view.parent
        while (p != null) { if (p === parent) return true; p = (p as? View)?.parent }
        return false
    }

    /** Live TV tiles: languages you've watched (most-recent first) + All Live.
     *  Organic — a language appears here once you play a channel of it. */
    private var shownLiveLangs: List<String>? = null
    private var shownFavCount = -1

    private fun fillLiveTvRail() {
        if (!homeBuilt) return
        val watched = (application as XtreamApp).resume.recentLiveLangs()
        val favCount = (application as XtreamApp).resume.favoriteIds().size
        if (watched == shownLiveLangs && favCount == shownFavCount && liveSlot.childCount > 0) return
        shownLiveLangs = watched
        shownFavCount = favCount
        liveSlot.removeAllViews()
        // Favorites (if any) + Sports, then watched languages (recent first), then
        // All Live. The third field is the removable language (null = not removable).
        val tiles: List<Triple<String, () -> Unit, String?>> =
            (if (favCount > 0) listOf(Triple<String, () -> Unit, String?>("♥ Favorites", { openLive("", favorites = true) }, null)) else emptyList()) +
            listOf(Triple<String, () -> Unit, String?>("All Live", { openLive("") }, null)) +
            listOf(Triple<String, () -> Unit, String?>("Sports", { startActivity(Intent(this, SportsActivity::class.java)) }, null)) +
            watched.map { lang -> Triple<String, () -> Unit, String?>(lang, { openLive(lang) }, lang) }
        liveSlot.addView(com.nirajgtm.xtreamtv.ui.buildRail(this, "Live TV", tiles.size,
            { card, i -> card.bindArt(com.nirajgtm.xtreamtv.ui.TileArt.tile(tiles[i].first)) },
            { i -> tiles[i].second() },
            onLongClick = { i ->
                val lang = tiles[i].third
                if (lang != null) {
                    (application as XtreamApp).resume.removeLiveLang(lang)
                    android.widget.Toast.makeText(this, "Removed $lang from Live TV", android.widget.Toast.LENGTH_SHORT).show()
                    fillLiveTvRail()
                    true
                } else false
            }))
    }

    private fun openLive(lang: String, favorites: Boolean = false) {
        startActivity(Intent(this, LiveBrowseActivity::class.java)
            .putExtra("lang", lang).putExtra("favorites", favorites))
    }

    /** History of the last ~20 plays; long-press a card to remove it. Hidden when empty. */
    private fun refreshContinuePlaying() {
        if (!homeBuilt) return
        continueSlot.removeAllViews()
        // Collapsed: one card per series (its latest-played episode), not one per episode.
        val recent = (application as XtreamApp).resume.recentCollapsed(20)
        if (recent.isEmpty()) return
        continueSlot.addView(com.nirajgtm.xtreamtv.ui.buildRail(this, "Continue Playing", recent.size,
            { card, i ->
                card.bind(recent[i].second.title, recent[i].second.poster)
                val m = recent[i].second
                val watched = if (m.durationMs > 0) m.positionMs.toFloat() / m.durationMs else 0f
                val fetched = (application as XtreamApp).aheadCache
                    .prefetchedEndFraction(m.playUrl, watched.toDouble()) ?: 0f
                card.setProgress(watched, fetched)
            },
            { i -> resumeFromHistory(recent[i].first, recent[i].second) },
            onLongClick = { i -> confirmRemoveFromHistory(recent[i].first, recent[i].second.title); true }))
    }

    private fun confirmRemoveFromHistory(key: String, title: String) {
        android.app.AlertDialog.Builder(this)
            .setTitle("Remove from Continue Playing?")
            .setMessage(title)
            .setPositiveButton("Remove") { _, _ ->
                (application as XtreamApp).resume.remove(key)
                refreshContinuePlaying()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    // ---- Snapshot: instant render + background refresh ----

    private fun renderSnapshot() {
        val snap = (application as XtreamApp).homeCache.load() ?: return
        for (rail in snap.rails) {
            if (rail.providerKey == -1) renderRailData(trendingSlot, rail)
            else tmdb.providers.indexOfFirst { it.key == rail.providerKey }
                .takeIf { it >= 0 }?.let { renderRailData(providerSubSlots[it], rail) }
        }
    }

    private fun renderRailData(into: LinearLayout, rail: com.nirajgtm.xtreamtv.data.RailData) {
        if (rail.cards.isEmpty()) return
        val store = (application as XtreamApp).resume
        fun started(c: com.nirajgtm.xtreamtv.data.CardData) =
            c.kind == Kind.MOVIE.ordinal && store.hasResume("movie:${c.id}")
        val hub = if (rail.providerKey != -1) tmdb.providers.firstOrNull { it.key == rail.providerKey } else null
        into.removeAllViews()
        into.addView(com.nirajgtm.xtreamtv.ui.buildRail(this, rail.title, rail.cards.size,
            { card, i ->
                val c = rail.cards[i]
                card.bind((if (started(c)) "▶ " else "") + c.display, c.poster)
            },
            { i ->
                val c = rail.cards[i]
                // Watching from a platform rail is what ranks that platform.
                if (rail.providerKey != -1)
                    (application as XtreamApp).affinity.recordPlay(rail.providerKey)
                onResultClicked(SearchResult(Kind.values()[c.kind], c.name, c.id, c.ext))
            },
            leadTitle = hub?.let { "${it.label} ›" },
            leadPosterUrl = rail.logoUrl.ifEmpty { null },
            leadOnClick = hub?.let { p -> { openProviderHub(p) } },
            expandFor = { i ->
                val c = rail.cards[i]
                if (c.overview.isBlank() && c.tmdbId == 0) null
                else com.nirajgtm.xtreamtv.ui.ExpandData(c.display, c.year,
                    c.kind == Kind.SERIES.ordinal, c.overview) { tmdb.castFor(c.tmdbId, c.kind == Kind.SERIES.ordinal) }
            }))
    }

    /** Background: rebuild all TMDB rails, replace each slot, and re-save the snapshot. */
    private fun rebuildTmdbRails() {
        if (!tmdb.configured) {
            if (trendingSlot.childCount == 0) trendingSlot.addView(TextView(this).apply {
                text = "Add a TMDB key to see trending rails."
                setTextColor(Color.parseColor("#557788")); setPadding(24, 24, 24, 24)
            })
            return
        }
        if (trendingSlot.childCount == 0) trendingSlot.addView(TextView(this).apply {
            text = "Loading what's trending today…"
            setTextColor(Color.parseColor("#557788")); setPadding(24, 24, 24, 24); tag = "loading"
        })
        (application as XtreamApp).background.submit {
            try { client.loadMovies { } } catch (_: Exception) {} // need the movie index to resolve titles
            try { client.warmTitleIndexes() } catch (_: Exception) {}
            val trending = try { tmdb.trendingWithProviders() } catch (_: Exception) { emptyList() }
            val collected = java.util.concurrent.ConcurrentHashMap<Int, com.nirajgtm.xtreamtv.data.RailData>()
            fillRailAsync(trendingSlot, "Trending Today", trending, collector = { collected[-1] = it })
            val pool = java.util.concurrent.Executors.newFixedThreadPool(4,
                com.nirajgtm.xtreamtv.util.Threads.lowPriorityFactory("rails"))
            tmdb.providers.forEachIndexed { index, provider ->
                pool.execute {
                    val trendingOn = trending.filter { tmdb.onProvider(it, provider) }
                    val padded = (trendingOn + tmdb.popularOn(provider)).distinctBy { it.tmdbId }
                    // Reorder by Watchmode's accurate per-service popularity when
                    // available; otherwise keep TMDB order. Posters stay TMDB's.
                    val ranks = (application as XtreamApp).watchmode.popularRanks(provider.watchmodeId)
                    val ordered = if (ranks.isNotEmpty())
                        padded.sortedBy { ranks[it.tmdbId] ?: Int.MAX_VALUE } else padded
                    fillRailAsync(providerSubSlots[index], "Popular on ${provider.label}", ordered,
                        cap = 20, hubProvider = provider, collector = { collected[index] = it })
                }
            }
            pool.shutdown()
            pool.awaitTermination(120, TimeUnit.SECONDS)
            val ordered = (listOf(-1) + tmdb.providers.indices).mapNotNull { collected[it] }
            (application as XtreamApp).homeCache.save(
                com.nirajgtm.xtreamtv.data.HomeSnapshot(System.currentTimeMillis(), ordered))
        }
    }

    private fun fillRailAsync(into: LinearLayout, title: String, items: List<com.nirajgtm.xtreamtv.data.TmdbItem>, cap: Int = 60,
                             hubProvider: com.nirajgtm.xtreamtv.data.TmdbClient.Provider? = null,
                             collector: ((com.nirajgtm.xtreamtv.data.RailData) -> Unit)? = null) {
        val available = ArrayList<Pair<com.nirajgtm.xtreamtv.data.TmdbItem, SearchResult>>()
        for (item in items) {
            client.findByTitle(item.title, item.isSeries)?.let { available.add(item to it) }
            if (available.size >= cap) break
        }
        if (available.isEmpty()) return
        val store = (application as XtreamApp).resume
        fun started(r: SearchResult) = r.kind == Kind.MOVIE && store.hasResume("movie:${r.id}")
        val ordered = available.sortedByDescending { started(it.second) }
        val logoUrl = hubProvider?.let { tmdb.providerLogoUrl(it) }
        collector?.invoke(com.nirajgtm.xtreamtv.data.RailData(
            title, hubProvider?.key ?: -1, logoUrl ?: "",
            ordered.map { (item, r) ->
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
                { i -> onResultClicked(ordered[i].second) },
                leadTitle = hubProvider?.let { "${it.label} ›" },
                leadPosterUrl = logoUrl,
                leadOnClick = hubProvider?.let { p -> { openProviderHub(p) } },
                expandFor = { i ->
                    val item = ordered[i].first
                    com.nirajgtm.xtreamtv.ui.ExpandData(item.title, item.year, item.isSeries,
                        item.overview) { tmdb.castFor(item.tmdbId, item.isSeries) }
                }))
        }
    }

    private fun openProviderHub(provider: com.nirajgtm.xtreamtv.data.TmdbClient.Provider) {
        startActivity(Intent(this, ProviderHubActivity::class.java).putExtra("providerKey", provider.key))
    }

    // For an episode mark, resolve (seriesId, season, episode) — from stored
    // fields, or (for older marks) by parsing the "Name  S1 E2 ..." title and
    // finding the series in the catalog.
    private fun episodeSeriesRef(mark: com.nirajgtm.xtreamtv.data.ResumeStore.Mark): Triple<Long, Int, Int>? {
        if (mark.seriesId != 0L) return Triple(mark.seriesId, mark.season, mark.episodeNum)
        val m = Regex("^(.*?)\\s+S(\\d+)\\s*E(\\d+)").find(mark.title) ?: return null
        val season = m.groupValues[2].toIntOrNull() ?: return null
        val episode = m.groupValues[3].toIntOrNull() ?: return null
        val sid = client.findByTitle(m.groupValues[1].trim(), true)?.id ?: return null
        return Triple(sid, season, episode)
    }

    /** Continue Watching opens the movie/series PAGE (not direct playback); a
     *  series lands on the exact season/episode, a movie on its detail page (which
     *  shows Resume). */
    private fun resumeFromHistory(key: String, mark: com.nirajgtm.xtreamtv.data.ResumeStore.Mark) {
        focusToRestore = currentFocus
        if (mark.kind == "series") {
            val ref = episodeSeriesRef(mark) ?: return
            focusSeason = ref.second
            focusEpisodeNum = ref.third
            val name = mark.seriesName.ifBlank { mark.title.substringBefore("  S").trim() }
            openSeries(SearchResult(Kind.SERIES, name, ref.first))
        } else {
            val id = key.removePrefix("movie:").toLongOrNull() ?: return
            val ext = mark.playUrl.substringAfterLast('.', "").takeIf { it.length in 2..4 } ?: "mp4"
            startActivity(Intent(this, DetailActivity::class.java)
                .putExtra("id", id).putExtra("name", mark.title).putExtra("ext", ext))
        }
    }

    // ---- Search: debounced, off the UI thread, paged ----

    private fun scheduleSearch(query: String) {
        searchGen++
        searchHandler.removeCallbacksAndMessages(null)
        searchHandler.postDelayed({ startSearch(query, searchGen) }, searchDebounceMs)
    }

    private fun startSearch(query: String, gen: Int) {
        val newSession = client.newSearch(query, selectedKind, selectedLang)
        if (!newSession.valid) {
            session = null
            availability = null
            updateFilterAvailability()
            showResults(emptyList(), replace = true)
            if (catalogsReady) status.text = "Type at least 2 characters to search."
            return
        }
        thread {
            val page = newSession.next(pageSize)
            runOnUiThread {
                if (gen != searchGen || mode != Mode.RESULTS) return@runOnUiThread
                session = newSession
                showResults(page, replace = true)
            }
            // Facet counts are a full-catalog pass; done after the page shows.
            val counts = client.availability(query, selectedKind, selectedLang)
            runOnUiThread {
                if (gen != searchGen || mode != Mode.RESULTS) return@runOnUiThread
                availability = counts
                updateFilterAvailability()
            }
        }
    }

    private fun loadMore(current: XtreamClient.SearchSession) {
        loadingMore = true
        val gen = searchGen
        thread {
            val page = current.next(pageSize)
            runOnUiThread {
                loadingMore = false
                if (gen != searchGen || mode != Mode.RESULTS || page.isEmpty()) return@runOnUiThread
                showResults(page, replace = false)
            }
        }
    }

    private fun showResults(page: List<SearchResult>, replace: Boolean) {
        // A new result set means the previewing row is gone: stop it, or the old
        // channel keeps playing under rows it no longer belongs to.
        if (replace) resultsPreview?.pause()
        if (replace) results.clear()
        results.addAll(page)
        if (resultsAdapter == null) {
            resultsAdapter = ResultsAdapter()
            resultsList.adapter = resultsAdapter
        }
        resultsAdapter?.notifyDataSetChanged()
        val more = session?.let { !it.exhausted } == true
        if (session != null) {
            val kindLabel = selectedKind?.toString()?.lowercase() ?: "all types"
            val langLabel = selectedLang ?: "all languages"
            status.text = "${results.size}${if (more) "+" else ""} results  ($kindLabel, $langLabel)"
        }
    }

    /** Row: type icon + cleaned title + colored pills (language, quality, source, year). */
    private fun renderResult(result: SearchResult): CharSequence {
        val icon = when (result.kind) {
            Kind.LIVE -> "🔴"
            Kind.MOVIE -> "🎬"
            Kind.SERIES -> "📺"
        }
        val parsed = com.nirajgtm.xtreamtv.data.TitleParser.parse(result.name)
        val text = SpannableStringBuilder("$icon  ${parsed.clean}")
        com.nirajgtm.xtreamtv.ui.appendInlinePills(text, parsed.pills)
        return text
    }

    /** Search rows: a thumbnail slot (live preview / last frame / logo / kind icon)
     *  plus the rich title. Live rows preview with sound on focus via the controller. */
    private inner class ResultsAdapter : android.widget.BaseAdapter() {
        private val idThumb = 0x2B01
        private val idEmoji = 0x2B02
        private val idTitle = 0x2B03

        override fun getCount() = results.size
        override fun getItem(position: Int) = results[position]
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val row = (convertView as? LinearLayout) ?: buildRow()
            val result = results[position]
            row.findViewById<TextView>(idTitle).text = renderResult(result)
            val thumb = row.findViewById<android.widget.ImageView>(idThumb)
            val emoji = row.findViewById<TextView>(idEmoji)
            val cached = if (result.kind == Kind.LIVE) com.nirajgtm.xtreamtv.ui.PreviewCache.get(result.id) else null
            val logo = if (result.kind == Kind.LIVE) liveById()[result.id]?.logo else null
            when {
                cached != null -> {
                    thumb.scaleType = android.widget.ImageView.ScaleType.CENTER_CROP
                    thumb.setImageBitmap(cached); thumb.visibility = View.VISIBLE; emoji.visibility = View.GONE
                }
                !logo.isNullOrBlank() -> {
                    thumb.scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
                    com.nirajgtm.xtreamtv.ui.ImageLoader.load(thumb, logo, Color.parseColor("#22303C"))
                    thumb.visibility = View.VISIBLE; emoji.visibility = View.GONE
                }
                else -> {
                    thumb.setImageDrawable(null); thumb.visibility = View.GONE; emoji.visibility = View.VISIBLE
                    emoji.text = when (result.kind) { Kind.LIVE -> "🔴"; Kind.MOVIE -> "🎬"; Kind.SERIES -> "📺" }
                }
            }
            return row
        }

        private fun buildRow(): LinearLayout {
            val thumb = android.widget.ImageView(this@MainActivity).apply {
                id = idThumb; setBackgroundColor(Color.parseColor("#22303C"))
            }
            val emoji = TextView(this@MainActivity).apply {
                id = idEmoji; textSize = 26f; gravity = android.view.Gravity.CENTER
            }
            val slot = android.widget.FrameLayout(this@MainActivity).apply {
                id = com.nirajgtm.xtreamtv.ui.ChannelRowAdapter.PREVIEW_SLOT_ID
                addView(thumb, android.widget.FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
                addView(emoji, android.widget.FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            }
            val title = TextView(this@MainActivity).apply {
                id = idTitle; setTextColor(Color.WHITE); textSize = 16f
            }
            return LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                setPadding(20, 12, 20, 12)
                addView(slot, LinearLayout.LayoutParams(200, 112).apply { marginEnd = 22 })
                addView(title, LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            }
        }
    }

    private fun makeTextAdapter(labels: List<String>): ArrayAdapter<String> =
        object : ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, labels) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val view = super.getView(position, convertView, parent) as TextView
                view.setTextColor(Color.WHITE)
                return view
            }
        }

    // ---- Playback and series ----

    // The card we left from, so returning lands back on it (not the top/search).
    private var focusToRestore: View? = null

    /**
     * Search rows open a light episode list per source, so several sources of
     * the same show can be explored without going through the series page.
     * Home rails and Continue Playing still open the full series page.
     */
    private fun onSearchResultClicked(result: SearchResult) {
        if (result.kind == Kind.SERIES) {
            focusToRestore = currentFocus
            startActivity(Intent(this, SearchEpisodesActivity::class.java)
                .putExtra("seriesId", result.id)
                .putExtra("seriesName", result.name))
        } else onResultClicked(result)
    }

    private fun onResultClicked(result: SearchResult) {
        when (result.kind) {
            Kind.LIVE -> {
                focusToRestore = currentFocus
                (application as XtreamApp).resume.touchLiveLang(
                    com.nirajgtm.xtreamtv.data.LiveCatalog.bucketOf(result.name), System.currentTimeMillis())
                (application as XtreamApp).resume.bumpPlay("live:${result.id}")
                play(client.liveUrl(result.id), result.name, isLive = true, channelId = result.id)
            }
            Kind.MOVIE -> {
                focusToRestore = currentFocus
                startActivity(Intent(this, DetailActivity::class.java)
                    .putExtra("id", result.id)
                    .putExtra("name", result.name)
                    .putExtra("ext", result.ext))
            }
            Kind.SERIES -> openSeries(result)
        }
    }

    /** [applyOverride] false when re-opening from the source picker (use exactly [result]). */
    private fun openSeries(result: SearchResult, applyOverride: Boolean = true) {
        status.text = "Loading ${displayTitle(result.name)}..."
        thread {
            try {
                val key = client.titleKeyOf(result.name)
                var effId = result.id; var effName = result.name
                // Apply a saved source choice cheaply (no catalog scan).
                if (applyOverride) (application as XtreamApp).resume.sourceOverride(key)
                    ?.takeIf { it.name.isNotBlank() }
                    ?.let { effId = it.id; effName = it.name }
                val detail = client.seriesDetail(effId)
                val fetched = detail.episodes
                runOnUiThread {
                    if (fetched.isEmpty()) {
                        status.text = "No episodes found for ${displayTitle(result.name)}"
                        return@runOnUiThread
                    }
                    seriesTitleKey = key; seriesSources = emptyList() // loaded lazily on demand
                    currentSeriesName = displayTitle(effName)
                    currentSeriesId = effId
                    currentSeriesCover = detail.cover
                    currentSeriesPlot = detail.plot
                    currentSeriesCast = detail.cast
                    currentSeriesTmdbId = detail.tmdbId
                    currentSeriesBackdrop = detail.backdrop
                    currentSeriesMeta = listOf(detail.genre, detail.year,
                        detail.rating.takeIf { it.isNotBlank() }?.let { "★ $it" } ?: "")
                        .filter { it.isNotBlank() }.joinToString("   •   ")
                    seasons = fetched.groupBy { it.season }.toSortedMap()
                        .map { (season, episodes) -> season to episodes.sortedBy { it.number } }
                    enterSeriesMode()
                }
            } catch (e: Exception) {
                runOnUiThread { status.text = "Could not load series: ${e.message}" }
            }
        }
    }

    private fun seriesSourceLabel(name: String): String {
        val prefix = name.substringBefore(" - ", "").trim()
        val country = Regex("\\(([A-Za-z]{2})\\)\\s*$").find(name)?.groupValues?.get(1)?.uppercase() ?: ""
        return listOf(prefix, country).filter { it.isNotBlank() }.joinToString("  ·  ").ifBlank { name }
    }

    private fun showSeriesSourceDialog() {
        if (seriesSources.isEmpty()) {
            status.text = "Finding sources for $currentSeriesName…"
            val name = currentSeriesName
            thread {
                val list = client.sourcesFor(name, true)
                runOnUiThread {
                    seriesSources = list
                    status.text = "$currentSeriesName   (Back returns to search)"
                    showSeriesSourceList()
                }
            }
        } else showSeriesSourceList()
    }

    private fun showSeriesSourceList() {
        if (seriesSources.size < 2) {
            android.widget.Toast.makeText(this, "No other sources found", android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        val labels = seriesSources.map { seriesSourceLabel(it.name) }.toTypedArray()
        android.app.AlertDialog.Builder(this)
            .setTitle("Other sources (${seriesSources.size})")
            .setItems(labels) { _, which ->
                val entry = seriesSources[which]
                // Explore this source now; it becomes the default only if you play from it.
                openSeries(SearchResult(Kind.SERIES, entry.name, entry.id), applyOverride = false)
            }
            .show()
    }

    /** Rounded pill styling for the hero buttons (primary = white, else translucent). */
    private fun styleHeroButton(button: android.widget.Button, isPrimary: Boolean) {
        val focused = button.isFocused
        val filled = isPrimary || focused
        button.stateListAnimator = null
        button.elevation = 0f
        // Squircle, not a plain rounded rect: continuous corners have no visible
        // kink where the straight edge meets the curve.
        button.background = com.nirajgtm.xtreamtv.ui.Squircle(
            if (filled) Color.WHITE else Color.parseColor("#33FFFFFF"))
        button.setTextColor(if (filled) Color.parseColor("#0B0F14") else Color.WHITE)
        button.isAllCaps = false
        button.setPadding(44, 18, 44, 18)
        button.scaleX = if (focused) 1.04f else 1f
        button.scaleY = if (focused) 1.04f else 1f
    }

    /** Full-bleed Apple TV-style series page: hero + horizontal episode strip. */
    private fun enterSeriesMode() {
        resultsPreview?.pause() // never leave a channel playing behind the series page
        mode = Mode.SERIES
        topChrome.visibility = View.GONE
        resultsList.visibility = View.GONE
        homeScroll.visibility = View.GONE
        seriesPane.visibility = View.VISIBLE
        seriesTitleView.text = currentSeriesName
        com.nirajgtm.xtreamtv.ui.ImageLoader.load(seriesBackdrop,
            currentSeriesBackdrop.ifBlank { currentSeriesCover }, Color.parseColor("#0B0F14"), maxDim = 1280)
        seriesInfoView.text = currentSeriesPlot
        seriesInfoView.visibility = if (currentSeriesPlot.isBlank()) View.GONE else View.VISIBLE
        seriesMetaView.text = currentSeriesMeta
        seriesStarringView.text = currentSeriesCast.takeIf { it.isNotBlank() }?.let { "Starring $it" } ?: ""
        otherSourcesButton.text = "Other sources"
        val store = (application as XtreamApp).resume
        val allEps = seasons.flatMap { it.second }
        val anyMark = allEps.any { store.markUpdatedAt("ep:${it.id}") > 0 }
        val target = heroEpisode()
        playButton.text = when {
            target == null -> "▶  Play"
            store.hasResume("ep:${target.id}") -> "▶  Resume S${target.season} E${target.number}"
            anyMark -> "▶  Play S${target.season} E${target.number}"
            else -> "▶  Play First Episode"
        }
        // Progress bar under the button: how far into the resume episode.
        heroWatchedFrac = target?.let { store.watchedFraction("ep:${it.id}") } ?: 0f
        resumeProgressTrack.visibility = if (heroWatchedFrac > 0.01f) View.VISIBLE else View.GONE
        startHeroPrefetchTicker()   // applies BOTH bars, and retries until the track is measured
        // Start pulling down whatever Play would launch, so it starts from disk:
        // the first episode of a new show, or the one in progress from its
        // saved position.
        target?.let { episode -> // always prefetch what Play would launch
            val app = application as XtreamApp
            val fraction = app.resume.watchedFraction("ep:${episode.id}").toDouble()
            val url = client.episodeUrl(episode)
            app.activeMediaUrl = url            // on screen: its cache is protected
            app.aheadCache.prepare(url, fraction)
        }
        // Preselect the target season (from Continue Watching), else the first.
        val seasonIndex = if (focusSeason >= 0)
            seasons.indexOfFirst { it.first == focusSeason }.coerceAtLeast(0) else 0
        showSeasonEpisodes(seasonIndex)
        renderSeasonChips() // visible season tabs (built after selectedSeasonIndex is set)
        // Always land on the hero Play button (expanded); if resuming a specific
        // episode, scroll the strip to it so it's ready when you press down.
        val epIndex = if (focusEpisodeNum >= 0)
            currentEpisodes.indexOfFirst { it.number == focusEpisodeNum } else -1
        playButton.post { playButton.requestFocus() }
        if (epIndex > 0) episodeStripScroll.post {
            episodeStrip.getChildAt(epIndex)?.let { episodeStripScroll.smoothScrollTo(it.left - 56, 0) }
        }
        focusSeason = -1; focusEpisodeNum = -1
    }

    /**
     * Animate the translucent "downloaded" layer on the hero progress bar while
     * the page is open, so the prefetch is visible before Play is pressed. Shows
     * the track even with no watch progress once bytes start landing.
     */
    private fun setBarWidth(v: View, px: Int) {
        v.layoutParams = (v.layoutParams as android.widget.FrameLayout.LayoutParams).apply { width = px }
        v.requestLayout()
    }

    private fun startHeroPrefetchTicker() {
        prefetchBarHandler.removeCallbacksAndMessages(null)
        val tick = object : Runnable {
            override fun run() {
                if (mode != Mode.SERIES) return
                val span = (application as XtreamApp).aheadCache.prefetchedSpanFractions()
                if (heroWatchedFrac > 0.01f || span != null)
                    resumeProgressTrack.visibility = View.VISIBLE
                val w = resumeProgressTrack.width
                if (w > 0) {
                    setBarWidth(resumeProgressFill, (w * heroWatchedFrac).toInt())
                    if (span != null) setBarWidth(resumePrefetchFill, (w * span.second).toInt())
                }
                prefetchBarHandler.postDelayed(this, 1_000)
            }
        }
        prefetchBarHandler.post(tick)
    }

    /** The episode the Play button should launch: the one in progress (or the next
     *  one if that's within 2 min of the end), else the very first episode. */
    private fun heroEpisode(): Episode? {
        val store = (application as XtreamApp).resume
        val all = seasons.flatMap { it.second }
        // Most recent episode we have any mark for (resume OR queued next-up).
        val inProgress = all.filter { store.markUpdatedAt("ep:${it.id}") > 0 }
            .maxByOrNull { store.markUpdatedAt("ep:${it.id}") }
        if (inProgress != null) {
            return if (store.isNearlyFinished("ep:${inProgress.id}"))
                (nextEpisodeAfter(inProgress) ?: inProgress) else inProgress
        }
        return all.firstOrNull()
    }

    private fun nextEpisodeAfter(ep: Episode): Episode? {
        val all = seasons.flatMap { it.second }
        val idx = all.indexOfFirst { it.id == ep.id }
        return if (idx >= 0 && idx + 1 < all.size) all[idx + 1] else null
    }

    private fun playHeroEpisode() { heroEpisode()?.let { playEpisode(it) } }

    /** Build a tab per season; the active one is highlighted. Rebuilt per series. */
    private fun renderSeasonChips() {
        seasonHeader.removeAllViews()
        seasons.forEachIndexed { index, seasonPair ->
            val chip = android.widget.Button(this).apply {
                text = "Season ${seasonPair.first}"; isAllCaps = false; textSize = 17f
                setPadding(40, 14, 40, 14)
                setOnClickListener { if (index != selectedSeasonIndex) showSeasonEpisodes(index) }
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

    private fun showSeasonEpisodes(seasonIndex: Int) {
        val season = seasons.getOrNull(seasonIndex) ?: return
        selectedSeasonIndex = seasonIndex
        currentEpisodes = season.second
        updateSeasonChipStyles()
        renderEpisodeCards(emptyMap()) // provider data instantly...
        // ...then enrich with real names/overviews/stills from TMDB.
        val tmdbId = currentSeriesTmdbId; val seasonNum = season.first
        if (tmdbId != 0) thread {
            val meta = tmdb.seasonEpisodes(tmdbId, seasonNum)
            if (meta.isNotEmpty()) runOnUiThread {
                if (mode == Mode.SERIES && selectedSeasonIndex == seasonIndex) renderEpisodeCards(meta)
            }
        }
    }

    private fun renderEpisodeCards(meta: Map<Int, com.nirajgtm.xtreamtv.data.TmdbClient.EpisodeMeta>) {
        episodeStrip.removeAllViews()
        val store = (application as XtreamApp).resume
        currentEpisodes.forEach { ep ->
            episodeStrip.addView(com.nirajgtm.xtreamtv.ui.buildEpisodeCard(
                this, ep, meta[ep.number], store) { playEpisode(ep) })
        }
        episodeStripScroll.scrollTo(0, 0)
    }

    private fun exitSeriesMode() {
        seriesPane.visibility = View.GONE
        topChrome.visibility = View.VISIBLE
        if (searchBox.text.isNullOrBlank()) {
            showHome()
            searchBox.requestFocus()
        } else {
            showResults()
            resultsList.requestFocus()
        }
    }

    private fun playEpisode(episode: Episode) {
        val key = "ep:${episode.id}"
        val url = client.episodeUrl(episode)
        val label = episodeLabel(episode)
        // Use the high-quality series cover, not the low-res episode still.
        val poster = currentSeriesCover.ifBlank { episode.thumb }
        (application as XtreamApp).resume.remember(key, label, poster, "series", url,
            seriesId = currentSeriesId, seriesName = currentSeriesName,
            season = episode.season, episodeNum = episode.number)
        // Playing from this source makes it the default for this series.
        if (seriesTitleKey.isNotBlank())
            (application as XtreamApp).resume.setSourceOverride(
                seriesTitleKey, currentSeriesId, currentSeriesName, "")
        // Remember where to return (survives this Activity being reclaimed while playing).
        (application as XtreamApp).pendingSeriesReturn = XtreamApp.SeriesReturn(
            currentSeriesId, currentSeriesName, episode.season, episode.number)
        // Whole series in order (across all seasons) so the player can step
        // forward AND back between episodes and roll over season boundaries.
        val all = seasons.flatMap { it.second }
        val startIndex = all.indexOfFirst { it.id == episode.id }.coerceAtLeast(0)
        startActivity(Intent(this, PlayerActivity::class.java)
            .putExtra("url", url)
            .putExtra("title", label)
            .putExtra("resumeKey", key)
            .putExtra("resumePosition", (application as XtreamApp).resume.resumePosition(key))
            .putExtra("ovPoster", poster)
            .putExtra("ovTitle", label)
            .putExtra("ovPlot", episode.plot)
            .putExtra("ovSeriesId", currentSeriesId)
            .putExtra("epStartIndex", startIndex)
            .putStringArrayListExtra("epUrls", ArrayList(all.map { client.episodeUrl(it) }))
            .putStringArrayListExtra("epTitles", ArrayList(all.map { episodeLabel(it) }))
            .putStringArrayListExtra("epKeys", ArrayList(all.map { "ep:${it.id}" }))
            .putStringArrayListExtra("epPlots", ArrayList(all.map { it.plot }))
            .putExtra("epSeasons", all.map { it.season }.toIntArray())
            .putExtra("epNums", all.map { it.number }.toIntArray()))
    }

    private fun episodeLabel(episode: Episode): String {
        val title = cleanEpisodeTitle(episode.title).ifEmpty { "Episode ${episode.number}" }
        return "$currentSeriesName  S${episode.season} E${episode.number}  $title"
    }

    private fun play(url: String, title: String, isLive: Boolean = false, channelId: Long = 0L) {
        startActivity(Intent(this, PlayerActivity::class.java)
            .putExtra("url", url)
            .putExtra("title", title)
            .putExtra("isLive", isLive)
            .putExtra("channelId", channelId))
    }

    override fun onResume() {
        super.onResume()
        // Returning from the player can leave the keyboard's input connection in an
        // "evicted" state that eats every D-pad press. Dismiss it so the remote works.
        try {
            (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
                .hideSoftInputFromWindow(searchBox.windowToken, 0)
        } catch (_: Exception) {}
        kickResumePrefetch() // warm the top Continue Playing items so Resume is instant
        // Returning from an episode played via Continue Playing: open its series
        // list at that season/episode instead of staying on home.
        pendingReturnToSeries?.let { mark ->
            pendingReturnToSeries = null
            focusToRestore = null
            focusSeason = mark.season
            focusEpisodeNum = mark.episodeNum
            openSeries(SearchResult(Kind.SERIES, mark.seriesName, mark.seriesId))
            return
        }
        // Returning from a series episode: land back on the series page (not home),
        // with the season/episode we were on selected. Survives Activity reclaim.
        (application as XtreamApp).pendingSeriesReturn?.let { ret ->
            (application as XtreamApp).pendingSeriesReturn = null
            if (mode != Mode.SERIES || currentSeriesId != ret.id) {
                focusSeason = ret.season; focusEpisodeNum = ret.episode
                openSeries(SearchResult(Kind.SERIES, ret.name, ret.id), applyOverride = false)
            } else {
                val si = seasons.indexOfFirst { it.first == ret.season }.coerceAtLeast(0)
                showSeasonEpisodes(si)
                val ei = currentEpisodes.indexOfFirst { it.number == ret.episode }
                if (ei >= 0) episodeStrip.post { episodeStrip.getChildAt(ei)?.requestFocus() }
            }
            return
        }
        // A position may have been saved while watching; refresh the episode strip.
        if (mode == Mode.SERIES) showSeasonEpisodes(selectedSeasonIndex)
        if (mode == Mode.HOME && homeBuilt) {
            refreshContinuePlaying()
            fillLiveTvRail() // a newly-watched language may need a new tile
            applyProviderOrder() // most-watched platforms rise over time
            // Return focus to the card we launched from, so it feels like coming back.
            focusToRestore?.let { v ->
                focusToRestore = null
                if (v.isAttachedToWindow) v.post { v.requestFocus() }
            }
        }
    }

    override fun onBackPressed() {
        when {
            mode == Mode.SERIES -> exitSeriesMode()
            // Not on home yet -> go home first; only exit from home.
            mode == Mode.RESULTS || !searchBox.text.isNullOrEmpty() -> {
                searchBox.setText("")
                showHome()
                searchBox.requestFocus()
            }
            else -> super.onBackPressed()
        }
    }

    // ---- Voice search: talk from anywhere in the app -> into the search bar ----

    private val voiceRequest = 4711
    private val SETTINGS_REQUEST = 4713
    private val voice by lazy { com.nirajgtm.xtreamtv.ui.VoiceSearch(this) }

    // ---- Adult filter: on by default, unlocked by a phrase + 5 UP presses ----

    private val unlockPhrase = "i love boobies"
    private val lockPhrase = "i hate boobies"
    /** Non-zero once the unlock phrase is typed; counts the UP presses that follow. */
    private var unlockArmed = false
    private var unlockUpPresses = 0

    private val settings by lazy { com.nirajgtm.xtreamtv.data.Settings(this) }

    /** Push the stored preference into the places that actually filter. */
    private fun applyAdultFilter(on: Boolean) {
        settings.adultFilter = on
        client.adultFilterOn = on
        com.nirajgtm.xtreamtv.data.LiveCatalog.adultFilterOn = on
    }

    /** Watches the search box for the lock/unlock phrases. */
    private fun checkFilterPhrase(query: String) {
        when (query.trim().lowercase()) {
            unlockPhrase -> { unlockArmed = true; unlockUpPresses = 0 }
            lockPhrase -> {
                unlockArmed = false; unlockUpPresses = 0
                if (!settings.adultFilter) {
                    applyAdultFilter(true)
                    android.widget.Toast.makeText(this, "No boobies for you!", android.widget.Toast.LENGTH_LONG).show()
                    searchBox.setText("")
                }
            }
            else -> { unlockArmed = false; unlockUpPresses = 0 }
        }
    }

    /** UP presses while the phrase is showing; the 5th one unlocks. */
    private fun countUnlockPress(): Boolean {
        if (!unlockArmed) return false
        unlockUpPresses++
        if (unlockUpPresses < 5) return true // swallow so focus doesn't wander off
        unlockArmed = false; unlockUpPresses = 0
        applyAdultFilter(false)
        android.widget.Toast.makeText(this, "boobies unlocked", android.widget.Toast.LENGTH_LONG).show()
        searchBox.setText("")
        return true
    }

    /**
     * Listen in-app and search as the words arrive. The system recognizer dialog
     * only returns a final transcript, so results could never update mid-sentence;
     * driving SpeechRecognizer ourselves gives partial hypotheses to search on.
     */
    private fun launchVoiceSearch() {
        if (!com.nirajgtm.xtreamtv.ui.VoiceSearch.hasPermission(this)) {
            com.nirajgtm.xtreamtv.ui.VoiceSearch.requestPermission(this)
            return
        }
        if (voice.listening) { voice.stop(); return } // pressing again stops listening
        if (!voice.available()) { legacyVoiceSearch(); return }
        if (mode == Mode.SERIES) exitSeriesMode()
        searchBox.requestFocus()
        status.text = "Listening…"
        voice.start(
            onPartial = { spoken -> applySpokenQuery(spoken) },   // search while still speaking
            onFinal = { spoken -> applySpokenQuery(spoken) },
            onDone = { message -> status.text = message ?: "" }
        )
    }

    private fun applySpokenQuery(spoken: String) {
        if (spoken.isBlank()) return
        searchBox.setText(spoken)
        searchBox.setSelection(spoken.length)
        // The text watcher already schedules the search for us.
    }

    /** Devices with no in-app recognizer still get the system dialog. */
    private fun legacyVoiceSearch() {
        val intent = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(android.speech.RecognizerIntent.EXTRA_PROMPT, "Speak to search")
        }
        try {
            startActivityForResult(intent, voiceRequest)
        } catch (_: Exception) {
            status.text = "Voice input isn't available on this device."
        }
    }

    override fun onRequestPermissionsResult(code: Int, perms: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, perms, results)
        if (code == com.nirajgtm.xtreamtv.ui.VoiceSearch.PERMISSION_REQUEST) {
            if (results.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED)
                launchVoiceSearch()
            else legacyVoiceSearch() // no mic permission: fall back to the system dialog
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == voiceRequest && resultCode == RESULT_OK) {
            val spoken = data?.getStringArrayListExtra(
                android.speech.RecognizerIntent.EXTRA_RESULTS)?.firstOrNull()
            if (!spoken.isNullOrBlank()) {
                if (mode == Mode.SERIES) exitSeriesMode()
                searchBox.requestFocus()
                applySpokenQuery(spoken)
            }
        }
        // Coming back from first-run setup: nothing was loaded yet, so start now.
        if (requestCode == SETTINGS_REQUEST && !catalogsReady && credentials.isConfigured &&
            resultCode != SettingsActivity.RESULT_ACCOUNT_CHANGED) {
            loadCatalogs()
            handleLaunchExtras(intent)
            return
        }
        // A new account wiped the cached catalogues, so fetch them again from scratch.
        if (requestCode == SETTINGS_REQUEST && resultCode == SettingsActivity.RESULT_ACCOUNT_CHANGED) {
            catalogsReady = false
            if (mode == Mode.SERIES) exitSeriesMode()
            searchBox.setText("")
            showHome()
            status.text = "Loading new account…"
            fillLiveTvRail()
            refreshContinuePlaying()
            loadCatalogs()
        }
    }

    /** Remote search / voice keys launch voice search from anywhere in the app. */
    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        if (event.action == android.view.KeyEvent.ACTION_DOWN &&
            event.keyCode == android.view.KeyEvent.KEYCODE_DPAD_UP &&
            countUnlockPress()) return true
        if (event.action == android.view.KeyEvent.ACTION_DOWN && catalogsReady) {
            when (event.keyCode) {
                android.view.KeyEvent.KEYCODE_SEARCH,
                android.view.KeyEvent.KEYCODE_VOICE_ASSIST,
                android.view.KeyEvent.KEYCODE_ASSIST -> { launchVoiceSearch(); return true }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onSearchRequested(): Boolean {
        launchVoiceSearch()
        return true
    }

    // ---- Background refresh: check every 2h, refetch only if older than a day ----

    private fun scheduleRefreshCheck(delayMs: Long) {
        refreshHandler.removeCallbacksAndMessages(null)
        refreshHandler.postDelayed({
            thread {
                try {
                    val refreshed = client.refreshIfStale { }
                    if (refreshed) runOnUiThread {
                        if (mode == Mode.RESULTS) scheduleSearch(searchBox.text.toString())
                        status.text = "Catalogs refreshed: ${client.live.size} channels, " +
                            "${client.movies.size} movies, ${client.series.size} series."
                    }
                } catch (_: Exception) {
                    // Stale data keeps working; next check retries.
                }
                runOnUiThread { scheduleRefreshCheck(refreshCheckIntervalMs) }
            }
        }, delayMs)
    }

    override fun onPause() {
        super.onPause()
        resultsPreview?.pause() // free the decoder when leaving / opening playback
        voice.stop() // never hold the mic open behind another screen
        // Release the one connection the moment home is no longer in front: warming or
        // page-prefetch must never keep a slot occupied behind another screen or, on a
        // single-connection account, behind another TV. Both resume when we return.
        (application as XtreamApp).resumePrefetcher.pause()
        (application as XtreamApp).aheadCache.stop()
    }

    /** Warm the video cache for the top Continue Playing items (skips live). */
    private fun kickResumePrefetch() {
        // Warming titles in the background costs a stream connection. With only one
        // available, that competes with whatever is being watched (here or on
        // another TV on the same account), so leave the connection alone.
        if (!client.canFetchWhilePlaying) return
        val targets = (application as XtreamApp).resume.recentCollapsed(8)
            .filter { it.second.kind != "live" && it.second.playUrl.isNotBlank() }
            .map { com.nirajgtm.xtreamtv.data.ResumePrefetcher.Target(
                it.second.playUrl, it.second.positionMs, it.second.durationMs) }
        (application as XtreamApp).resumePrefetcher.sync(targets)
    }

    override fun onDestroy() {
        super.onDestroy()
        refreshHandler.removeCallbacksAndMessages(null)
        searchHandler.removeCallbacksAndMessages(null)
        resultsPreview?.release()
        voice.stop()
    }
}
