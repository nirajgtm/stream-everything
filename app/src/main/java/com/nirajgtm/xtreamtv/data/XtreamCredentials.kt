package com.nirajgtm.xtreamtv.data

import android.content.Context
import com.nirajgtm.xtreamtv.BuildConfig
import okhttp3.OkHttpClient
import okhttp3.Request
import com.google.gson.JsonParser
import java.util.concurrent.TimeUnit

/**
 * The Xtream account the app talks to.
 *
 * Stored on the device so it can be changed from Settings, but it falls back to
 * the values baked in at build time — builds made for a specific person keep
 * working untouched, and only an explicit save in Settings overrides them.
 */
class XtreamCredentials(context: Context) {

    private val sp = context.applicationContext
        .getSharedPreferences("xtream_credentials", Context.MODE_PRIVATE)

    val server: String get() = sp.getString(KEY_SERVER, null)?.takeIf { it.isNotBlank() }
        ?: BuildConfig.XTREAM_SERVER
    val username: String get() = sp.getString(KEY_USER, null)?.takeIf { it.isNotBlank() }
        ?: BuildConfig.XTREAM_USER
    val password: String get() = sp.getString(KEY_PASS, null)?.takeIf { it.isNotBlank() }
        ?: BuildConfig.XTREAM_PASS

    /** True once there is a usable account, whether saved here or built in. */
    val isConfigured: Boolean
        get() = server.isNotBlank() && username.isNotBlank() && password.isNotBlank()

    /** True when the user has saved their own account (not the built-in one). */
    val isUserSupplied: Boolean get() = sp.contains(KEY_SERVER)

    fun save(server: String, username: String, password: String) {
        sp.edit()
            .putString(KEY_SERVER, normalizeServer(server))
            .putString(KEY_USER, username.trim())
            .putString(KEY_PASS, password.trim())
            .apply()
    }

    /** Forget the saved account and fall back to the built-in one. */
    fun clear() = sp.edit().remove(KEY_SERVER).remove(KEY_USER).remove(KEY_PASS).apply()

    companion object {
        private const val KEY_SERVER = "server"
        private const val KEY_USER = "username"
        private const val KEY_PASS = "password"

        /** Accepts "host.com", "host.com:8080" or a full URL; always returns a URL. */
        fun normalizeServer(raw: String): String {
            val trimmed = raw.trim().trimEnd('/')
            if (trimmed.isEmpty()) return ""
            return if (trimmed.startsWith("http://", true) || trimmed.startsWith("https://", true))
                trimmed else "http://$trimmed"
        }

        /** Outcome of a "Test connection" tap. */
        data class TestResult(val ok: Boolean, val message: String)

        /**
         * Ask the server to authenticate the account. Network call — never run this
         * on the UI thread. Reports why it failed so the user can fix it, rather
         * than a bare "failed".
         */
        fun test(server: String, username: String, password: String): TestResult {
            val base = normalizeServer(server)
            if (base.isBlank() || username.isBlank() || password.isBlank())
                return TestResult(false, "Fill in server, username and password.")
            val url = "$base/player_api.php?username=$username&password=$password"
            val http = OkHttpClient.Builder()
                .connectTimeout(15, TimeUnit.SECONDS)
                .readTimeout(20, TimeUnit.SECONDS)
                .build()
            return try {
                http.newCall(Request.Builder().url(url).build()).execute().use { response ->
                    if (!response.isSuccessful)
                        return TestResult(false, "Server replied HTTP ${response.code}.")
                    val body = response.body?.string().orEmpty()
                    val info = try {
                        JsonParser.parseString(body).asJsonObject.getAsJsonObject("user_info")
                    } catch (_: Exception) {
                        return TestResult(false, "Not an Xtream server (unexpected reply).")
                    } ?: return TestResult(false, "Server did not return an account.")

                    val auth = info.get("auth")?.asString ?: "0"
                    val status = info.get("status")?.asString ?: ""
                    if (auth != "1" || status.equals("Banned", true) || status.equals("Disabled", true))
                        return TestResult(false, "Rejected: wrong username/password" +
                            if (status.isNotBlank()) " (status $status)." else ".")

                    val expiry = info.get("exp_date")?.asString?.toLongOrNull()
                        ?.let { java.text.SimpleDateFormat("d MMM yyyy", java.util.Locale.US)
                            .format(java.util.Date(it * 1000)) }
                    val connections = info.get("max_connections")?.asString
                    TestResult(true, buildString {
                        append("Connected")
                        if (status.isNotBlank()) append(" · $status")
                        if (expiry != null) append(" · expires $expiry")
                        if (!connections.isNullOrBlank()) append(" · $connections connections")
                    })
                }
            } catch (e: java.net.UnknownHostException) {
                TestResult(false, "Can't reach that server — check the address.")
            } catch (e: java.net.SocketTimeoutException) {
                TestResult(false, "Timed out reaching the server.")
            } catch (e: Exception) {
                TestResult(false, "Couldn't connect: ${e.message ?: "unknown error"}")
            }
        }
    }
}
