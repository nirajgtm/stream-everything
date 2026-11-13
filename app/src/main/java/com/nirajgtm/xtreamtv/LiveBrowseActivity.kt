package com.nirajgtm.xtreamtv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.AbsListView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import android.widget.Toast
import com.nirajgtm.xtreamtv.data.Entry
import com.nirajgtm.xtreamtv.data.LiveCatalog
import com.nirajgtm.xtreamtv.data.LiveCategory
import com.nirajgtm.xtreamtv.data.TitleParser
import com.nirajgtm.xtreamtv.ui.ChannelRowAdapter
import kotlin.concurrent.thread

/** One row in the left navigator: favorites, a language group, or a cross-cutting
 *  smart list (type/genre/sport). Languages and categories share one flat list. */
private sealed class LeftItem {
    abstract val label: String
    abstract val navKey: String  // stable id for access tracking
    abstract val sortKey: String // alphabetical key (emoji/symbols stripped)
}
private class FavItem(count: Int) : LeftItem() {
    override val label = "♥ Favorites  ($count)"
    override val navKey = "favorites"; override val sortKey = ""
}
private class LangItem(val group: LiveCatalog.Group) : LeftItem() {
    override val label = "${group.label}  (${group.channels.size})"
    override val navKey = "lang:${group.label}"; override val sortKey = group.label
}
private class SmartItem(val smart: LiveCatalog.SmartList) : LeftItem() {
    override val label = smart.label
    override val navKey = "smart:${smart.label}"
    override val sortKey = smart.label.dropWhile { !it.isLetter() && !it.isDigit() }.trim()
}

/** Live TV: a left navigator (Favorites, languages by usage, then cross-cutting
 *  category/sport lists), channels with logos + EPG on the right. */
class LiveBrowseActivity : Activity() {

    private lateinit var status: TextView
    private lateinit var navList: ListView
    private lateinit var categoryRow: LinearLayout
    private lateinit var channelList: ListView
    private lateinit var channelAdapter: ChannelRowAdapter
    private var preview: com.nirajgtm.xtreamtv.ui.ChannelPreviewController? = null

    private var groups: List<LiveCatalog.Group> = emptyList()
    private var leftItems: List<LeftItem> = emptyList()
    private var selectedIndex = 0
    private var selectedCategory: LiveCategory? = null
    private var filtered: List<Entry> = emptyList()
    private var shown = 0
    private val pageSize = 100
    private var refreshGen = 0
    private val categoryButtons = mutableMapOf<LiveCategory?, Button>() // null = All

