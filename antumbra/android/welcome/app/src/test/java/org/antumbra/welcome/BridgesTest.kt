// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgesTest {
    private val obfs4 = "obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=AbC+/x iat-mode=0"
    private val webtunnel = "webtunnel [2001:db8::1]:443 0123456789ABCDEF0123456789ABCDEF01234567 url=https://example.org/x ver=0.0.1"
    private val meek = "meek_lite 192.0.2.18:80 0123456789ABCDEF0123456789ABCDEF01234567 url=https://cdn.example.net/ front=www.example.com"

    private fun ok(text: String) = (Bridges.parse(text) as Bridges.Result.Ok).lines
    private fun problem(text: String) = (Bridges.parse(text) as Bridges.Result.Error).problem

    @Test
    fun acceptsSupportedTransportsAndPlainBridges() {
        val plain = "192.0.2.7:9001 0123456789ABCDEF0123456789ABCDEF01234567"
        assertEquals(listOf(obfs4, webtunnel, meek, plain), ok("$obfs4\n$webtunnel\n$meek\n$plain"))
        assertEquals(listOf("192.0.2.7:9001"), ok("192.0.2.7:9001"))
    }

    @Test
    fun normalisesWhitespaceCommentsAndBridgePrefix() {
        val text = "  # from bridges.torproject.org\r\n\r\nBridge   $obfs4\t\r\n\n"
        assertEquals(listOf(obfs4), ok(text))
    }

    @Test
    fun refusesSnowflakeWithItsLineNumber() {
        assertEquals(Bridges.Problem.Snowflake(2), problem("$obfs4\nsnowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72"))
    }

    @Test
    fun refusesIpv6ForAddressedTransportsAndPlainBridges() {
        assertEquals(Bridges.Problem.Ipv6(1), problem("obfs4 [2001:db8::5]:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=x iat-mode=0"))
        assertEquals(Bridges.Problem.Ipv6(1), problem("[2001:db8::5]:443"))
        assertEquals(Bridges.Problem.Ipv6(1), problem("2001:db8::5"))
    }

    @Test
    fun refusesUnknownTransportsAndObsoleteOnes() {
        assertEquals(Bridges.Problem.UnknownType(1, "obfs3"), problem("obfs3 192.0.2.1:443"))
        assertEquals(Bridges.Problem.UnknownType(1, "scramblesuit"), problem("scramblesuit 192.0.2.1:443"))
    }

    @Test
    fun refusesCharactersThatCouldBreakTheControlPortQuoting() {
        assertEquals(Bridges.Problem.Characters(1), problem("$obfs4\"\r\nSETCONF DisableNetwork=0"))
        assertEquals(Bridges.Problem.Characters(1), problem("$obfs4 \\"))
        assertEquals(Bridges.Problem.Characters(1), problem("obfs4 192.0.2.1:443 é"))
        assertEquals(Bridges.Problem.Characters(1), problem("obfs4 192.0.2.1:443\u0000"))
    }

    @Test
    fun checksAddressesFingerprintsAndRequiredArguments() {
        assertEquals(Bridges.Problem.Address(1, "192.0.2.1"), problem("obfs4 192.0.2.1 cert=x"))
        assertEquals(Bridges.Problem.Address(1, "192.0.2.300:443"), problem("192.0.2.300:443"))
        assertEquals(Bridges.Problem.Address(1, "192.0.2.1:0"), problem("192.0.2.1:0"))
        assertEquals(Bridges.Problem.Address(1, ""), problem("obfs4"))
        assertEquals(Bridges.Problem.Fingerprint(1), problem("obfs4 192.0.2.1:443 ABCD cert=x iat-mode=0"))
        assertEquals(
            Bridges.Problem.MissingArg(1, "obfs4", "cert"),
            problem("obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 iat-mode=0"),
        )
        assertEquals(
            Bridges.Problem.MissingArg(1, "webtunnel", "url"),
            problem("webtunnel [2001:db8::1]:443 0123456789ABCDEF0123456789ABCDEF01234567 url="),
        )
    }

    @Test
    fun refusesEmptyInputTooManyAndTooLongLines() {
        assertEquals(Bridges.Problem.None(), problem(" \n# only a comment\n"))
        val many = (1..Bridges.MAX_BRIDGES + 1).joinToString("\n") { "192.0.2.${it}:443" }
        assertEquals(Bridges.Problem.TooMany(Bridges.MAX_BRIDGES), problem(many))
        assertEquals(Bridges.Problem.TooLong(1), problem("$obfs4 " + "x".repeat(Bridges.MAX_LINE_LENGTH)))
    }

    @Test
    fun ipv4WithPort() {
        assertTrue(Bridges.isIpv4WithPort("255.255.255.255:65535"))
        listOf("1.2.3:4", "1.2.3.4", "1.2.3.4:", "01234.1.1.1:1", "1.2.3.4:65536", "a.b.c.d:1", "1.2.3.4:+1").forEach {
            assertTrue(it, !Bridges.isIpv4WithPort(it))
        }
    }

    /** The shipped built-in bridges must pass the same checks as typed ones. */
    @Test
    fun builtInAssetParses() {
        val asset = File("src/main/assets/" + WelcomeActivity.BUILTIN_ASSET)
        val lines = ok(asset.readText())
        assertTrue("expected several built-in bridges, got ${lines.size}", lines.size >= 3)
        assertTrue(lines.all { it.startsWith("obfs4 ") })
    }
}
