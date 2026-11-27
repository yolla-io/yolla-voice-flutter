//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//

package com.yollacalls.flutter.voice

import com.yollacalls.android.voice.Call
import com.yollacalls.android.voice.CallStats
import com.yollacalls.android.voice.VoiceError
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest

private fun token(to: String? = "+4915112345678"): String {
    val claims = if (to == null) """{"jti":"call_1"}""" else """{"jti":"call_1","to":"$to","cli":"anonymous"}"""
    val payload = Base64.getUrlEncoder().withoutPadding().encodeToString(claims.toByteArray())
    return "e30.$payload.sig"
}

private class FakeVoice : VoiceConnecting {
    override val call = MutableStateFlow<Call?>(null)
    val commands = mutableListOf<String>()
    var connectError: VoiceError? = null
    var holdError: VoiceError? = null

    fun snapshot(change: Call.Builder.() -> Unit) {
        call.value = (call.value ?: Call { callID = "call_1"; to = "+4915112345678" }).toBuilder().apply(change).build()
    }

    override fun connect(callToken: String) {
        connectError?.let { throw it }
        commands += "connect"
        call.value = Call { callID = "call_1"; to = "+4915112345678"; state = Call.State.Connecting }
    }

    override fun hangup() {
        commands += "hangup"
    }

    override suspend fun setMuted(muted: Boolean) {
        commands += "mute $muted"
        snapshot { isMuted = muted }
    }

    override suspend fun setOnHold(hold: Boolean) {
        holdError?.let { throw it }
        commands += "hold $hold"
        snapshot { isOnHold = hold }
    }

    override suspend fun sendDigits(digits: String) {
        commands += "digits $digits"
    }

    override suspend fun stats(): CallStats? = null
}

private class FakeTelecomSession : TelecomSession {
    val reports = mutableListOf<String>()
    var allowsHold = true
    override val routes = MutableStateFlow(listOf(AudioRoute("e", AudioRoute.Kind.Earpiece, "Phone"), AudioRoute("s", AudioRoute.Kind.Speaker, "Speaker")))
    override val current = MutableStateFlow<AudioRoute?>(routes.value.first())

    override suspend fun setHeld(held: Boolean): Boolean {
        reports += "held $held"
        return allowsHold
    }

    override suspend fun reportConnected() {
        reports += "connected"
    }

    override suspend fun reportEnded(cause: TelecomEndCause) {
        reports += "ended $cause"
    }

    override suspend fun select(route: AudioRoute) {
        current.value = route
    }
}

private class FakeTelecom : TelecomStarting {
    val session = FakeTelecomSession()
    var refuses = false
    var gate: CompletableDeferred<Unit>? = null
    var events: TelecomCallEvents? = null

    override suspend fun startCall(number: String, events: TelecomCallEvents): TelecomSession {
        gate?.await()
        if (refuses) throw TelecomStartException("Telecom refused the call (code 1)")
        this.events = events
        return session
    }
}

private class FakeService : CallServiceControlling {
    val log = mutableListOf<String>()
    override fun start(number: String, microphoneGranted: Boolean, telecom: Boolean) {
        log += "start $number"
    }

    override fun stop() {
        log += "stop"
    }
}

private class FakeDirect : DirectAudioRouting {
    override val routes = MutableStateFlow(listOf(AudioRoute("speaker", AudioRoute.Kind.Speaker, "Speaker")))
    override val current = MutableStateFlow<AudioRoute?>(null)
    var resets = 0
    override suspend fun select(route: AudioRoute) {
        current.value = route
    }

