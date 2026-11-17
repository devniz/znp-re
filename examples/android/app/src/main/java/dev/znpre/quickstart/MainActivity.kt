package dev.znpre.quickstart

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.media.AudioFormat
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import java.io.OutputStream
import java.util.concurrent.Executors

/**
 * The whole assistant loop:
 *
 *     button ─▶ badge mic ─▶ speech to text ─▶ Claude ─▶ badge screen + badge speaker
 *
 * Change PERSONA to give it a personality, or the model in Claude.kt.
 */
class MainActivity : Activity(), Z01Link.Events {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private lateinit var badge: Z01Link
    private lateinit var tts: TextToSpeech
    private lateinit var status: TextView
    private lateinit var transcript: TextView
    private lateinit var keyField: EditText

    private val history = mutableListOf<Claude.Turn>()
    private var recognizer: SpeechRecognizer? = null
    private var audioOut: OutputStream? = null
    private var decoder: OpusDecoder? = null
    private var micOpenedAt = 0L
    private var busy = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        status = TextView(this).apply { text = "Starting…" }
        keyField = EditText(this).apply {
            hint = "Anthropic API key"
            setText(prefs().getString("key", ""))
        }
        val save = Button(this).apply {
            text = "Save key"
            setOnClickListener { prefs().edit().putString("key", keyField.text.toString().trim()).apply() }
        }
        val talk = Button(this).apply { text = "Talk"; setOnClickListener { listen() } }
        transcript = TextView(this)
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 96, 48, 48)
            listOf(status, keyField, save, talk, transcript).forEach(::addView)
        })

        tts = TextToSpeech(this) {}
        badge = Z01Link(this, this)
        requestPermissions(arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT), 1)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, results: IntArray) {
        badge.start()
    }

    // region Badge events

    override fun onState(state: Z01Link.State) {
        status.text = when (state) {
            Z01Link.State.SEARCHING -> "Looking for your Z01…"
            Z01Link.State.CONNECTING -> "Connecting…"
            Z01Link.State.AUTHENTICATING -> "Unlocking the badge…"
            Z01Link.State.READY -> "Ready: press the badge button"
        }
    }

    override fun onBattery(percent: Int) {
        status.text = "Ready: press the badge button · battery $percent %"
    }

    override fun onButtonPressed() = listen()

    override fun onMicPackets(packets: List<ByteArray>) {
        val decoder = decoder ?: return
        val out = audioOut ?: return
        io.execute {
            for (packet in packets) {
                val pcm = decoder.decode(packet)
                val bytes = ByteArray(pcm.size * 2)
                pcm.forEachIndexed { i, s -> bytes[2 * i] = s.toByte(); bytes[2 * i + 1] = (s.toInt() shr 8).toByte() }
                runCatching { out.write(bytes) }
            }
        }
    }

    override fun onMicRefused() = stopAudio()

    override fun onSessionEnded() = stopAudio()

    // endregion

    // region Listening: badge mic → Android speech recognizer

    private fun listen() {
        if (busy || badge.state != Z01Link.State.READY) return
        busy = true
        tts.stop()
        transcript.text = "Listening…"

        // The recognizer reads 16 kHz PCM from a pipe that we fill with the badge's audio.
        val (readEnd, writeEnd) = ParcelFileDescriptor.createPipe()
        audioOut = ParcelFileDescriptor.AutoCloseOutputStream(writeEnd)
        decoder = OpusDecoder()
        recognizer = SpeechRecognizer.createSpeechRecognizer(this).apply {
            setRecognitionListener(recognition)
            startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE, readEnd)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
                putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, OpusDecoder.SAMPLE_RATE)
            })
        }
        micOpenedAt = System.currentTimeMillis()
        badge.startMic()
        badge.setScreen(Z01Link.Screen.LISTENING)
    }

    private val recognition = object : RecognitionListener {
        override fun onResults(results: Bundle) {
            val text = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
            finishListening(text)
        }

        override fun onError(error: Int) = finishListening("")
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onPartialResults(partialResults: Bundle?) {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun finishListening(question: String) {
        if (recognizer == null) return // already finishing
        recognizer?.destroy()
        recognizer = null
        // After a button press the badge wants its mic open 2 s or more, or it shows the stock app's QR code.
        val wait = maxOf(0L, 2_000 - (System.currentTimeMillis() - micOpenedAt))
        main.postDelayed({
            badge.stopMic()
            stopAudio()
            if (question.isBlank()) { busy = false; transcript.text = ""; return@postDelayed }
            answer(question)
        }, wait)
    }

    private fun stopAudio() {
        runCatching { audioOut?.close() }
        audioOut = null
        recognizer?.destroy()
        recognizer = null
        val d = decoder
        decoder = null
        io.execute { d?.release() }
    }

    // endregion

    // region Thinking: Claude → badge screen + speaker

    private fun answer(question: String) {
        transcript.text = "You: $question"
        badge.setScreen(Z01Link.Screen.THINKING)
        history += Claude.Turn(fromUser = true, text = question)
        val key = prefs().getString("key", "").orEmpty()
        var started = false
        io.execute {
            val reply = runCatching {
                Claude(key).reply(PERSONA, history.toList()) { piece ->
                    main.post {
                        if (!started) { started = true; badge.beginReply() }
                        badge.appendReply(piece)
                        transcript.append(if (transcript.text.contains("\nClaude: ")) piece else "\nClaude: $piece")
                    }
                }
            }
            main.post {
                busy = false
                val text = reply.getOrNull().orEmpty()
                if (text.isBlank()) {
                    history.removeAt(history.lastIndex)
                    badge.showText("Sorry, I couldn't answer that.")
                    transcript.append("\n" + (reply.exceptionOrNull()?.message ?: "No answer."))
                    return@post
                }
                history += Claude.Turn(fromUser = false, text = text)
                // Plays on the phone's audio output: pick "Z01" to hear it from the badge.
                tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "reply")
            }
        }
    }

    // endregion

    // Fine for your own phone. Use EncryptedSharedPreferences, or better your own server, in a real app.
    private fun prefs() = getSharedPreferences("quickstart", MODE_PRIVATE)

    override fun onDestroy() {
        stopAudio()
        tts.shutdown()
        super.onDestroy()
    }

    companion object {
        const val PERSONA = "You are a friendly voice assistant that lives in a small badge worn on the user's clothes. " +
            "Your words are shown on a tiny round screen and read aloud, so answer in one to three short sentences " +
            "of plain spoken text: no markdown, no lists, no emoji, no links."
    }
}
