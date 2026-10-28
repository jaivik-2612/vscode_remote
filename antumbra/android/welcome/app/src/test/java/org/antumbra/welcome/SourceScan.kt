// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.io.File

/** Welcome's own sources and texts, for the tests that scan them. */
object SourceScan {
    val MAIN = File("src/main/java/org/antumbra/welcome")

    /** Every Kotlin and Java source under src/main/java. */
    fun sources(): List<File> =
        File("src/main/java").walkTopDown().filter { it.isFile && it.extension in setOf("kt", "java") }.toList()

    /** One main source's code, comments taken out. */
    fun code(name: String): String = withoutComments(File(MAIN, name).readText())

    /** The code without its comments (strings kept; "//" in a string is not a comment). */
    fun withoutComments(src: String): String {
        val out = StringBuilder(src.length)
        var i = 0
        var depth = 0
        var inString = false
        var raw = false
        while (i < src.length) {
            val c = src[i]
            val next = if (i + 1 < src.length) src[i + 1] else ' '
            when {
                depth > 0 -> {
                    if (c == '*' && next == '/') { depth--; i += 2; out.append("  "); continue }
                    if (c == '/' && next == '*') { depth++; i += 2; out.append("  "); continue }
                    out.append(if (c == '\n') '\n' else ' ')
                }
                inString && raw -> {
                    if (src.startsWith("\"\"\"", i)) { inString = false; out.append("\"\"\""); i += 3; continue }
                    out.append(c)
                }
                inString -> {
                    if (c == '\\' && i + 1 < src.length) { out.append(c).append(next); i += 2; continue }
                    if (c == '"' || c == '\n') inString = false
                    out.append(c)
                }
                c == '/' && next == '/' -> {
                    while (i < src.length && src[i] != '\n') { out.append(' '); i++ }
                    continue
                }
                c == '/' && next == '*' -> { depth = 1; i += 2; out.append("  "); continue }
                src.startsWith("\"\"\"", i) -> { inString = true; raw = true; out.append("\"\"\""); i += 3; continue }
                c == '"' -> { inString = true; raw = false; out.append(c) }
                c == '\'' && i + 2 < src.length && (src[i + 2] == '\'' || (next == '\\' && i + 3 < src.length && src[i + 3] == '\'')) -> {
                    // A char literal such as '"' or '\'' is not the start of a string.
                    val len = if (next == '\\') 4 else 3
                    out.append(src, i, i + len)
                    i += len
                    continue
                }
                else -> out.append(c)
            }
            i++
        }
        return out.toString()
    }

    /** The string literals of some code (without comments), their contents as written. */
    fun literals(code: String): List<String> =
        Regex("\"((?:[^\"\\\\\\n]|\\\\.)*)\"").findAll(code).map { it.groupValues[1] }.toList()

    /** A function in [code], from `fun SIGNATURE` (its name and the start of its parameters) to the next `fun`. */
    fun function(code: String, signature: String): String {
        val start = code.indexOf("fun $signature")
        require(start >= 0) { "no fun $signature" }
        val next = Regex("\\n\\s*(?:@\\w+(?:\\([^)]*\\))?\\s*)*(?:override |private |internal )?fun ").find(code, start + 1)
        return code.substring(start, next?.range?.first ?: code.length)
    }
}

/** strings.xml's texts by resource name, and R's ids back to names. */
object StringsXml {
    val xml: String = File("src/main/res/values/strings.xml").readText()

    val texts: Map<String, List<String>> = run {
        val m = HashMap<String, List<String>>()
        Regex("""<string name="([a-z0-9_]+)">([^<]*)</string>""").findAll(xml).forEach {
            m[it.groupValues[1]] = listOf(unescape(it.groupValues[2]))
        }
        Regex("""<plurals name="([a-z0-9_]+)">(.*?)</plurals>""", RegexOption.DOT_MATCHES_ALL).findAll(xml).forEach { p ->
            m[p.groupValues[1]] = Regex("""<item quantity="[a-z]+">([^<]*)</item>""").findAll(p.groupValues[2])
                .map { unescape(it.groupValues[1]) }.toList()
        }
        m
    }

    private fun unescape(s: String) = s.replace("\\'", "'").replace("\\\"", "\"")

    val names: Map<Int, String> = (R.string::class.java.fields + R.plurals::class.java.fields)
        .associate { it.getInt(null) to it.name }

    fun name(id: Int): String = names[id] ?: error("no resource $id")

    /** The text of a string resource (the first item of a plurals). */
    fun text(id: Int): String = texts[name(id)]?.first() ?: error("no text for ${name(id)}")

    fun of(name: String): String = texts[name]?.single() ?: error("no string $name")
}
