package com.nirajgtm.xtreamtv.ui

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface

/**
 * Generates a stylized typography tile (gradient background + centered label)
 * at runtime, so every category/language gets a tile with no bundled images.
 * A per-label hue keeps them visually distinct; results are cached.
 */
object TileArt {
    private val cache = HashMap<String, Bitmap>()

    fun tile(label: String, w: Int = 360, h: Int = 202): Bitmap {
        cache[label]?.let { return it }
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        val hue = (Math.abs(label.hashCode()) % 360).toFloat()
        val top = Color.HSVToColor(floatArrayOf(hue, 0.55f, 0.5f))
        val bottom = Color.HSVToColor(floatArrayOf((hue + 24f) % 360f, 0.7f, 0.28f))
        val bg = Paint().apply {
            shader = LinearGradient(0f, 0f, w.toFloat(), h.toFloat(), top, bottom, Shader.TileMode.CLAMP)
        }
        c.drawRoundRect(0f, 0f, w.toFloat(), h.toFloat(), 18f, 18f, bg)
        // subtle inner accent bar
        Paint().apply { color = Color.argb(60, 255, 255, 255) }.also {
            c.drawRoundRect(0f, h - 12f, w.toFloat(), h.toFloat(), 6f, 6f, it)
        }
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textAlign = Paint.Align.CENTER
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textSize = fitTextSize(this, label, w * 0.86f, 56f)
        }
        val fm = text.fontMetrics
        c.drawText(label, w / 2f, h / 2f - (fm.ascent + fm.descent) / 2f, text)
        cache[label] = bmp
        return bmp
    }

    private fun fitTextSize(paint: Paint, text: String, maxWidth: Float, start: Float): Float {
        var size = start
        paint.textSize = size
        while (paint.measureText(text) > maxWidth && size > 18f) {
            size -= 2f
            paint.textSize = size
        }
        return size
    }
}
