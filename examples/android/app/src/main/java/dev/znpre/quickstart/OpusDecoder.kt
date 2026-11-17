package dev.znpre.quickstart

import android.media.MediaCodec
import android.media.MediaFormat
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes the badge's Opus packets (16 kHz mono, 20 ms) with Android's built-in
 * decoder and returns 16 kHz mono 16-bit PCM. Android's Opus decoder usually
 * outputs 48 kHz, so the result is brought back down to 16 kHz.
 */
class OpusDecoder {
    private val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
    private var outputRate = 48_000
    private var outputChannels = 1
    private var timeUs = 0L

    init {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, SAMPLE_RATE, 1)
        // csd-0: the OpusHead header (RFC 7845), mono, no pre-skip.
        val head = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("OpusHead".toByteArray()); put(1); put(1); putShort(0); putInt(SAMPLE_RATE); putShort(0); put(0)
            flip()
        }
        format.setByteBuffer("csd-0", head)
        format.setByteBuffer("csd-1", nanos(0))           // codec delay
        format.setByteBuffer("csd-2", nanos(80_000_000))  // seek pre-roll
        codec.configure(format, null, null, 0)
        codec.start()
    }

    /** One Opus packet in, 16 kHz PCM out (may be empty while the decoder warms up). */
    fun decode(packet: ByteArray): ShortArray {
        val input = codec.dequeueInputBuffer(10_000)
        if (input >= 0) {
            codec.getInputBuffer(input)!!.apply { clear(); put(packet) }
            codec.queueInputBuffer(input, 0, packet.size, timeUs, 0)
            timeUs += 20_000
        }
        val pcm = ArrayList<Short>()
        val info = MediaCodec.BufferInfo()
        while (true) {
            val output = codec.dequeueOutputBuffer(info, 0)
            when {
                output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    outputRate = codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                    outputChannels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                }
                output >= 0 -> {
                    val samples = codec.getOutputBuffer(output)!!.order(ByteOrder.nativeOrder()).asShortBuffer()
                    val step = outputChannels * maxOf(1, outputRate / SAMPLE_RATE)
                    for (i in 0 until info.size / 2 step step) pcm += samples.get(i)
                    codec.releaseOutputBuffer(output, false)
                }
                else -> return pcm.toShortArray()
            }
        }
    }

    fun release() {
        codec.stop()
        codec.release()
    }

    private fun nanos(value: Long): ByteBuffer =
        ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).apply { putLong(value); flip() }

    companion object {
        const val SAMPLE_RATE = 16_000
    }
}