    override fun reset() {
        resets++
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class VoiceRuntimeTests {
    private val voice = FakeVoice()
    private val telecom = FakeTelecom()
    private val service = FakeService()
    private val direct = FakeDirect()
    private val proximity = mutableListOf<Boolean>()
    private var granted = CallPermissions(microphone = true, notifications = true, bluetooth = true)

    private fun TestScope.runtime() = VoiceRuntime(
        voice = { voice },
        telecom = telecom,
        service = service,
        directRouting = direct,
        proximity = { active, _ -> proximity += active },
        scope = CoroutineScope(UnconfinedTestDispatcher(testScheduler)),
        log = {},
        currentPermissions = { granted },
    )

    private suspend fun refusal(block: suspend () -> Unit): String = assertFailsWith<VoiceError> { block() }.code

    @Test
    fun `a call starts the service and Telecom, then the SDK`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        assertEquals(listOf("start +4915112345678"), service.log)
        assertEquals(listOf("connect"), voice.commands)
        assertEquals(Call.State.Connecting, runtime.call.value?.call?.state)
        assertEquals(2, runtime.routes.value.routes.size)
        assertEquals(AudioRoute.Kind.Earpiece, runtime.routes.value.current?.kind)
        assertTrue(proximity.last())
    }

    @Test
    fun `a token without a destination is refused before anything starts`() = runTest {
        val runtime = runtime()
        assertEquals("invalid_token", refusal { runtime.connect(token(to = null)) })
        assertEquals("invalid_token", refusal { runtime.connect("not a token") })
        assertTrue(service.log.isEmpty())
        assertNull(runtime.call.value)
    }

    @Test
    fun `no microphone, no call`() = runTest {
        granted = granted.copy(microphone = false)
        val runtime = runtime()
        assertEquals("microphone_denied", refusal { runtime.connect(token()) })
        assertTrue(service.log.isEmpty())
        assertTrue(voice.commands.isEmpty())
    }

    @Test
    fun `the permissions are asked from the screen when there is one`() = runTest {
        granted = granted.copy(microphone = false)
        val runtime = runtime()
        runtime.permissions = PermissionRequesting { granted.copy(microphone = true) }
        runtime.connect(token())
        assertEquals(listOf("connect"), voice.commands)
    }

    @Test
    fun `one call at a time`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        assertEquals("call_in_progress", refusal { runtime.connect(token()) })
    }

    @Test
    fun `the answer is reported to Telecom once, the end after the end tone`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        voice.snapshot { state = Call.State.Connected; wasConnected = true }
        voice.snapshot { state = Call.State.Reconnecting }
        voice.snapshot { state = Call.State.Connected }
        assertEquals(listOf("connected"), telecom.session.reports)

