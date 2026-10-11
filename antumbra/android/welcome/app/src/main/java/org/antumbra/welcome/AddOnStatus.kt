// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL
import java.util.concurrent.TimeUnit
import org.json.JSONException
import org.json.JSONObject

/** The DNS filter's own counters (antumbra/android/dnsfilter, internal/status). */
data class FilterStatus(
    val queries: Long,
    val blocked: Long,
    val listLoaded: Boolean,
    val listSize: Long,
    val listVersion: String,
    val upstreamState: String,
)

/**
 * What the module's status.json says, as far as Welcome shows it. Every
 * field is optional: the file is written by the module's service.sh and
 * passed on by the filter under "module". It lives in a directory that tor's
 * uid can also write, and when the filter is down any app could answer on
 * its port, so it is shown, never trusted to allow anything. The one
 * decision it takes part in can only refuse: [sessionLatched] stops a
 * second Start in the same boot.
 */
data class ModuleStatus(
    val torBootstrap: Int?,
    val torSummary: String?,
    val torNetworkEnabled: Boolean?,
    /** Why tor cannot connect, in the module's words (such as bridges that need lyrebird). */
    val torError: String?,
    val firewallState: String?,
    val firewallHash: String?,
    /** The module has latched a started session in this boot (welcome.started, or a session_id). */
    val sessionLatched: Boolean,
)

data class AddOnStatus(
    /** Null when the status page did not answer with a filter document. */
    val filter: FilterStatus?,
    val module: ModuleStatus?,
    /** Short reason when the page could not be read. */
    val error: String?,
) {
    val filterAnswered: Boolean get() = filter != null

    companion object {
        val UNKNOWN = AddOnStatus(null, null, "not checked yet")
    }
}

object StatusPage {
    const val URL = "http://127.0.0.1:5380/status"
    private const val MAX_BYTES = 256 * 1024

    /** Reads the status page; never throws. Call off the main thread. */
    fun fetch(timeoutMs: Int = 1500): AddOnStatus = try {
        val connection = URL(URL).openConnection(Proxy.NO_PROXY) as HttpURLConnection
        try {
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Accept", "application/json")
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_OK) {
                AddOnStatus(null, null, "HTTP $code")
            } else {
                parse(readLimited(connection))
            }
        } finally {
            connection.disconnect()
        }
    } catch (e: Exception) {
        AddOnStatus(null, null, e.javaClass.simpleName)
    }

    private fun readLimited(connection: HttpURLConnection): String {
        val out = ByteArrayOutputStream()
        connection.inputStream.use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > MAX_BYTES) throw IllegalStateException("status page too large")
            }
        }
        return out.toString(Charsets.UTF_8.name())
    }

    /** Parses the status document; a document that is not the filter's gives an error status. */
    fun parse(body: String): AddOnStatus {
        val doc = try {
            JSONObject(body)
        } catch (e: JSONException) {
            return AddOnStatus(null, null, "not JSON")
        }
        if (doc.optString("service") != "antumbra-dnsfilter") {
            return AddOnStatus(null, null, "not the Antumbra DNS filter")
        }
        val list = doc.optJSONObject("list")
        val upstream = doc.optJSONObject("upstream")
        val filter = FilterStatus(
            queries = doc.optLong("queries"),
            blocked = doc.optLong("blocked"),
            listLoaded = list?.optBoolean("loaded") ?: false,
            listSize = list?.optLong("size") ?: 0,
            listVersion = list?.optString("version").orEmpty(),
            upstreamState = upstream?.optString("state").orEmpty(),
        )
        return AddOnStatus(filter, doc.optJSONObject("module")?.let(::parseModule), null)
    }

    /**
     * The module's part. Welcome reads these fields (README, "What Welcome
     * reads from the status page"):
     *   tor.bootstrap (0-100), tor.summary (text), tor.network
     *   ("enabled"/"disabled"), tor.error (text), firewall.state ("live",
     *   "armed", ...), firewall.hash (the ruleset hash prefix),
     *   welcome.started (true once the module latched a session) or, from
     *   older modules, a non-empty welcome.session_id.
     */
    fun parseModule(m: JSONObject): ModuleStatus {
        val tor = m.optJSONObject("tor")
        val fw = m.optJSONObject("firewall")
        val welcome = m.optJSONObject("welcome")
        val latched = welcome != null && (
            welcome.opt("started").let { it == true || it == 1 || it == "1" || it == "true" } ||
                welcome.optString("session_id").isNotBlank()
            )
        val bootstrap = tor?.let { t ->
            if (t.has("bootstrap") && !t.isNull("bootstrap")) t.optInt("bootstrap", -1).takeIf { it in 0..100 } else null
        }
        val network = when (tor?.optString("network")) {
            "enabled" -> true
            "disabled" -> false
            else -> null
        }
        return ModuleStatus(
            torBootstrap = bootstrap,
            torSummary = tor?.optString("summary")?.takeIf { it.isNotBlank() }?.take(200),
            torNetworkEnabled = network,
            torError = tor?.optString("error")?.takeIf { it.isNotBlank() }?.take(300),
            firewallState = fw?.optString("state")?.takeIf { it.isNotBlank() }?.take(40),
            firewallHash = fw?.optString("hash")?.takeIf { it.isNotBlank() }?.take(64),
            sessionLatched = latched,
        )
    }
}

/** Reads a system property with the getprop tool (apps have no public API for it). */
object SystemProperty {
    fun read(name: String): String? = try {
        val process = ProcessBuilder("/system/bin/getprop", name).redirectErrorStream(true).start()
        val value = process.inputStream.bufferedReader().use { it.readText() }.trim()
        if (!process.waitFor(2, TimeUnit.SECONDS)) process.destroy()
        value
    } catch (e: Exception) {
        null
    }
}

/**
 * The firewall's own sign of life: the module publishes the ruleset hash
 * with 'resetprop -n antumbra.fw.armed <hash>' only after 'antumbra-fw
 * apply' succeeded and was verified. Only root can set it. Apps can read
 * it: an unlisted property is default_prop, which every coredomain process
 * may read (android16 sepolicy, private/coredomain.te), and untrusted_app
 * is a coredomain. If a future policy hid it, Welcome would see the add-on
 * as absent and keep Wi-Fi off: it fails closed.
 */
object FirewallProperty {
    const val NAME = "antumbra.fw.armed"

    fun read(): String? = SystemProperty.read(NAME)?.takeIf { Regex("[0-9a-f]{8,64}").matches(it) }
}

/** Whether the add-on is present, for the fail-closed Wi-Fi decision at Start. */
data class AddOnCheck(val firewallHash: String?, val status: AddOnStatus) {
    /**
     * The firewall property is the only proof (only root sets it). The
     * status page is shown but never counts: without the firewall, any app
     * could answer on 127.0.0.1:5380 as the DNS filter.
     */
    val present: Boolean get() = firewallHash != null

    /**
     * The module already latched a session in this boot, so a new Start
     * would change nothing in the module (it keeps the first one). Only
     * believed while the firewall property is set; it can only refuse.
     */
    val sessionLatched: Boolean get() = present && status.module?.sessionLatched == true

    companion object {
        fun run(): AddOnCheck = AddOnCheck(FirewallProperty.read(), StatusPage.fetch())
    }
}
