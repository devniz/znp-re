package dev.znpre.quickstart

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.Calendar
import java.util.UUID

/**
 * The ZNP Z01 over BLE: connect, unlock, button, mic, screens and text.
 * Everything runs and calls back on the main thread. Needs BLUETOOTH_SCAN and
 * BLUETOOTH_CONNECT granted before `start()`. Android 13+ (API 33).
 *
 * The badge speaker isn't here: it's a normal Bluetooth audio device named
 * "Z01". Pair it in Android's Bluetooth settings and pick it as the output.
 */
@SuppressLint("MissingPermission")
class Z01Link(private val context: Context, private val events: Events) {

    interface Events {
        fun onState(state: State) {}
        fun onBattery(percent: Int) {}
        /** The side button. The badge now waits for the mic: open it with `startMic()`. */
        fun onButtonPressed() {}
        fun onSessionEnded() {}
        fun onMicOpened() {}
        fun onMicRefused() {}
        /** Opus packets, 16 kHz mono, 20 ms each (see OpusDecoder). */
        fun onMicPackets(packets: List<ByteArray>) {}
    }

    enum class State { SEARCHING, CONNECTING, AUTHENTICATING, READY }

    enum class Screen(val code: Int) { REPLYING(0x02), LISTENING(0x03), THINKING(0x04) }

    var state = State.SEARCHING
        private set(value) {
            if (field != value) { field = value; events.onState(value) }
        }
    var isMicOpen = false
        private set

    private val main = Handler(Looper.getMainLooper())
    private val adapter = context.getSystemService(BluetoothManager::class.java).adapter
    private var gatt: BluetoothGatt? = null
    private var device: BluetoothDevice? = null
    private var writeSize = 20
    private var auth: JieLiAuth? = null
    private var sn = 0
    private var micSn: Int? = null

    /** Android runs one GATT operation at a time: each entry starts one, the callback starts the next. */
    private val ops = ArrayDeque<(BluetoothGatt) -> Boolean>()
    private var opRunning = false

    private val textFrames = ArrayDeque<ByteArray>()
    private var cleaner = ScreenText.Cleaner()
    private var sendingText = false
    private var textGeneration = 0
    private var lastTextAt = 0L

    // region Public API

    fun start() {
        state = State.SEARCHING
        adapter.bluetoothLeScanner?.startScan(scan)
    }

    fun setScreen(screen: Screen) {
        clearText()
        send(0xFF, byteArrayOf(0xFF.toByte(), 0xF7.toByte(), 0xF1.toByte(), screen.code.toByte()), RcspFrame.COMMAND_NO_REPLY)
    }

    /** Leaves the session screen and closes the mic. */
    fun endSession() {
        clearText()
        isMicOpen = false
        micSn = null
        send(0x05, byteArrayOf(0x00))
    }

    /** After a button press, keep the mic open at least 2 s, or the badge shows the stock app's QR code. */
    fun startMic() {
        if (state != State.READY || isMicOpen) return
        isMicOpen = true
        micSn = send(0x04, byteArrayOf(0x02, 0x10, 0x00))
    }

    fun stopMic() {
        if (isMicOpen) endSession()
    }

    fun showText(text: String) {
        beginReply()
        appendReply(text)
    }

    /** Switches to the replying screen, ready for `appendReply`. */
    fun beginReply() {
        setScreen(Screen.REPLYING)
        cleaner = ScreenText.Cleaner()
    }

    /** Adds a streamed piece of text to the screen. */
    fun appendReply(piece: String) {
        if (state != State.READY) return
        textFrames.addAll(ScreenText.frames(cleaner.feed(piece)))
        if (!sendingText) {
            sendingText = true
            sendNextText()
        }
    }

    fun refreshBattery() {
        send(0x03, byteArrayOf(-1, -1, -1, -1))
    }

    // endregion

    // region Text pacing: ~120 ms between frames, or 350 ms without an ack

