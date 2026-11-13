package com.nirajgtm.xtreamtv

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.nirajgtm.xtreamtv.data.XtreamCredentials
import kotlin.concurrent.thread

/**
 * The Xtream account screen: type in a server, test it, save it.
 *
 * Saving adopts the account app-wide and wipes the old account's cached
 * catalogues, so the caller is told (via [RESULT_ACCOUNT_CHANGED]) that it needs
 * to reload. With no account configured yet the screen becomes a required setup
 * form: no Cancel, and Back leaves the app rather than dropping the user on an
 * empty home screen.
 */
class SettingsActivity : Activity() {

    private lateinit var credentials: XtreamCredentials

    private lateinit var serverField: EditText
    private lateinit var usernameField: EditText
    private lateinit var passwordField: EditText
    private lateinit var showPassword: CheckBox
    private lateinit var testButton: Button
    private lateinit var saveButton: Button
    private lateinit var cancelButton: Button
    private lateinit var statusLine: TextView

    /** No account at all yet: the screen is a setup form the user can't back out of. */
    private var firstRun = false

    // What is on disk right now, so an edit can be told from an untouched field.
    private var storedServer = ""
    private var storedUsername = ""
    private var storedPassword = ""

    /** The exact values the last "Test connection" ran against, and how it went.
     *  Any later edit makes these stop matching, which invalidates the result. */
    private var testedValues: Triple<String, String, String>? = null
    private var testedOk = false

