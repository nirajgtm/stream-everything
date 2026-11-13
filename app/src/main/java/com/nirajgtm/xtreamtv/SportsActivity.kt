package com.nirajgtm.xtreamtv

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.ArrayAdapter
import android.widget.LinearLayout
import android.widget.ListView
import android.widget.TextView
import com.nirajgtm.xtreamtv.data.Entry
import com.nirajgtm.xtreamtv.data.TitleParser
import com.nirajgtm.xtreamtv.data.XtreamClient
import kotlin.concurrent.thread

/** Sports & Live Events: provider sport/PPV/event categories on the left,
 *  their channels on the right with a now/next EPG line for the focused one. */
class SportsActivity : Activity() {

    private lateinit var status: TextView
    private lateinit var categoryList: ListView
    private lateinit var channelList: ListView
    private lateinit var channelAdapter: com.nirajgtm.xtreamtv.ui.ChannelRowAdapter
    private var preview: com.nirajgtm.xtreamtv.ui.ChannelPreviewController? = null

    private var categories: List<XtreamClient.LiveCategoryInfo> = emptyList()
    private var channels: List<Entry> = emptyList()
    private val client by lazy { (application as XtreamApp).client }
    private val resume by lazy { (application as XtreamApp).resume }

    private val keywords = listOf("sport", "ppv", "event", "football", "soccer", "nba", "nfl",
        "nhl", "mlb", "ufc", "mma", "f1", "formula", "motogp", "cricket", "tennis", "golf",
        "boxing", "wwe", "wrestl", "fight", "league", "liga", "ligue", "serie a", "bundesliga",
        "dazn", "espn", "bein", "tnt sport", "sky sport", "rugby", "darts", "racing", "uefa",
        "epl", "premier", "champions", "match", "live ")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply {
            text = "Loading sports & events…"; textSize = 16f
            setTextColor(Color.parseColor("#80CBC4")); setPadding(24, 16, 24, 4)
        }
        categoryList = ListView(this)
        channelList = ListView(this).apply { divider = null; dividerHeight = 0 }
        channelAdapter = com.nirajgtm.xtreamtv.ui.ChannelRowAdapter(this, application as XtreamApp)
        channelList.adapter = channelAdapter
        val panes = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(categoryList, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0.42f))
            addView(channelList, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 0.58f))
        }
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#101820"))
            addView(status)
            addView(panes, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        }
        setContentView(root)

        categoryList.setOnItemClickListener { _, _, pos, _ -> selectCategory(pos, focus = true) }
        categoryList.onItemSelectedListener = object : android.widget.AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: android.widget.AdapterView<*>?, v: View?, pos: Int, id: Long) = selectCategory(pos, focus = false)
            override fun onNothingSelected(p: android.widget.AdapterView<*>?) {}
        }
        channelList.setOnItemClickListener { _, _, pos, _ -> playChannel(pos) }
        channelList.setOnItemLongClickListener { _, _, pos, _ -> toggleFavorite(pos); true }
        preview = com.nirajgtm.xtreamtv.ui.ChannelPreviewController(this, channelList) { pos ->
            channels.getOrNull(pos)?.let { it.id to client.liveUrl(it.id) }
        }.also { it.attach() }
        loadCategories()
    }

    private fun loadCategories() {
        thread {
            if (!client.loaded) client.loadCatalogs { }
            val all = client.liveCategories()
            val sports = all.filter { c -> keywords.any { c.name.lowercase().contains(it) } }
            runOnUiThread {
                categories = sports
                status.text = "Sports & Live Events — ${sports.size} categories"
                categoryList.adapter = whiteAdapter(sports.map { cleanCategory(it.name) })
                if (sports.isNotEmpty()) selectCategory(0, focus = false)
                categoryList.requestFocus()
            }
        }
    }

    override fun onPause() {
        super.onPause()
        preview?.pause()
    }

    override fun onDestroy() {
        super.onDestroy()
        preview?.release()
    }

    private fun selectCategory(index: Int, focus: Boolean) {
        val cat = categories.getOrNull(index) ?: return
        channels = emptyList()
        channelAdapter.setChannels(emptyList())
        thread {
            val list = client.channelsInCategory(cat.id)
                .sortedByDescending { resume.playCount("live:${it.id}") } // most-watched first
            runOnUiThread {
                channels = list
                channelAdapter.setChannels(list)
                channelList.setSelection(0)
                if (focus) channelList.requestFocus()
            }
        }
    }

    private fun toggleFavorite(position: Int) {
        val channel = channels.getOrNull(position) ?: return
        val nowFav = resume.toggleFavorite(channel.id)
        android.widget.Toast.makeText(this,
            (if (nowFav) "Added to" else "Removed from") + " favorites: ${TitleParser.parse(channel.name).clean}",
            android.widget.Toast.LENGTH_SHORT).show()
        channelAdapter.notifyDataSetChanged()
    }

    private fun playChannel(position: Int) {
        val channel = channels.getOrNull(position) ?: return
        val app = application as XtreamApp
        app.liveZapList = channels.map {
            XtreamApp.LiveZapItem(it.id, client.liveUrl(it.id), TitleParser.parse(it.name).clean)
        }
        resume.bumpPlay("live:${channel.id}")
        resume.touchLiveLang(com.nirajgtm.xtreamtv.data.LiveCatalog.bucketOf(channel.name), System.currentTimeMillis())
        startActivity(Intent(this, PlayerActivity::class.java)
            .putExtra("url", client.liveUrl(channel.id))
            .putExtra("title", TitleParser.parse(channel.name).clean)
            .putExtra("isLive", true)
            .putExtra("liveIndex", position)
            .putExtra("channelId", channel.id))
    }

    /** Drop the "XX|" region prefix and map superscript quality marks to ASCII. */
    private fun cleanCategory(name: String): String {
        var s = name.substringAfter("|", name).trim()
        val marks = mapOf("ᵁᴴᴰ" to "UHD", "ᴴᴰ" to "HD", "ᴿᴬᵂ" to "RAW", "ⱽᴵᴾ" to "VIP",
            "ˢᴰ" to "SD", "ᴰᴼᴸᴮʸ" to "Dolby", "ᴬᵁᴰᴵᴼ" to "Audio", "ᴷ" to "K")
        for ((m, r) in marks) s = s.replace(m, r)
        s = s.replace(Regex("[\\u02B0-\\u02FF\\u1D2C-\\u1D6A\\u2070-\\u209F\\u1DA0-\\u1DBF³⁸⁴⁰ᴾ]"), "")
        return s.replace(Regex("\\s{2,}"), " ").trim(' ', '|', '-')
    }

    private fun whiteAdapter(labels: List<String>): ArrayAdapter<String> =
        object : ArrayAdapter<String>(this, android.R.layout.simple_list_item_1, labels) {
            override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
                val v = super.getView(position, convertView, parent) as TextView
                v.setTextColor(Color.WHITE); return v
            }
        }
}