        voice.snapshot { state = Call.State.Disconnected; endReason = Call.EndReason.RemoteHangup }
        assertEquals(Call.State.Disconnected, runtime.call.value?.call?.state)
        assertEquals(listOf("connected"), telecom.session.reports)
        advanceTimeBy(VoiceRuntime.END_TONE_DELAY.inWholeMilliseconds + 1)
        assertEquals(listOf("connected", "ended Remote"), telecom.session.reports)
        assertEquals("stop", service.log.last())
        assertTrue(runtime.routes.value.routes.isEmpty())
        assertFalse(proximity.last())
        // The ended call stays until the next one.
        assertEquals(Call.EndReason.RemoteHangup, runtime.call.value?.call?.endReason)
    }

    @Test
    fun `the next call waits for the previous one to be released`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        voice.snapshot { state = Call.State.Disconnected; endReason = Call.EndReason.Busy }
        runtime.connect(token())
        assertEquals(listOf("start +4915112345678", "stop", "start +4915112345678"), service.log)
        assertEquals(listOf("ended Rejected"), telecom.session.reports)
        assertEquals(Call.State.Connecting, runtime.call.value?.call?.state)
    }

    @Test
    fun `without Telecom the call goes on with the direct audio routes`() = runTest {
        telecom.refuses = true
        val runtime = runtime()
        runtime.connect(token())
        assertEquals(listOf("connect"), voice.commands)
        assertEquals(listOf("speaker"), runtime.routes.value.routes.map { it.id })
        voice.snapshot { state = Call.State.Disconnected; endReason = Call.EndReason.LocalHangup }
        advanceUntilIdle()
        assertEquals(1, direct.resets)
        assertEquals("stop", service.log.last())
    }

    @Test
    fun `a hang-up while Telecom is starting dials nothing`() = runTest {
        telecom.gate = CompletableDeferred()
        val runtime = runtime()
        var code: String? = null
        val connecting = launch(UnconfinedTestDispatcher(testScheduler)) { code = refusal { runtime.connect(token()) } }
        runtime.hangup()
        telecom.gate!!.complete(Unit)
        connecting.join()
        assertEquals("cancelled", code)
        assertTrue(voice.commands.isEmpty())
        assertEquals(listOf("ended Local"), telecom.session.reports)
        assertEquals("stop", service.log.last())
        // The client is free again.
        runtime.connect(token())
    }

    @Test
    fun `a call the SDK refuses is taken down again`() = runTest {
        voice.connectError = VoiceError("invalid_token", "expired")
        val runtime = runtime()
        assertEquals("invalid_token", refusal { runtime.connect(token()) })
        assertEquals(listOf("ended Error"), telecom.session.reports)
        assertEquals("stop", service.log.last())
        assertNull(runtime.call.value)
    }

    @Test
    fun `commands need a call`() = runTest {
        val runtime = runtime()
        assertEquals("invalid_call_state", refusal { runtime.setMuted(true) })
        assertEquals("invalid_call_state", refusal { runtime.setOnHold(true) })
        assertEquals("invalid_call_state", refusal { runtime.sendDigits("1") })
        assertEquals("invalid_call_state", refusal { runtime.selectRoute("s") })
        runtime.hangup()
        assertNull(runtime.stats())
    }

    @Test
    fun `mute, digits, routes and hang-up go to the call`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        runtime.setMuted(true)
        runtime.sendDigits("5")
        runtime.selectRoute("s")
        runtime.hangup()
        assertEquals(listOf("connect", "mute true", "digits 5", "hangup"), voice.commands)
        assertTrue(runtime.call.value!!.call.isMuted)
        assertEquals("s", runtime.routes.value.current?.id)
    }

    @Test
    fun `a hold is agreed with Telecom first`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        voice.snapshot { state = Call.State.Connected }
        runtime.setOnHold(true)
        assertEquals(listOf("connected", "held true"), telecom.session.reports)
        assertTrue(runtime.call.value!!.isOnHold)

        telecom.session.allowsHold = false
        assertEquals("system_call_failed", refusal { runtime.setOnHold(false) })
        assertTrue(runtime.call.value!!.isOnHold)
    }

    @Test
    fun `a hold the SDK refuses is taken back from Telecom`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        voice.snapshot { state = Call.State.Connected }
        voice.holdError = VoiceError("sip_488", "Not Acceptable Here", 488)
        assertEquals("sip_488", refusal { runtime.setOnHold(true) })
        assertEquals(listOf("connected", "held true", "held false"), telecom.session.reports)
    }

    @Test
    fun `a system hold the SDK refuses closes the microphone instead`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        voice.snapshot { state = Call.State.Connected }
        voice.holdError = VoiceError("sip_488", "Not Acceptable Here", 488)
        telecom.events!!.holdFromTelecom(true)
        assertTrue(runtime.call.value!!.isOnHold)
        assertTrue(runtime.call.value!!.call.isMuted)
        telecom.events!!.holdFromTelecom(false)
        assertFalse(runtime.call.value!!.isOnHold)
        assertFalse(runtime.call.value!!.call.isMuted)
    }

    @Test
    fun `a system hold before the answer ends the call`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        telecom.events!!.holdFromTelecom(true)
        assertEquals("hangup", voice.commands.last())
    }

    @Test
    fun `an end that came from Telecom is not reported back to it`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        telecom.events!!.hangupFromTelecom()
        assertEquals("hangup", voice.commands.last())
        voice.snapshot { state = Call.State.Disconnected; endReason = Call.EndReason.Cancelled }
        advanceUntilIdle()
        assertTrue(telecom.session.reports.isEmpty())
        assertEquals("stop", service.log.last())
        assertNull(runtime.call.value?.call?.error)
    }

    @Test
    fun `the system's mute follows into the call`() = runTest {
        val runtime = runtime()
        runtime.connect(token())
        telecom.events!!.muteFromTelecom(true)
        telecom.events!!.muteFromTelecom(true)
        assertEquals(listOf("connect", "mute true"), voice.commands)
        // An ended call has nothing to mute, and saying so is not an error.
        voice.snapshot { state = Call.State.Disconnected; endReason = Call.EndReason.RemoteHangup }
        telecom.events!!.muteFromTelecom(false)
    }

    @Test
    fun `the destination is read from the token`() {
        assertEquals("+4915112345678", destinationOf(token()))
        assertNull(destinationOf(token(to = null)))
        assertNull(destinationOf("a.b"))
        assertNull(destinationOf("a.!!!.c"))
        assertNull(destinationOf("a.${Base64.getUrlEncoder().encodeToString("[1]".toByteArray())}.c"))
    }

    @Test
    fun `what is reported to Telecom at the end`() {
        fun cause(reason: Call.EndReason, viaTelecom: Boolean = false) = VoiceRuntime.telecomEndCause(reason, viaTelecom)
        assertEquals(TelecomEndCause.Remote, cause(Call.EndReason.RemoteHangup))
        assertEquals(TelecomEndCause.Remote, cause(Call.EndReason.NoAnswer))
        assertEquals(TelecomEndCause.Rejected, cause(Call.EndReason.Busy))
        assertEquals(TelecomEndCause.Error, cause(Call.EndReason.Failed))
        assertEquals(TelecomEndCause.Local, cause(Call.EndReason.LocalHangup))
        assertNull(cause(Call.EndReason.LocalHangup, viaTelecom = true))
    }
}