    private fun clearText() {
        textFrames.clear()
        sendingText = false
        textGeneration++
    }

    private fun sendNextText() {
        val frame = textFrames.removeFirstOrNull()
        if (!sendingText || frame == null) { sendingText = false; return }
        write(frame, TEXT_WRITE)
        lastTextAt = System.currentTimeMillis()
        scheduleNextText(350)
    }

    private fun scheduleNextText(delayMs: Long) {
        val generation = ++textGeneration
        main.postDelayed({ if (textGeneration == generation) sendNextText() }, delayMs)
    }

    private fun textAcked() {
        if (sendingText) scheduleNextText(maxOf(0L, 120 - (System.currentTimeMillis() - lastTextAt)))
    }

    // endregion

    // region Writing

    /** Sends an RCSP command, returns its sequence number. */
    private fun send(opcode: Int, data: ByteArray, flag: Int = RcspFrame.COMMAND): Int {
        if (state != State.READY) return 0
        sn = (sn + 1) and 0xFF
        write(RcspFrame(flag, opcode, byteArrayOf(sn.toByte()) + data).encode(), RCSP_WRITE)
        return sn
    }

    /** Queues one frame, cut to the write size. The badge joins the pieces. */
    private fun write(data: ByteArray, uuid: UUID) {
        val c = characteristic(uuid) ?: return
        val type = if (c.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0)
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE else BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        for (start in data.indices step writeSize) {
            val piece = data.copyOfRange(start, minOf(data.size, start + writeSize))
            enqueue { it.writeCharacteristic(c, piece, type) == BluetoothStatusCodes.SUCCESS }
        }
    }

    private fun enqueue(op: (BluetoothGatt) -> Boolean) {
        ops.addLast(op)
        runNext()
    }

    private fun runNext() {
        val g = gatt ?: return
        while (!opRunning) {
            val op = ops.removeFirstOrNull() ?: return
            opRunning = op(g) // an op that failed to start is skipped
        }
    }

    private fun opDone() {
        opRunning = false
        runNext()
    }

    private fun characteristic(uuid: UUID): BluetoothGattCharacteristic? =
        gatt?.services?.firstNotNullOfOrNull { it.getCharacteristic(uuid) }

    private fun enableNotifications(uuid: UUID) {
        val c = characteristic(uuid) ?: return
        enqueue { g ->
            g.setCharacteristicNotification(c, true)
            val cccd = c.getDescriptor(CCCD) ?: return@enqueue false
            g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
        }
    }

    // endregion

    // region Connection

