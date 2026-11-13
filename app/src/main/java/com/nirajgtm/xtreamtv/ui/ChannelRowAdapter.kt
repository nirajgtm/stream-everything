package com.nirajgtm.xtreamtv.ui

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.nirajgtm.xtreamtv.XtreamApp
import com.nirajgtm.xtreamtv.data.Entry
import com.nirajgtm.xtreamtv.data.TitleParser
import java.util.concurrent.Executors

/**
 * Live-channel rows with the station logo, name, a favorite/played marker, and a
 * lazily-loaded now/next EPG line. EPG is fetched off the UI thread on a small
 * pool (the client caches it ~10 min) and applied only if the row hasn't been
 * recycled to another channel.
 */
class ChannelRowAdapter(
    private val activity: Activity,
    private val app: XtreamApp
) : BaseAdapter() {

    private val items = ArrayList<Entry>()
    private val epgPool = Executors.newFixedThreadPool(4,
        com.nirajgtm.xtreamtv.util.Threads.lowPriorityFactory("epg"))

    private val idName = 0x1A02
    private val idEpg = 0x1A03

    companion object {
        /** FrameLayout wrapping the logo; the live-preview surface is attached here. */
        const val PREVIEW_SLOT_ID = 0x1A10
        private const val idLogo = 0x1A01
        /** ImageLoader's own view-tag key, so a pending logo load can be disowned. */
        private const val LOADER_TAG_KEY = 0x7f5a0001

        /**
         * Paint a captured still onto a row's image directly. The preview controller
         * calls this for the row it is leaving: a row that only loses selection is
         * redrawn, never rebound, so waiting for getView would leave the logo showing.
         */
        fun showFrame(previewSlot: View, frame: Bitmap) {
            previewSlot.findViewById<ImageView>(idLogo)?.let { showFrame(it, frame) }
        }

        private fun showFrame(logoView: ImageView, frame: Bitmap) {
            // Clear the loader's tag first: an in-flight logo download only checks the
            // url it was started with, so it would otherwise land later and paint over
            // the still on a recycled row bound to the same channel.
            logoView.setTag(LOADER_TAG_KEY, null)
            logoView.scaleType = ImageView.ScaleType.CENTER_CROP
            logoView.setImageBitmap(frame)
        }
    }

    // Snapshots of resume state, refreshed once per data change instead of per bind.
    private var favSet: Set<Long> = emptySet()
    private var playCounts: Map<Long, Int> = emptyMap()
    private val epgInFlight = java.util.Collections.synchronizedSet(HashSet<Long>())

    fun setChannels(list: List<Entry>) {
        items.clear(); items.addAll(list); notifyDataSetChanged()
    }

    fun appendChannels(list: List<Entry>) {
        if (list.isEmpty()) return
        items.addAll(list); notifyDataSetChanged()
    }

    override fun notifyDataSetChanged() {
        // Take the resume snapshots once here (favorite/played markers) rather than
        // locking ResumeStore twice on every getView.
        favSet = app.resume.favoriteIds().toHashSet()
        playCounts = app.resume.livePlayCounts()
        super.notifyDataSetChanged()
    }

    override fun getCount() = items.size
    override fun getItem(position: Int) = items[position]
    override fun getItemId(position: Int) = items[position].id

    override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
        val row = (convertView as? LinearLayout) ?: buildRow()
        val channel = items[position]
        row.tag = channel.id

        val fav = channel.id in favSet
        val played = (playCounts[channel.id] ?: 0) > 0
        val marker = when { fav -> "♥ "; played -> "★ "; else -> "" }
        val archive = if (channel.archive > 0) "   ⟲ catch-up" else ""
        row.findViewById<TextView>(idName).text = marker + channel.clean + archive

        val epgView = row.findViewById<TextView>(idEpg)
        epgView.tag = channel.id
        loadEpg(channel.id, epgView)

        // A recently-watched channel shows its last frame; otherwise the logo.
        val logoView = row.findViewById<ImageView>(idLogo)
        val cached = PreviewCache.get(channel.id)
        if (cached != null) {
            showFrame(logoView, cached)
        } else {
            logoView.scaleType = ImageView.ScaleType.FIT_CENTER
            ImageLoader.load(logoView, channel.logo, Color.parseColor("#22303C"))
        }
        return row
    }

    private fun buildRow(): LinearLayout {
        val logo = ImageView(activity).apply {
            id = idLogo
            scaleType = ImageView.ScaleType.FIT_CENTER
            setBackgroundColor(Color.parseColor("#22303C"))
        }
        // Wrap the logo so a live-preview surface can be attached over it.
        val previewSlot = android.widget.FrameLayout(activity).apply {
            id = PREVIEW_SLOT_ID
            addView(logo, android.widget.FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        val name = TextView(activity).apply {
            id = idName; setTextColor(Color.WHITE); textSize = 17f
            setTypeface(typeface, Typeface.BOLD)
        }
        val epg = TextView(activity).apply {
            id = idEpg; setTextColor(Color.parseColor("#99A6B0")); textSize = 13f
            maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(0, 4, 0, 0)
        }
        val texts = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_VERTICAL
            addView(name); addView(epg)
        }
        return LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(20, 14, 20, 14)
            // Large 16:9 preview; the name/EPG take the remaining width.
            addView(previewSlot, LinearLayout.LayoutParams(320, 180).apply { marginEnd = 24 })
            addView(texts, LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        }
    }

    private fun formatEpg(epg: List<com.nirajgtm.xtreamtv.data.XtreamClient.EpgEntry>): String {
        val now = epg.firstOrNull { it.nowPlaying } ?: epg.firstOrNull()
        val next = if (now != null) epg.getOrNull(epg.indexOf(now) + 1) else null
        return buildString {
            if (now != null) append("Now: ${now.title}  (until ${now.end.takeLast(8).take(5)})")
            if (next != null) append("\nNext: ${next.title}")
        }.ifBlank { "No guide" }
    }

    private fun loadEpg(channelId: Long, epgView: TextView) {
        // Cache hit: set inline, no task, no thread hop (keeps fast scroll smooth).
        val cached = app.client.shortEpgCached(channelId)
        if (cached != null) { epgView.text = formatEpg(cached); return }
        epgView.text = "…"
        // Miss: fetch once; don't re-enqueue the same channel while a fetch is pending.
        if (!epgInFlight.add(channelId)) return
        epgPool.execute {
            val epg = try { app.client.shortEpg(channelId) } catch (_: Exception) { emptyList() }
            epgInFlight.remove(channelId)
            val line = formatEpg(epg)
            activity.runOnUiThread { if (epgView.tag == channelId) epgView.text = line }
        }
    }
}
