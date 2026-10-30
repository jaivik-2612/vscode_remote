// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle

/**
 * content://org.antumbra.welcome.state/session: one row with the session's
 * choices, for the Antumbra module (shared contract, README "The state
 * provider"). Read-only, and readable only by uid 0 (root) and uid 2000
 * (shell), checked with Binder.getCallingUid(). Every other caller,
 * including other apps, gets a SecurityException.
 *
 * The module's words come in through [call], from uid 0 only: not even
 * the shell may give them. Method "module_word" (MOD11) on the last calls,
 * kept by [CallWatch]; method "module_cell" (WEL8) on the cell radio and
 * this phone's Phone-mode gate, kept by [CellWatch]. Both stay in memory,
 * and there is no way to read them back.
 */
class StateProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val uid = Binder.getCallingUid()
        if (!StateRow.isAllowedCaller(uid)) {
            throw SecurityException("uid $uid may not read the Antumbra session")
        }
        require(uri.authority == StateRow.AUTHORITY && uri.path == "/" + StateRow.PATH) { "Unknown URI: $uri" }
        require(selection == null && selectionArgs == null) { "Selection is not supported" }
        val columns = StateRow.columns(projection)
        val values = StateRow.values(Session.current())
        return MatrixCursor(columns.toTypedArray(), 1).apply {
            addRow(columns.map { values.getValue(it) })
        }
    }

    override fun getType(uri: Uri): String = "vnd.android.cursor.item/vnd.org.antumbra.welcome.session"

    /**
     * The module's words, given by root with 'content call --method
     * module_word|module_cell --extra ...'. The binder's uid goes straight
     * to [ModuleCalls.receive], the one check: any other caller gets a
     * SecurityException before the method or the extras are looked at; an
     * unknown method or a malformed word an IllegalArgumentException.
     * Answers only that the word was taken ({v=1}), never the word.
     */
    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        ModuleCalls.receive(Binder.getCallingUid(), method, arg, { extrasOf(extras) }, CallWatch::take, CellWatch::take)
        return Bundle().apply { putInt("v", ModuleWord.VERSION) }
    }

    private fun extrasOf(extras: Bundle?): Map<String, Any?> = extras?.let { b ->
        b.keySet().associateWith {
            @Suppress("DEPRECATION")
            b.get(it)
        }
    } ?: emptyMap()

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("The Antumbra session is read-only")

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("The Antumbra session is read-only")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("The Antumbra session is read-only")
}

/** The provider's row, apart from Android classes so that it can be unit-tested. */
object StateRow {
    const val AUTHORITY = "org.antumbra.welcome.state"
    const val PATH = "session"

    /** The contract's columns, in this order (cell since WEL8, last). */
    val COLUMNS = listOf(
        "started", "tor_mode", "bridges", "mac", "admin", "unsafe_browser", "persistent", "session_id", "cell",
    )

    private const val ROOT_UID = 0
    private const val SHELL_UID = 2000

    fun isAllowedCaller(uid: Int): Boolean = uid == ROOT_UID || uid == SHELL_UID

    /** The requested columns (all of them for a null projection). */
    fun columns(projection: Array<out String>?): List<String> {
        if (projection == null) return COLUMNS
        require(projection.isNotEmpty()) { "Empty projection" }
        projection.forEach { require(it in COLUMNS) { "Unknown column: $it" } }
        return projection.toList()
    }

    /**
     * Column values. Integers are 0 or 1; bridges holds one bridge line per
     * line, separated by '\n' and empty when tor_mode is not bridges; cell
     * is off, phone or data (off before Start).
     */
    fun values(s: SessionState): Map<String, Any> = mapOf(
        "started" to s.started.int,
        "tor_mode" to s.torMode.wire,
        "bridges" to s.bridges.joinToString("\n"),
        "mac" to if (s.newMac) "new" else "keep",
        "admin" to s.admin.int,
        "unsafe_browser" to s.unsafeBrowser.int,
        "persistent" to s.persistent.int,
        "session_id" to s.sessionId,
        "cell" to s.cell.wire,
    )

    private val Boolean.int: Int get() = if (this) 1 else 0
}
