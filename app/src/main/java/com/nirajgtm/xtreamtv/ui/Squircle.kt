package com.nirajgtm.xtreamtv.ui

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Drawable
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.tan

/**
 * A pill (or rounded rectangle) whose outline is **curvature continuous**.
 *
 * A plain capsule joins a straight edge to a semicircle, so curvature jumps from
 * 0 to 1/r at the join and the eye reads that step as a kink. A superellipse
 * fixes the join only on paper: at pill proportions n=2.2 ramps curvature over
 * ~0.01r of arc (half a pixel here, so the kink survives) while flattening the
 * extremity to ~7x the half-height, which is what makes it look geometric; push
 * n up and the flat spot grows until the pill reads as a rectangle.
 *
 * So the shape is defined by its curvature instead. Each end holds a constant
 * (genuinely circular) curvature across [PLATEAU] of its arclength and ramps
 * smoothly to zero over the rest, and the outline is integrated from that. The
 * ramp is monotone with no overshoot, it spans ~0.9r of arc, and the tip stays
 * 98% of a true semicircle: round ends *and* an invisible join.
 */
class Squircle(
    private val fillColor: Int,
    private val radiusPx: Float = Float.MAX_VALUE, // default: capsule (half the height)
    private val strokeColor: Int = Color.TRANSPARENT,
    private val strokeWidthPx: Float = 0f,
    @Suppress("UNUSED_PARAMETER") exponent: Float = 2.2f // legacy, kept for callers
) : Drawable() {

    private val fillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = fillColor
    }
    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = strokeColor
        strokeWidth = strokeWidthPx
    }
    private val path = Path()

    override fun onBoundsChange(bounds: Rect) {
        super.onBoundsChange(bounds)
        rebuild(bounds)
    }

    private fun rebuild(b: Rect) {
        path.reset()
        if (b.width() <= 0 || b.height() <= 0) return
        // Inset by half the stroke so the outline isn't clipped by the bounds.
        val inset = strokeWidthPx / 2f
        val left = b.left + inset
        val top = b.top + inset
        val right = b.right - inset
        val bottom = b.bottom - inset
        val w = right - left
        val h = bottom - top
        if (w <= 0f || h <= 0f) return
        val r = min(radiusPx, min(w, h) / 2f)
        if (r <= 0f) { path.addRect(left, top, right, bottom, Path.Direction.CW); return }

        when {
            r >= h / 2f - 0.001f && w >= h -> {          // wide capsule: caps at the ends
                val (cap, reach) = cap(w / (2f * h), h)
                path.moveTo(left + reach, top)
                path.lineTo(right - reach, top)
                addArc(cap, right - reach, top, 1f, 0f, h)
                path.lineTo(left + reach, bottom)
                addArc(cap, left + reach, bottom, -1f, 0f, h)
            }
            r >= w / 2f - 0.001f -> {                    // tall capsule: caps top and bottom
                val (cap, reach) = cap(h / (2f * w), w)
                path.moveTo(right, top + reach)
                path.lineTo(right, bottom - reach)
                addArc(cap, right, bottom - reach, 0f, 1f, w)
                path.lineTo(left, top + reach)
                addArc(cap, left, top + reach, 0f, -1f, w)
            }
            else -> {                                    // rounded rectangle
                val reach = min(r * CORNER_SPAN, min(w, h) / 2f)
                val k = reach / CORNER_SPAN
                path.moveTo(left + reach, top)
                path.lineTo(right - reach, top)
                addArc(CORNER, right - reach, top, 1f, 0f, k)
                path.lineTo(right, bottom - reach)
                addArc(CORNER, right, bottom - reach, 0f, 1f, k)
                path.lineTo(left + reach, bottom)
                addArc(CORNER, left + reach, bottom, -1f, 0f, k)
                path.lineTo(left, top + reach)
                addArc(CORNER, left, top + reach, 0f, -1f, k)
            }
        }
        path.close()
    }

    /**
     * The end cap, plus how far it reaches back along the long edge. A short pill
     * has no room for the full easing, so the cap is blended back toward a plain
     * semicircle by however much [roomRatio] (half-width over height) allows.
     */
    private fun cap(roomRatio: Float, scale: Float): Pair<FloatArray, Float> {
        val t = ((min(CAP_SPAN, roomRatio) - HALF) / (CAP_SPAN - HALF)).coerceIn(0f, 1f)
        val bez = FloatArray(CAP_SMOOTH.size) { CAP_ROUND[it] + t * (CAP_SMOOTH[it] - CAP_ROUND[it]) }
        return bez to (HALF + t * (CAP_SPAN - HALF)) * scale
    }

    /**
     * Append one arc, mapping its local frame (start at 0,0 heading +x, curving
     * toward +y) onto the canvas: local +x becomes [ux],[uy] and local +y its
     * quarter turn, both scaled by [k].
     */
    private fun addArc(bez: FloatArray, sx: Float, sy: Float, ux: Float, uy: Float, k: Float) {
        val vx = -uy
        val vy = ux
        var i = 0
        while (i < bez.size) {
            path.cubicTo(
                sx + k * (bez[i] * ux + bez[i + 1] * vx), sy + k * (bez[i] * uy + bez[i + 1] * vy),
                sx + k * (bez[i + 2] * ux + bez[i + 3] * vx), sy + k * (bez[i + 2] * uy + bez[i + 3] * vy),
                sx + k * (bez[i + 4] * ux + bez[i + 5] * vx), sy + k * (bez[i + 4] * uy + bez[i + 5] * vy))
            i += 6
        }
    }

    override fun draw(canvas: Canvas) {
        if (path.isEmpty) rebuild(bounds)
        if (Color.alpha(fillColor) != 0) canvas.drawPath(path, fillPaint)
        if (strokeWidthPx > 0f && Color.alpha(strokeColor) != 0) canvas.drawPath(path, strokePaint)
    }

    override fun setAlpha(alpha: Int) { fillPaint.alpha = alpha; strokePaint.alpha = alpha }
    override fun setColorFilter(filter: ColorFilter?) {
        fillPaint.colorFilter = filter; strokePaint.colorFilter = filter
    }
    @Deprecated("Deprecated in Drawable", ReplaceWith("PixelFormat.TRANSLUCENT"))
    override fun getOpacity() = PixelFormat.TRANSLUCENT

    private companion object {
        /** Fraction of an end's arclength held at constant curvature. Lower eases
         *  the join over more of the edge but pinches the tip; 0.55 keeps the tip
         *  at 98% of a true semicircle while the ramp still spans ~0.9r. */
        const val PLATEAU = 0.55f
        const val STEPS = 384       // integration steps, divisible by both segment counts
        // Cubics per piece. At these counts the outline sits within 0.02px of the
        // integrated curve and the curvature step at a segment join stays under 0.7%.
        const val CAP_SEGS = 24
        const val CORNER_SEGS = 12
        const val HALF = 0.5f       // a semicircular cap reaches half its own height

        /** Ends, normalised to unit height: fully eased, and the plain semicircle
         *  they are blended back toward when a pill is too short for the easing.
         *  [CAP_SPAN] is how far a unit-height eased cap reaches back along the edge. */
        private val eased = smoothArc(PI.toFloat(), PLATEAU, CAP_SEGS)
        val CAP_SMOOTH: FloatArray = eased.first
        val CAP_SPAN: Float = eased.second
        val CAP_ROUND: FloatArray = smoothArc(PI.toFloat(), 1f, CAP_SEGS).first

        /** Rounded-rect corner, unit peak radius, and its reach along each edge. */
        private val corner = smoothArc(PI.toFloat() / 2f, PLATEAU, CORNER_SEGS)
        val CORNER: FloatArray = corner.first
        val CORNER_SPAN: Float = corner.second

        /**
         * Integrate a curve that starts at (0,0) heading +x and turns [turn]
         * radians toward +y, with peak curvature 1, zero curvature at both ends
         * and a constant plateau across the middle [plateau] of its arclength.
         *
         * Returns cubic control points (6 floats per segment, ready for cubicTo)
         * and the curve's reach along the +x axis. A 180-degree arc is normalised
         * to unit height so caps of different easing can be blended; a 90-degree
         * corner keeps unit radius, so its reach is its span along each edge.
         */
        fun smoothArc(turn: Float, plateau: Float, segs: Int): Pair<FloatArray, Float> {
            val ramp = (1f - plateau) / 2f
            fun curvature(u: Float): Float {
                val v = when {
                    ramp <= 0f -> 1f
                    u < ramp -> u / ramp
                    u > 1f - ramp -> (1f - u) / ramp
                    else -> 1f
                }
                return v * v * (3f - 2f * v)          // smoothstep: zero slope at both ends
            }
            // Simpson's rule on the mean curvature, so the total turning is exact.
            var mean = curvature(0f) + curvature(1f)
            for (i in 1 until STEPS) {
                mean += (if (i % 2 == 1) 4f else 2f) * curvature(i.toFloat() / STEPS)
            }
            val ds = turn / (mean / (3f * STEPS)) / STEPS

            val xs = FloatArray(STEPS + 1)
            val ys = FloatArray(STEPS + 1)
            val th = FloatArray(STEPS + 1)
            var x = 0f; var y = 0f; var a = 0f; var reach = 0f
            for (i in 0 until STEPS) {
                val k = curvature((i + 0.5f) / STEPS)
                val da = k * ds
                if (k < 1e-6f) {                       // straight step
                    x += cos(a) * ds; y += sin(a) * ds
                } else {                               // exact arc step
                    x += (sin(a + da) - sin(a)) / k; y -= (cos(a + da) - cos(a)) / k
                }
                a += da
                xs[i + 1] = x; ys[i + 1] = y; th[i + 1] = a
                if (x > reach) reach = x
            }
            // Scale so a half turn ends up one unit tall; a quarter turn keeps unit radius.
            val norm = if (turn > 2f) 1f / ys[STEPS] else 1f

            val per = STEPS / segs
            val bez = FloatArray(segs * 6)
            for (j in 0 until segs) {
                val i0 = j * per
                val i1 = i0 + per
                val dth = th[i1] - th[i0]
                val chord = hypot(xs[i1] - xs[i0], ys[i1] - ys[i0])
                // Control arm that makes a cubic match a circular arc of this sweep.
                val arm = if (dth < 1e-5f) chord / 3f
                          else 4f / 3f * tan(dth / 4f) * chord / (2f * sin(dth / 2f))
                val o = j * 6
                bez[o] = (xs[i0] + arm * cos(th[i0])) * norm
                bez[o + 1] = (ys[i0] + arm * sin(th[i0])) * norm
                bez[o + 2] = (xs[i1] - arm * cos(th[i1])) * norm
                bez[o + 3] = (ys[i1] - arm * sin(th[i1])) * norm
                bez[o + 4] = xs[i1] * norm
                bez[o + 5] = ys[i1] * norm
            }
            return bez to reach * norm
        }
    }
}