    private val scan = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val name = result.device.name ?: result.scanRecord?.deviceName ?: return
            if (!name.startsWith("Z01") || device != null) return
            adapter.bluetoothLeScanner?.stopScan(this)
            device = result.device
            connect(autoConnect = false)
        }
    }

    private fun connect(autoConnect: Boolean) {
        state = State.CONNECTING
        // TRANSPORT_LE: the badge is dual-mode, and the classic side is its speaker.
        gatt = device?.connectGatt(context, autoConnect, callback, BluetoothDevice.TRANSPORT_LE)
    }

    private fun authenticated() {
        state = State.READY
        val c = Calendar.getInstance()
        val year = c.get(Calendar.YEAR)
        send(0x08, byteArrayOf(0x02, 0x08, 0x00, (year shr 8).toByte(), year.toByte(),
            (c.get(Calendar.MONTH) + 1).toByte(), c.get(Calendar.DAY_OF_MONTH).toByte(),
            c.get(Calendar.HOUR_OF_DAY).toByte(), c.get(Calendar.MINUTE).toByte(), c.get(Calendar.SECOND).toByte()))
        refreshBattery()
    }

    private fun linkLost() {
        auth = null
        ops.clear()
        opRunning = false
        clearText()
        micSn = null
        if (isMicOpen) { isMicOpen = false; events.onMicRefused() }
    }

    /** GATT callbacks arrive on a binder thread: hop to the main thread for everything. */
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            main.post {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    state = State.AUTHENTICATING
                    g.requestMtu(247)
                    // A stuck handshake (another app holds the badge, say): drop and retry.
                    main.postDelayed({ if (gatt === g && state == State.AUTHENTICATING) g.disconnect() }, 10_000)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    linkLost()
                    g.close()
                    if (gatt === g) connect(autoConnect = true) // comes back by itself when in range
                }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            main.post {
                writeSize = maxOf(20, mtu - 3)
                g.discoverServices()
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            main.post {
                enableNotifications(TEXT_NOTIFY)
                enableNotifications(RCSP_NOTIFY)
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            main.post {
                opDone()
                if (d.characteristic.uuid == RCSP_NOTIFY) {
                    val a = JieLiAuth(send = { write(it, RCSP_WRITE) }, onDone = { authenticated() })
                    auth = a
                    main.postDelayed({ a.start() }, 500)
                }
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            main.post { opDone() }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            main.post { received(c.uuid, value) }
        }
    }

    // endregion

    // region Incoming

    private fun received(uuid: UUID, value: ByteArray) {
        if (uuid == TEXT_NOTIFY) {
            if (value.contentEquals(ScreenText.ACK)) textAcked()
            return
        }
        if (uuid != RCSP_NOTIFY) return
        val frame = RcspFrame.parse(value) ?: run { auth?.handle(value); return }
        val data = frame.data
        when {
            frame.isCommand && frame.opcode == 0x01 && (data.firstOrNull()?.u() ?: 0) > 0 -> {
                if (isMicOpen) events.onMicPackets(splitPackets(data))
            }
            !frame.isCommand && frame.opcode == 0x04 && micSn != null && frame.sn == micSn -> {
                micSn = null
                if (frame.status == 0) events.onMicOpened() else { isMicOpen = false; events.onMicRefused() }
            }
            frame.isCommand && frame.opcode == 0xFF && data.contentEquals(BUTTON) -> events.onButtonPressed()
            frame.isCommand && frame.opcode == 0xFF && data.contentEquals(SESSION_ENDED) -> {
                isMicOpen = false
                events.onSessionEnded()
            }
            !frame.isCommand && frame.opcode == 0x03 && frame.status == 0 -> battery(data)?.let(events::onBattery)
        }
    }

    /** `count`, then `count` equal-size Opus packets. */
    private fun splitPackets(data: ByteArray): List<ByteArray> {
        val n = data[0].u()
        val size = (data.size - 1) / n
        if (size == 0) return emptyList()
        return (0 until n).map { data.copyOfRange(1 + it * size, 1 + (it + 1) * size) }
    }

    /** GetTargetInfo TLVs `len type value[len-1]`; type 01 starts with the battery %. */
    private fun battery(b: ByteArray): Int? {
        var i = 0
        while (i + 1 < b.size) {
            val len = b[i].u()
            if (len == 0 || i + len >= b.size) return null
            if (b[i + 1].u() == 0x01 && len >= 2) return b[i + 2].u()
            i += len + 1
        }
        return null
    }

    // endregion

    companion object {
        private fun uuid(short: String) = UUID.fromString("0000$short-0000-1000-8000-00805f9b34fb")
        val RCSP_WRITE: UUID = uuid("ae01")
        val RCSP_NOTIFY: UUID = uuid("ae02")
        val TEXT_WRITE: UUID = uuid("df98")
        val TEXT_NOTIFY: UUID = uuid("df99")
        val CCCD: UUID = uuid("2902")
        private val BUTTON = byteArrayOf(0xFF.toByte(), 0xF7.toByte(), 0xF1.toByte(), 0x00)
        private val SESSION_ENDED = byteArrayOf(0xFF.toByte(), 0xF7.toByte(), 0xF1.toByte(), 0x01)
    }
}
