package dev.znpre.quickstart

import java.text.BreakIterator
import kotlin.random.Random

/**
 * A JieLi RCSP frame on AE01 / AE02 (docs/PROTOCOL.md §5):
 *
 *     FE DC BA | flag | opcode | len (2, BE) | params[len] | EF
 *
 * Command params start with `sn`, response params with `status, sn`.
 */
class RcspFrame(val flag: Int, val opcode: Int, val params: ByteArray) {
    val isCommand get() = flag and 0x80 != 0
    val sn: Int? get() = if (isCommand) params.firstOrNull()?.u() else params.getOrNull(1)?.u()
    val status: Int? get() = if (isCommand) null else params.firstOrNull()?.u()
    val data: ByteArray get() = params.copyOfRange(minOf(params.size, if (isCommand) 1 else 2), params.size)

    fun encode(): ByteArray = byteArrayOf(
        0xFE.toByte(), 0xDC.toByte(), 0xBA.toByte(), flag.toByte(), opcode.toByte(),
        (params.size shr 8).toByte(), params.size.toByte(),
    ) + params + byteArrayOf(0xEF.toByte())

    companion object {
        const val COMMAND = 0xC0          // wants an answer
        const val COMMAND_NO_REPLY = 0x80 // screen switches, bulk data

        /** Null if `b` isn't one whole frame (auth messages aren't). */
        fun parse(b: ByteArray): RcspFrame? {
            if (b.size < 8 || b[0] != 0xFE.toByte() || b[1] != 0xDC.toByte() || b[2] != 0xBA.toByte()) return null
            if (b.last() != 0xEF.toByte()) return null
            val len = b[5].u() shl 8 or b[6].u()
            if (b.size != 8 + len) return null
            return RcspFrame(b[3].u(), b[4].u(), b.copyOfRange(7, 7 + len))
        }
    }
}

fun Byte.u() = toInt() and 0xFF

/**
 * JieLi's challenge-response (docs/PROTOCOL.md §4). We don't know the secret
 * function, so we send the badge's own challenge back to it and use its answer.
 */
class JieLiAuth(private val send: (ByteArray) -> Unit, private val onDone: () -> Unit) {
    private enum class State { IDLE, CHALLENGED, PASSED, REFLECTING, RESPONDED, DONE }

    private var state = State.IDLE

    fun start() {
        state = State.CHALLENGED
        send(byteArrayOf(0x00) + Random.nextBytes(16))
    }

    /** Feed every AE02 notification that isn't an RCSP frame. */
    fun handle(data: ByteArray) {
        when {
            data.isEmpty() -> return
            data[0] == 0x01.toByte() && state == State.CHALLENGED -> {
                state = State.PASSED
                send(PASS)
            }
            data[0] == 0x01.toByte() && state == State.REFLECTING -> {
                state = State.RESPONDED
                send(data) // the badge scrambled its own challenge: that's our answer
            }
            data[0] == 0x00.toByte() -> {
                state = State.REFLECTING
                send(data) // send the badge's challenge straight back to it
            }
            data.contentEquals(PASS) && (state == State.PASSED || state == State.RESPONDED) -> {
                state = State.DONE
                onDone()
            }
        }
    }

    companion object {
        val PASS = byteArrayOf(0x02) + "pass".toByteArray()
    }
}

/** Screen text on DF98 (docs/PROTOCOL.md §9): 2 characters per frame, acked on DF99. */
object ScreenText {
    val ACK = byteArrayOf(0x88.toByte(), 0x88.toByte(), 0x11, 0x02, 0x01, 0x00)

    fun frame(text: String): ByteArray {
        val bytes = text.toByteArray().take(250).toByteArray()
        val n = bytes.size
        return byteArrayOf(0x88.toByte(), 0x88.toByte(), 0x11, 0x01, (n + 5).toByte(), 0x00, n.toByte(), 0x00, 0x00, n.toByte()) + bytes
    }

    /** Cuts clean text into frames, never inside a character. */
    fun frames(text: String): List<ByteArray> {
        val characters = ArrayList<String>()
        val it = BreakIterator.getCharacterInstance().apply { setText(text) }
        var start = it.first()
        var end = it.next()
        while (end != BreakIterator.DONE) {
            characters += text.substring(start, end)
            start = end
            end = it.next()
        }
        return characters.chunked(2).map { frame(it.joinToString("")) }
    }

    /** One flowing line, no markdown, plain punctuation, no emoji. Keeps spaces across pieces. */
    class Cleaner {
        private var pendingSpace = false
        private var started = false

        fun feed(piece: String): String {
            val out = StringBuilder()
            var i = 0
            while (i < piece.length) {
                val cp = piece.codePointAt(i)
                i += Character.charCount(cp)
                if (Character.isWhitespace(cp)) {
                    pendingSpace = started
                    continue
                }
                val safe = safe(cp) ?: continue
                if (pendingSpace) out.append(' ')
                pendingSpace = false
                started = true
                out.append(safe)
            }
            return out.toString()
        }

        private fun safe(cp: Int): String? = when (cp) {
            '*'.code, '_'.code, '`'.code, '#'.code -> null
            0x2018, 0x2019, 0x201B, 0x2032 -> "'"
            0x201C, 0x201D, 0x201E, 0x00AB, 0x00BB -> "\""
            0x2013, 0x2014, 0x2212, 0x2022, 0x00B7 -> "-"
            0x2026 -> "..."
            0x200D, 0xFE0F -> null
            in 0x2190..0x2BFF, in 0x1F000..0x1FFFF -> null // arrows, symbols, emoji
            else -> String(Character.toChars(cp))
        }
    }
}