    private val resume by lazy { (application as XtreamApp).resume }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply {
            text = "Loading live channels..."
            textSize = 16f; setTextColor(Color.parseColor("#80CBC4")); setPadding(24, 16, 24, 8)
        }
        navList = ListView(this)
        categoryRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setPadding(16, 8, 16, 8)
        }
        channelList = ListView(this).apply { divider = null; dividerHeight = 0 }
        channelAdapter = ChannelRowAdapter(this, application as XtreamApp)
        channelList.adapter = channelAdapter

        val right = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(categoryRow)
            addView(channelList, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        val panes = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(navList, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0.32f))
            addView(right, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0.68f))
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#101820"))
            addView(status)
            addView(panes, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(root)

        navList.setOnItemClickListener { _, _, position, _ -> selectItem(position, focusChannels = true) }
        navList.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: android.widget.AdapterView<*>?, v: View?, pos: Int, id: Long) = selectItem(pos, focusChannels = false)
            override fun onNothingSelected(p: android.widget.AdapterView<*>?) {}
        }
        channelList.setOnItemClickListener { _, _, position, _ -> playChannel(position) }
        channelList.setOnItemLongClickListener { _, _, position, _ -> toggleFavorite(position); true }
        channelList.setOnScrollListener(object : AbsListView.OnScrollListener {
            override fun onScroll(view: AbsListView?, first: Int, visible: Int, total: Int) {
                if (shown < filtered.size && first + visible >= total - 15) loadMoreChannels()
            }
            override fun onScrollStateChanged(view: AbsListView?, state: Int) {}
        })
        // Live preview of the focused row after a short dwell.
        preview = com.nirajgtm.xtreamtv.ui.ChannelPreviewController(this, channelList) { pos ->
            filtered.getOrNull(pos)?.let { it.id to (application as XtreamApp).client.liveUrl(it.id) }
        }.also { it.attach() }

        loadGroups()
    }

    private fun loadGroups() {
        val app = application as XtreamApp
        // Warm case: the catalog is already in RAM and its grouping is memoized —
        // render immediately, no background hop or re-grouping (~57k channels).
        val cached = cachedGroups
        if (app.client.loaded && cached != null && cachedToken == System.identityHashCode(app.client.live)) {
            renderGroups(cached)
            return
        }
        thread {
            if (!app.client.loaded) app.client.loadCatalogs { }
            val grouped = LiveCatalog.group(app.client.live)
            cachedGroups = grouped
            cachedToken = System.identityHashCode(app.client.live)
            runOnUiThread { renderGroups(grouped) }
        }
    }

    private fun renderGroups(grouped: List<LiveCatalog.Group>) {
        groups = grouped
        status.text = "Live TV — ${grouped.size} languages"
        buildLeftItems()
        buildCategoryChips()
        val startIndex = when {
            intent.getBooleanExtra("favorites", false) -> 0
            else -> intent.getStringExtra("lang")?.let { lang ->
                leftItems.indexOfFirst { it is LangItem && it.group.label.equals(lang, ignoreCase = true) }
            }?.takeIf { it >= 0 } ?: 1
        }
        navList.setSelection(startIndex)
        selectItem(startIndex, focusChannels = false)
        // Land on the first channel of the list (not the left nav).
        channelList.post {
            channelList.setSelection(0)
            channelList.requestFocus()
        }
    }

    /** Left navigator: ♥ Favorites always first, then languages + categories as one
     *  flat list — recently-opened lists ranked first, the rest alphabetical. */
    private fun buildLeftItems() {
        val access = resume.navAccessTimes()
        val all: List<LeftItem> = groups.map { LangItem(it) } + LiveCatalog.smartLists.map { SmartItem(it) }
        val sorted = all.sortedWith(
            compareByDescending<LeftItem> { access[it.navKey] ?: 0L }.thenBy { it.sortKey.lowercase() })
        leftItems = listOf(FavItem(resume.favoriteIds().size)) + sorted
        navList.adapter = whiteAdapter(leftItems.map { it.label })
    }

    private fun selectItem(position: Int, focusChannels: Boolean) {
        val item = leftItems.getOrNull(position) ?: return
        selectedIndex = position
        selectedCategory = null
        // Opening a list (an explicit click) marks it recently-accessed.
        if (focusChannels && item.navKey != "favorites") resume.touchNav(item.navKey, System.currentTimeMillis())
        styleCategoryChips()
        refreshChannels()
        if (focusChannels) channelList.requestFocus()
    }

    private fun buildCategoryChips() {
        categoryRow.removeAllViews()
        categoryButtons.clear()
        fun chip(label: String, key: LiveCategory?) {
            val button = Button(this).apply {
                text = label; isAllCaps = false; textSize = 13f
                setOnClickListener { selectedCategory = key; styleCategoryChips(); refreshChannels() }
                setOnFocusChangeListener { _, _ -> styleCategoryChips() }
            }
            categoryButtons[key] = button
            categoryRow.addView(button, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { marginEnd = 8 })
        }
        chip("All", null)
        for (cat in listOf(LiveCategory.SPORTS, LiveCategory.NEWS, LiveCategory.MOVIES,
            LiveCategory.KIDS, LiveCategory.MUSIC, LiveCategory.DOCS)) chip(cat.label, cat)
        styleCategoryChips()
    }

    private fun styleCategoryChips() {
        for ((key, button) in categoryButtons) {
            val selected = key == selectedCategory
            val focused = button.isFocused
            button.stateListAnimator = null
            button.elevation = 0f
            button.background = com.nirajgtm.xtreamtv.ui.Squircle(
                fillColor = Color.parseColor(if (selected) "#80CBC4" else if (focused) "#3A5064" else "#22303C"),
                strokeColor = if (focused) Color.WHITE else Color.TRANSPARENT,
                strokeWidthPx = if (focused) 3f else 0f)
            button.setTextColor(Color.parseColor(if (selected) "#101820" else "#FFFFFF"))
        }
    }

    /** Resolve the selected nav item to channels, filter by category, most-played first. */
    private fun refreshChannels() {
        val item = leftItems.getOrNull(selectedIndex) ?: return
        val app = application as XtreamApp
        val gen = ++refreshGen

        fun apply(base: List<Entry>, head: String) {
            if (gen != refreshGen) return
            val byCat = base.filter { selectedCategory == null || LiveCategory.of(it.name) == selectedCategory }
            val counts = resume.livePlayCounts() // one lock instead of one per element
            filtered = byCat.sortedByDescending { counts[it.id] ?: 0 }
            shown = minOf(pageSize, filtered.size)
            channelAdapter.setChannels(filtered.take(shown))
            channelList.setSelection(0)
            status.text = "$head — ${filtered.size} channels" +
                (selectedCategory?.let { " · ${it.label}" } ?: "")
        }

        when (item) {
            is FavItem -> {
                val favs = resume.favoriteIds().toHashSet()
                apply(app.client.live.filter {
                    it.id in favs && !(app.client.adultFilterOn && it.adult)
                }, "♥ Favorites")
            }
            is LangItem -> apply(item.group.channels, item.group.label)
            is SmartItem -> {
                // Filtering the whole catalog is heavier — do it off the UI thread.
                status.text = "${item.smart.label} — loading…"
                channelAdapter.setChannels(emptyList())
                thread {
                    val base = LiveCatalog.channelsFor(app.client.live, item.smart)
                    runOnUiThread { apply(base, item.smart.label) }
                }
            }
            else -> {}
        }
    }

    private fun loadMoreChannels() {
        val next = minOf(shown + pageSize, filtered.size)
        if (next <= shown) return
        channelAdapter.appendChannels(filtered.subList(shown, next))
        shown = next
    }

    private fun toggleFavorite(position: Int) {
        val channel = filtered.getOrNull(position) ?: return
        val nowFav = resume.toggleFavorite(channel.id)
        Toast.makeText(this,
            (if (nowFav) "Added to" else "Removed from") + " favorites: ${TitleParser.parse(channel.name).clean}",
            Toast.LENGTH_SHORT).show()
        // Remember the focused channel row so favoriting doesn't jump to the top.
        val channelPos = channelList.selectedItemPosition.takeIf { it >= 0 } ?: channelList.firstVisiblePosition
        val currentKey = leftItems.getOrNull(selectedIndex)?.navKey
        buildLeftItems() // keep the ♥ Favorites (N) count current
        selectedIndex = leftItems.indexOfFirst { it.navKey == currentKey }.takeIf { it >= 0 } ?: selectedIndex
        navList.setSelection(selectedIndex)
        if (leftItems.getOrNull(selectedIndex) is FavItem) refreshChannels()
        else channelAdapter.notifyDataSetChanged()
        // Restore focus + selection to the same channel row (rebuilding the left
        // nav adapter otherwise steals focus back to the first row). On the
        // Favorites list an unfavorite removes the row, so clamp to the new size.
        channelList.post {
            val target = channelPos.coerceIn(0, maxOf(0, channelList.count - 1))
            channelList.setSelection(target)
            channelList.requestFocus()
        }
    }

    private fun playChannel(position: Int) {
        val channel = filtered.getOrNull(position) ?: return
        val app = application as XtreamApp
        app.liveZapList = filtered.map {
            XtreamApp.LiveZapItem(it.id, app.client.liveUrl(it.id), TitleParser.parse(it.name).clean)
        }
        resume.bumpPlay("live:${channel.id}")
        resume.touchLiveLang(LiveCatalog.bucketOf(channel.name), System.currentTimeMillis())
        leftItems.getOrNull(selectedIndex)?.navKey?.takeIf { it != "favorites" }
            ?.let { resume.touchNav(it, System.currentTimeMillis()) }
        startActivity(Intent(this, PlayerActivity::class.java)
            .putExtra("url", app.client.liveUrl(channel.id))
            .putExtra("title", TitleParser.parse(channel.name).clean)
            .putExtra("isLive", true)
            .putExtra("liveIndex", position)
            .putExtra("channelId", channel.id))
    }

    private fun whiteAdapter(labels: List<String>): ArrayAdapter<String> =
        object : ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, labels) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val view = super.getView(position, convertView, parent) as TextView
                view.setTextColor(Color.WHITE)
                return view
            }
        }

    override fun onPause() {
        super.onPause()
        preview?.pause() // free the decoder before full playback / leaving
    }

    override fun onDestroy() {
        super.onDestroy()
        preview?.release()
    }

    override fun onResume() {
        super.onResume()
        if (!::channelAdapter.isInitialized || groups.isEmpty()) return
        // Re-sort the nav (recently-opened lists rise), refresh favorite markers/
        // count, and keep the current list selected.
        val currentKey = leftItems.getOrNull(selectedIndex)?.navKey
        buildLeftItems()
        selectedIndex = leftItems.indexOfFirst { it.navKey == currentKey }.takeIf { it >= 0 } ?: selectedIndex
        navList.setSelection(selectedIndex)
        if (leftItems.getOrNull(selectedIndex) is FavItem) refreshChannels()
        else channelAdapter.notifyDataSetChanged()
    }

    companion object {
        // Process-level memo of the grouped live catalog. cachedToken tags the
        // live-list identity so a background refresh (new list) invalidates it.
        @Volatile private var cachedGroups: List<LiveCatalog.Group>? = null
        @Volatile private var cachedToken: Int = 0
    }
}
