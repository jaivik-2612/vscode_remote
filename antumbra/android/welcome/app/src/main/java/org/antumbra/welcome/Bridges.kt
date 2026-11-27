// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

/**
 * Bridge lines as typed or pasted on the Welcome screen, checked before
 * they reach the module (which passes each line to tor over its control
 * socket as `SETCONF Bridge="<line>"`).
 *
 * The rules follow the archived Debian Antumbra (antumbra.settings
 * bridge_lines) with two changes for Android: obfs2 and obfs3 are no longer
 * offered (obsolete), and a line may contain only printable ASCII without
 * `"` or `\`, so that no line can end the quoted value early and add a
 * second control-port command.
 */
object Bridges {
    const val MAX_BRIDGES = 20
    const val MAX_LINE_LENGTH = 600

    /** Transports run by the pluggable-transport helper (lyrebird). */
    val TRANSPORTS = listOf("obfs4", "webtunnel", "meek_lite")

    /**
     * Whether this version of Antumbra can run [TRANSPORTS]. False until
     * the module ships lyrebird: until then the module refuses such
     * bridges, so Welcome refuses them first, and the built-in (obfs4)
     * bridges are shown as not available yet.
     */
    const val TRANSPORTS_AVAILABLE = false

    /** Transports that connect to the address on the line, as tor does for
     *  a plain bridge; that address must be IPv4 (IPv6 is off). webtunnel
     *  and meek_lite connect to the server named by url= instead, and their
     *  address is a placeholder, often an IPv6 one. */
    private val ADDRESSED = setOf("obfs4")

    /** The argument each transport cannot work without. */
    private val REQUIRED_ARG = mapOf("obfs4" to "cert=", "webtunnel" to "url=", "meek_lite" to "url=")

    sealed interface Problem {
        val line: Int
        data class None(override val line: Int = 0) : Problem
        data class TooMany(val max: Int, override val line: Int = 0) : Problem
        data class Snowflake(override val line: Int) : Problem
        data class UnknownType(override val line: Int, val type: String) : Problem
        data class Characters(override val line: Int) : Problem
        data class TooLong(override val line: Int) : Problem
        data class Ipv6(override val line: Int) : Problem
        data class Address(override val line: Int, val address: String) : Problem
        data class Fingerprint(override val line: Int) : Problem
        data class MissingArg(override val line: Int, val type: String, val arg: String) : Problem
        data class NeedsTransport(override val line: Int, val type: String) : Problem
    }

    sealed interface Result {
        data class Ok(val lines: List<String>) : Result
        data class Error(val problem: Problem) : Result
    }

    /**
     * Checks [text] (one bridge per line). Blank lines and lines starting
     * with `#` are skipped, a leading "Bridge " is dropped, and runs of
     * spaces or tabs become one space. Line numbers in problems count every
     * line of [text], from 1. With [transports] false, lines that need a
     * pluggable transport are refused.
     */
    fun parse(text: String, transports: Boolean = true): Result {
        val out = ArrayList<String>()
        text.split('\n').forEachIndexed { index, raw ->
            val number = index + 1
            var line = raw.trim().replace(Regex("[ \t]+"), " ")
            if (line.isEmpty() || line.startsWith("#")) return@forEachIndexed
            if (line.length > MAX_LINE_LENGTH) return Result.Error(Problem.TooLong(number))
            if (line.any { it < ' ' || it > '~' || it == '"' || it == '\\' }) {
                return Result.Error(Problem.Characters(number))
            }
            val first = line.substringBefore(' ')
            if (first.equals("bridge", ignoreCase = true)) {
                line = line.substringAfter(' ', "").trim()
                if (line.isEmpty()) return@forEachIndexed
            }
            val words = line.split(' ')
            checkLine(number, words, transports)?.let { return Result.Error(it) }
            out += line
            if (out.size > MAX_BRIDGES) return Result.Error(Problem.TooMany(MAX_BRIDGES))
        }
        if (out.isEmpty()) return Result.Error(Problem.None())
        return Result.Ok(out)
    }

    private fun checkLine(number: Int, words: List<String>, transports: Boolean): Problem? {
        val type = words[0]
        if (type.equals("snowflake", ignoreCase = true)) return Problem.Snowflake(number)
        val plain = type.firstOrNull()?.let { it.isDigit() || it == '[' } == true
        if (!plain && type !in TRANSPORTS) return Problem.UnknownType(number, type)
        if (!plain && !transports) return Problem.NeedsTransport(number, type)

        val address = if (plain) type else words.getOrNull(1) ?: return Problem.Address(number, "")
        if (plain || type in ADDRESSED) {
            if (address.startsWith("[") || address.count { it == ':' } > 1) return Problem.Ipv6(number)
            if (!isIpv4WithPort(address)) return Problem.Address(number, address)
        }
        // The fingerprint follows the address when it is present (it is
        // optional for plain bridges and placeholders, as in tor).
        val rest = words.drop(if (plain) 1 else 2)
        val fingerprint = rest.firstOrNull()?.takeIf { '=' !in it }
        if (fingerprint != null && !Regex("[0-9A-Fa-f]{40}").matches(fingerprint)) {
            return Problem.Fingerprint(number)
        }
        if (!plain) {
            val arg = REQUIRED_ARG.getValue(type)
            if (rest.none { it.startsWith(arg) && it.length > arg.length }) {
                return Problem.MissingArg(number, type, arg.removeSuffix("="))
            }
        }
        return null
    }

    /** "a.b.c.d:port", each part in range, no leading '+' or spaces. */
    fun isIpv4WithPort(text: String): Boolean {
        val host = text.substringBeforeLast(':', "")
        val port = text.substringAfterLast(':', "")
        if (host.isEmpty() || port.isEmpty() || port.length > 5 || !port.all { it.isDigit() }) return false
        if (port.toInt() !in 1..65535) return false
        val parts = host.split('.')
        return parts.size == 4 && parts.all { p ->
            p.isNotEmpty() && p.length <= 3 && p.all { it.isDigit() } && p.toInt() <= 255
        }
    }
}