    private val ui = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        credentials = XtreamCredentials(this)
        firstRun = !credentials.isConfigured
        if (!firstRun) {
            storedServer = credentials.server
            storedUsername = credentials.username
            storedPassword = credentials.password
        }
        setContentView(buildLayout())
        serverField.post { serverField.requestFocus() }
    }

    // ---- Layout ----

    private fun buildLayout(): View {
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#0B0F14"))
            setPadding(dp(56), dp(36), dp(56), dp(36))
        }

        column.addView(TextView(this).apply {
            text = if (firstRun) "Set up your Xtream account" else "Settings"
            textSize = 34f
            setTextColor(Color.WHITE)
            letterSpacing = 0.03f
            setTypeface(typeface, android.graphics.Typeface.BOLD)
        })
        if (firstRun) {
            column.addView(TextView(this).apply {
                text = "Enter the server address, username and password your IPTV " +
                    "provider gave you. Test the connection, then save to start watching."
                textSize = 16f
                setTextColor(Color.parseColor("#9FB3C0"))
                setPadding(0, dp(10), 0, 0)
                setLineSpacing(dp(4).toFloat(), 1f)
            })
        }

        column.addView(TextView(this).apply {
            text = "Xtream account"
            textSize = 15f
            setTextColor(Color.parseColor("#80CBC4"))
            letterSpacing = 0.12f
            isAllCaps = true
            setPadding(0, dp(28), 0, dp(10))
        })

        serverField = inputField("http://your-server.com:8080", InputType.TYPE_TEXT_VARIATION_URI)
        usernameField = inputField("username", InputType.TYPE_TEXT_VARIATION_NORMAL)
        passwordField = inputField("password", InputType.TYPE_TEXT_VARIATION_PASSWORD)

        if (!firstRun) {
            serverField.setText(storedServer)
            usernameField.setText(storedUsername)
            passwordField.setText(storedPassword)
        }

        column.addView(labelled("Server URL", serverField))
        column.addView(labelled("Username", usernameField))
        column.addView(labelled("Password", passwordField))

        showPassword = CheckBox(this).apply {
            text = "Show password"
            textSize = 16f
            setTextColor(Color.WHITE)
            isFocusable = true
            setPadding(dp(10), dp(8), 0, dp(8))
            buttonTintList = android.content.res.ColorStateList.valueOf(Color.parseColor("#80CBC4"))
            setOnCheckedChangeListener { _, checked -> applyPasswordVisibility(checked) }
            setOnFocusChangeListener { _, focused ->
                setTextColor(if (focused) Color.parseColor("#80CBC4") else Color.WHITE)
            }
        }
        column.addView(showPassword)

        testButton = pillButton("Test connection") { runConnectionTest() }
        saveButton = pillButton("Save") { attemptSave() }
        cancelButton = pillButton("Cancel") { finish() }
        if (firstRun) {
            cancelButton.visibility = View.GONE
            cancelButton.isEnabled = false
        }

        val buttonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(0, dp(22), 0, 0)
            addView(testButton)
            addView(saveButton, spacedParams())
            addView(cancelButton, spacedParams())
        }
        column.addView(buttonRow)

        statusLine = TextView(this).apply {
            textSize = 16f
            setTextColor(Color.parseColor("#9FB3C0"))
            setPadding(0, dp(20), 0, 0)
            text = ""
        }
        column.addView(statusLine)

        return ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(Color.parseColor("#0B0F14"))
            descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
            addView(column, ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }
    }

    private fun spacedParams() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
        .apply { marginStart = dp(18) }

    /** A caption above its field, as one block in the column. */
    private fun labelled(caption: String, field: EditText): View =
        LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(12), 0, 0)
            addView(TextView(this@SettingsActivity).apply {
                text = caption
                textSize = 15f
                setTextColor(Color.parseColor("#9FB3C0"))
                setPadding(dp(6), 0, 0, dp(6))
            })
            addView(field, LinearLayout.LayoutParams(
                dp(620), LinearLayout.LayoutParams.WRAP_CONTENT))
        }

    /** Big text, single line, and a focus ring you can see from the sofa. */
    private fun inputField(hintText: String, variation: Int): EditText = EditText(this).apply {
        hint = hintText
        setHintTextColor(Color.parseColor("#557788"))
        setTextColor(Color.WHITE)
        textSize = 20f
        isSingleLine = true
        inputType = InputType.TYPE_CLASS_TEXT or variation
        imeOptions = EditorInfo.IME_ACTION_NEXT
        setPadding(dp(20), dp(16), dp(20), dp(16))
        styleField(this, false)
        setOnFocusChangeListener { _, focused -> styleField(this, focused) }
        addTextChangedListener(object : android.text.TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
            override fun afterTextChanged(s: android.text.Editable?) {
                // An edit retires whatever the last test proved.
                if (testedValues != null && testedValues != currentValues()) clearStatus()
            }
        })
    }

    private fun styleField(field: EditText, focused: Boolean) {
        field.background = com.nirajgtm.xtreamtv.ui.Squircle(
            fillColor = Color.parseColor(if (focused) "#16242F" else "#111A22"),
            radiusPx = dp(12).toFloat(),
            strokeColor = Color.parseColor(if (focused) "#80CBC4" else "#33FFFFFF"),
            strokeWidthPx = dp(if (focused) 3 else 1).toFloat())
    }

    /** The app's pill button: white when focused, translucent otherwise. */
    private fun pillButton(label: String, onClick: () -> Unit): Button = Button(this).apply {
        text = label
        textSize = 17f
        setOnClickListener { onClick() }
        setOnFocusChangeListener { _, _ -> stylePill(this) }
        stylePill(this)
    }

    private fun stylePill(button: Button) {
        val focused = button.isFocused && button.isEnabled
        button.stateListAnimator = null
        button.elevation = 0f
        button.background = com.nirajgtm.xtreamtv.ui.Squircle(
            if (focused) Color.WHITE else Color.parseColor("#33FFFFFF"))
        button.setTextColor(when {
            focused -> Color.parseColor("#0B0F14")
            button.isEnabled -> Color.WHITE
            else -> Color.parseColor("#88FFFFFF")
        })
        button.isAllCaps = false
        button.setPadding(dp(28), dp(14), dp(28), dp(14))
        button.scaleX = if (focused) 1.04f else 1f
        button.scaleY = if (focused) 1.04f else 1f
    }

    private fun applyPasswordVisibility(visible: Boolean) {
        val cursor = passwordField.selectionEnd
        passwordField.inputType = InputType.TYPE_CLASS_TEXT or
            (if (visible) InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD
             else InputType.TYPE_TEXT_VARIATION_PASSWORD)
        // Changing inputType resets the typeface to monospace; put it back.
        passwordField.typeface = android.graphics.Typeface.DEFAULT
        passwordField.imeOptions = EditorInfo.IME_ACTION_NEXT
        passwordField.setSelection(cursor.coerceIn(0, passwordField.text.length))
    }

    // ---- Test connection ----

    private fun currentValues() = Triple(
        serverField.text.toString().trim(),
        usernameField.text.toString().trim(),
        passwordField.text.toString().trim())

    private fun runConnectionTest() {
        val (server, username, password) = currentValues()
        testButton.isEnabled = false
        stylePill(testButton)
        testButton.text = "Testing…"
        statusLine.setTextColor(Color.parseColor("#9FB3C0"))
        statusLine.text = "Testing…"
        thread {
            val result = XtreamCredentials.test(server, username, password)
            ui.post {
                testButton.isEnabled = true
                testButton.text = "Test connection"
                stylePill(testButton)
                testedValues = Triple(server, username, password)
                testedOk = result.ok
                showStatus(result.ok, result.message)
            }
        }
    }

    private fun showStatus(ok: Boolean, message: String) {
        statusLine.setTextColor(Color.parseColor(if (ok) "#80CBC4" else "#FF6B6B"))
        statusLine.text = message
    }

    private fun clearStatus() {
        statusLine.text = ""
        statusLine.setTextColor(Color.parseColor("#9FB3C0"))
    }

    // ---- Save ----

    private fun hasChanges(): Boolean {
        val (server, username, password) = currentValues()
        return XtreamCredentials.normalizeServer(server) != XtreamCredentials.normalizeServer(storedServer) ||
            username != storedUsername || password != storedPassword
    }

    /** True when the last test ran against exactly these values and failed. */
    private fun lastTestFailedForTheseValues(): Boolean =
        testedValues == currentValues() && !testedOk

    private fun attemptSave() {
        val (server, username, password) = currentValues()
        if (server.isBlank() || username.isBlank() || password.isBlank()) {
            showStatus(false, "Fill in server, username and password.")
            return
        }
        if (lastTestFailedForTheseValues()) {
            android.app.AlertDialog.Builder(this)
                .setTitle("Save anyway?")
                .setMessage("This account failed the connection test. Save anyway?")
                .setPositiveButton("Save") { _, _ -> commitSave() }
                .setNegativeButton("Cancel", null)
                .show()
            return
        }
        commitSave()
    }

    private fun commitSave() {
        val (server, username, password) = currentValues()
        val changed = hasChanges()
        credentials.save(server, username, password)
        // Adopting the account also wipes the previous account's cached catalogues.
        (application as XtreamApp).client.switchAccount(credentials)
        storedServer = credentials.server
        storedUsername = credentials.username
        storedPassword = credentials.password
        android.widget.Toast.makeText(this, "Account saved", android.widget.Toast.LENGTH_SHORT).show()
        setResult(if (changed) RESULT_ACCOUNT_CHANGED else RESULT_OK)
        finish()
    }

    // ---- Back ----

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Nothing configured yet: there is no working screen to go back to.
        if (firstRun) { finishAffinity(); return }
        if (!hasChanges()) { finish(); return }
        android.app.AlertDialog.Builder(this)
            .setTitle("Save changes?")
            .setMessage("Your account details have changed.")
            .setPositiveButton("Save") { _, _ -> attemptSave() }
            .setNegativeButton("Discard") { _, _ -> finish() }
            .setNeutralButton("Cancel", null)
            .show()
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt().coerceAtLeast(1)

    companion object {
        /** Sent back when the saved account actually changed, so the caller reloads. */
        const val RESULT_ACCOUNT_CHANGED = 101

        fun intent(context: Context): Intent = Intent(context, SettingsActivity::class.java)
    }
}
