package com.nirajgtm.xtreamtv.ui

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/**
 * In-app voice search that reports words as they are spoken.
 *
 * The system recognizer dialog ([RecognizerIntent] + startActivityForResult) only
 * hands back a final transcript, so results could not update mid-sentence. This
 * drives [SpeechRecognizer] directly and forwards partial hypotheses, letting the
 * search run while you are still talking.
 *
 * It also fixes the "mic sometimes does nothing" case: a recognizer that is
 * already listening rejects a second [startListening], and one that is never
 * destroyed leaks the mic for the whole process. [start] is therefore idempotent —
 * it tears down any previous session first — and every terminal callback releases
 * the recognizer.
 */
class VoiceSearch(private val activity: Activity) {

    companion object {
        const val PERMISSION_REQUEST = 4712
        /** True when RECORD_AUDIO has been granted (required for in-app recognition). */
        fun hasPermission(activity: Activity): Boolean =
            activity.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        fun requestPermission(activity: Activity) =
            activity.requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), PERMISSION_REQUEST)
    }

    private var recognizer: SpeechRecognizer? = null
    /** True between [start] and a terminal callback; guards double-starts. */
    var listening = false
        private set

    fun available(): Boolean = SpeechRecognizer.isRecognitionAvailable(activity)

    /**
     * Begin listening. [onPartial] fires repeatedly as speech is recognized (use it
     * to search live), [onFinal] once with the finished transcript, and [onDone]
     * whenever the session ends — including errors, whose message it carries.
     */
    fun start(
        onPartial: (String) -> Unit,
        onFinal: (String) -> Unit,
        onDone: (String?) -> Unit
    ) {
        stop() // never stack sessions: a listening recognizer ignores startListening
        if (!available()) { onDone("Voice input isn't available on this device."); return }
        val speech = try {
            SpeechRecognizer.createSpeechRecognizer(activity)
        } catch (_: Exception) { null } ?: run { onDone("Could not start voice input."); return }
        recognizer = speech
        listening = true

        fun finish(message: String?) {
            listening = false
            stop()
            onDone(message)
        }

        speech.setRecognitionListener(object : RecognitionListener {
            override fun onPartialResults(results: Bundle?) {
                first(results)?.let(onPartial) // live: search while still speaking
            }
            override fun onResults(results: Bundle?) {
                first(results)?.let { onFinal(it) }
                finish(null)
            }
            override fun onError(error: Int) = finish(messageFor(error))
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
        }
        try {
            speech.startListening(intent)
        } catch (_: Exception) {
            finish("Could not start voice input.")
        }
    }

    /** Release the mic. Safe to call repeatedly and from any lifecycle callback. */
    fun stop() {
        listening = false
        recognizer?.let {
            try { it.cancel() } catch (_: Exception) {}
            try { it.destroy() } catch (_: Exception) {}
        }
        recognizer = null
    }

    private fun first(results: Bundle?): String? =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()?.takeIf { it.isNotBlank() }

    private fun messageFor(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_NO_MATCH,
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "Didn't catch that — try again."
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Microphone permission is needed for voice search."
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "Voice search needs a network connection."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "Voice input is busy — try again."
        else -> "Voice input failed — try again."
    }
}
