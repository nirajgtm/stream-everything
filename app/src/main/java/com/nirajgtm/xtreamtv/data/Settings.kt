package com.nirajgtm.xtreamtv.data

import android.content.Context

/** Global app settings, persisted in SharedPreferences (survives restart). */
class Settings(context: Context) {

    private val sp = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    /** Show the pause/forward/backward controls during Live TV. Off by default. */
    var liveControls: Boolean
        get() = sp.getBoolean("liveControls", false)
        set(value) { sp.edit().putBoolean("liveControls", value).apply() }

    /** Hide adult titles everywhere. ON by default; unlocked only by the phrase. */
    var adultFilter: Boolean
        get() = sp.getBoolean("adultFilter", true)
        set(value) { sp.edit().putBoolean("adultFilter", value).apply() }
}
