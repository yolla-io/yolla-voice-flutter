//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// The iOS side of the plugin on fakes of the SDK, CallKit and the audio session.
//

import Foundation
import Testing
import YollaVoiceSDK

@testable import yolla_voice

private func token(
    id: String = "call_1",
    to: String? = "+4915112345678",
    cli: String? = "+4930123456"
) -> String {
    var claims: [String: String] = ["jti": id]
    claims["to"] = to
    claims["cli"] = cli
    let payload = try! JSONSerialization.data(withJSONObject: claims).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "e30.\(payload).sig"
}

private final class FakeCall: CallControlling, @unchecked Sendable {
    var commands: [String] = []
    var holdError: VoiceError?

    func setMuted(_ muted: Bool) async { commands.append("mute \(muted)") }
    func setOnHold(_ hold: Bool) async throws {
        if let holdError { throw holdError }
        commands.append("hold \(hold)")
    }
    func sendDigits(_ digits: String) async throws { commands.append("digits \(digits)") }
    func hangup() async { commands.append("hangup") }
    func stats() async -> CallStats { CallStats(media: .init(), sample: .init(), warnings: []) }
}

@MainActor
private final class FakeVoice: VoiceConnecting {
    var microphone = true
    var audioEnabled = false
    var disconnects = 0
    /// What `connect` hears the call's events through.
    var events: (any CallEvents)?
    private var waiter: CheckedContinuation<any CallControlling, any Error>?

    func callUUID(for callToken: String) throws -> UUID {
        guard callToken.contains(".") else { throw VoiceError(code: "invalid_token", message: "Call token: not a JWT") }
        return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    }
    func microphoneGranted() async -> Bool { microphone }
    func configureAudio() throws {}
    func setAudioEnabled(_ enabled: Bool) { audioEnabled = enabled }

    func connect(
        callToken: String,
        events: any CallEvents
    ) async throws -> any CallControlling {
        self.events = events
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    /// The SDK's `connect` returns the call, or throws.
    func finishConnect(_ result: Result<any CallControlling, any Error>) {
        waiter?.resume(with: result)
        waiter = nil
    }

    func disconnect() async {
        disconnects += 1
        finishConnect(.failure(VoiceError.cancelled))
    }
}

@MainActor
private final class FakeSystem: SystemCalls {
    weak var handler: (any SystemCallHandler)?
    var refuses = false
    var log: [String] = []

    func start(
        uuid: UUID,
        number: String
    ) async throws {
        if refuses { throw CancellationError() }
        #expect(handler?.systemDidStart(uuid) == true)
        log.append("start \(number)")
    }
    func end(uuid: UUID) async throws { _ = await handler?.systemWantsEnd(uuid) }
    func setMuted(
        uuid: UUID,
        _ muted: Bool
    ) async throws { _ = await handler?.systemWantsMute(uuid, muted: muted) }
    func setHeld(
        uuid: UUID,
        _ held: Bool
    ) async throws { _ = await handler?.systemWantsHold(uuid, hold: held) }
    func reportConnected(_ uuid: UUID) { log.append("connected") }
    func reportEnded(
        _ uuid: UUID,
        reason: SystemEndReason
    ) { log.append("ended \(reason)") }
}

@MainActor
private final class FakeAudio: AudioControlling {
    var onRoutesChanged: (() -> Void)?
    var sessionActive = false
    var proximity = false
    var current = "earpiece"

    func routes() -> AudioRoutes {
        AudioRoutes(
            routes: [
                AudioRoute(id: "earpiece", kind: .earpiece, name: "iPhone"),
                AudioRoute(id: "speaker", kind: .speaker, name: "Speaker"),
            ],
            currentID: current
        )
    }
    func select(routeID: String) throws { current = routeID }
    func setSessionActive(_ active: Bool) throws { sessionActive = active }
    func setProximityMonitoring(_ on: Bool) { proximity = on }
}

@MainActor
struct VoiceRuntimeTests {
    private let voice = FakeVoice()
    private let system = FakeSystem()
    private let audio = FakeAudio()
    private let runtime: VoiceRuntime

    init() {
        let tones = VoiceRuntime.EndTones(ended: .zero, busy: .zero, noAnswer: .zero, failed: .zero)
        runtime = VoiceRuntime(voice: voice, system: system, audio: audio, tones: tones)
    }

    /// Waits until `condition` holds; the runtime works in tasks of its own.
    private func eventually(
        _ what: Comment,
        _ condition: () -> Bool
    ) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition(), what)
    }

    private func code(_ block: () async throws -> Void) async -> String? {
        do { try await block() } catch { return (error as? VoiceError)?.code ?? "\(error)" }
        return nil
    }

    /// A call placed and handed back by the SDK.
    private func placed() async throws -> FakeCall {
        try await runtime.connect(callToken: token())
        await eventually("the SDK was asked for the call") { voice.events != nil }
        let call = FakeCall()
        voice.finishConnect(.success(call))
        await eventually("the call was attached") { voice.events != nil }
        for _ in 0..<10 { await Task.yield() }
        return call
    }

    @Test func aCallFromTheStartToTheEnd() async throws {
        var seen: [Call.State] = []
        _ = runtime.observe(call: { if let state = $0?.state, seen.last != state { seen.append(state) } }, routes: { _ in })

        _ = try await placed()
        #expect(system.log == ["start +4915112345678"])
        #expect(runtime.call == CallSnapshot(callID: "call_1", to: "+4915112345678", from: "+4930123456"))
        #expect(runtime.routes.currentID == "earpiece")
        #expect(audio.proximity)

        voice.events?.callRang(earlyMedia: true)
        #expect(runtime.call?.hasEarlyMedia == true)
        voice.events?.callConnected()
        voice.events?.callIsReconnecting(.networkChanged)
        #expect(runtime.call?.error?.code == "network_changed")
        voice.events?.callReconnected()
        #expect(runtime.call?.error == nil)
        voice.events?.callQualityChanged([.lowMOS])
        #expect(runtime.call?.warnings == [.lowMOS])
        voice.events?.callEnded(reason: .remoteHangup, error: nil)

        #expect(seen == [.connecting, .ringing, .connected, .reconnecting, .connected, .disconnected])
        #expect(runtime.call?.wasConnected == true)
        #expect(runtime.call?.endReason == .remoteHangup)
        await eventually("the end was reported to CallKit") { system.log.last == "ended remoteEnded" }
        #expect(system.log == ["start +4915112345678", "connected", "ended remoteEnded"])
        #expect(runtime.routes.routes.isEmpty)
        #expect(!audio.proximity)
        // An event after the end changes nothing.
        voice.events?.callConnected()
        #expect(runtime.call?.state == .disconnected)
    }

    @Test func whatStartsNoCallAtAll() async throws {
        #expect(await code { try await runtime.connect(callToken: "nonsense") } == "invalid_token")
        #expect(await code { try await runtime.connect(callToken: token(to: nil)) } == "invalid_token")
        voice.microphone = false
        #expect(await code { try await runtime.connect(callToken: token()) } == "microphone_denied")
        #expect(runtime.call == nil)
        #expect(system.log.isEmpty)
        #expect(await code { try await runtime.setMuted(true) } == "invalid_call_state")
        #expect(await code { try await runtime.sendDigits("1") } == "invalid_call_state")
        #expect(await code { try runtime.selectRoute("speaker") } == "invalid_call_state")
        await runtime.hangup()

        voice.microphone = true
        _ = try await placed()
        #expect(await code { try await runtime.connect(callToken: token(id: "call_2")) } == "call_in_progress")
    }

    @Test func aSetUpThatFailsEndsTheCallInTheSnapshots() async throws {
        try await runtime.connect(callToken: token(cli: "anonymous"))
        #expect(runtime.call?.state == .connecting)
        #expect(runtime.call?.from == nil)
        await eventually("the SDK was asked for the call") { voice.events != nil }
        voice.finishConnect(.failure(VoiceError(code: "http_401", message: "Unauthorized")))
        await eventually("the call ended") { runtime.call?.state == .disconnected }
        #expect(runtime.call?.endReason == .failed)
        #expect(runtime.call?.error?.code == "http_401")
        await eventually("the end was reported to CallKit") { system.log.last == "ended failed" }

        // The client is free for the next call, which replaces the ended one.
        try await runtime.connect(callToken: token(id: "call_2"))
        #expect(runtime.call?.callID == "call_2")
        #expect(runtime.call?.state == .connecting)
    }

    @Test func aHangUpBeforeTheSDKHasTheCallCancelsIt() async throws {
        try await runtime.connect(callToken: token())
        await eventually("the SDK was asked for the call") { voice.events != nil }
        await runtime.hangup()
        #expect(voice.disconnects == 1)
        await eventually("the call ended") { runtime.call?.state == .disconnected }
        #expect(runtime.call?.endReason == .cancelled)
        #expect(runtime.call?.error == nil)
        // The end came through CallKit's own end action: nothing more to report.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(system.log == ["start +4915112345678"])
    }

    @Test func commandsGoThroughCallKitToTheCall() async throws {
        let call = try await placed()
        voice.events?.callConnected()
        try await runtime.setMuted(true)
        try await runtime.setOnHold(true)
        try await runtime.sendDigits("5")
        try runtime.selectRoute("speaker")
        #expect(call.commands == ["mute true", "hold true", "digits 5"])
        #expect(runtime.call?.isMuted == true)
        #expect(runtime.call?.isOnHold == true)
        #expect(runtime.routes.currentID == "speaker")
        #expect(!audio.proximity)

        call.holdError = VoiceError(code: "sip_488", message: "Not Acceptable Here", sipStatus: 488)
        #expect(await code { try await runtime.setOnHold(false) } == "sip_488")
        #expect(runtime.call?.isOnHold == true)

        await runtime.hangup()
        #expect(call.commands.last == "hangup")
        _ = await runtime.stats()
    }

    @Test func aMuteBeforeTheSDKHasTheCallIsKept() async throws {
        try await runtime.connect(callToken: token())
        await eventually("the SDK was asked for the call") { voice.events != nil }
        try await runtime.setMuted(true)
        #expect(runtime.call?.isMuted == true)
        #expect(await code { try await runtime.setOnHold(true) } == "invalid_call_state")
        let call = FakeCall()
        voice.finishConnect(.success(call))
        await eventually("the mute reached the call") { call.commands == ["mute true"] }
    }

    @Test func withoutCallKitThePluginOwnsTheAudioSession() async throws {
        system.refuses = true
        let call = try await placed()
        #expect(audio.sessionActive)
        #expect(voice.audioEnabled)
        voice.events?.callConnected()
        try await runtime.setMuted(true)
        try await runtime.setOnHold(true)
        #expect(call.commands == ["mute true", "hold true"])
        await runtime.hangup()
        #expect(call.commands.last == "hangup")
        voice.events?.callEnded(reason: .localHangup, error: nil)
        await eventually("the audio was released") { !audio.sessionActive }
        #expect(!voice.audioEnabled)
        #expect(system.log.isEmpty)
    }

    @Test func theSystemsAudioSwitchesTheSDKsAudio() async throws {
        _ = try await placed()
        runtime.systemAudio(active: true)
        #expect(voice.audioEnabled)
        runtime.systemAudio(active: false)
        #expect(!voice.audioEnabled)
    }

    @Test func aCallKitResetEndsTheCall() async throws {
        _ = try await placed()
        runtime.systemDidReset()
        await eventually("the call ended") { runtime.call?.state == .disconnected }
        #expect(runtime.call?.error?.code == "system_call_failed")
        #expect(voice.disconnects == 1)
    }

    @Test func mappings() {
        let tones = VoiceRuntime.EndTones()
        #expect(VoiceRuntime.endToneDuration(reason: .busy, wasConnected: false, tones: tones) == .milliseconds(3100))
        #expect(VoiceRuntime.endToneDuration(reason: .remoteHangup, wasConnected: true, tones: tones) == .milliseconds(600))
        #expect(VoiceRuntime.endToneDuration(reason: .cancelled, wasConnected: false, tones: tones) == .zero)
        #expect(VoiceRuntime.systemEndReason(.noAnswer, endedViaSystem: false) == .unanswered)
        #expect(VoiceRuntime.systemEndReason(.busy, endedViaSystem: false) == .failed)
        #expect(VoiceRuntime.systemEndReason(.localHangup, endedViaSystem: true) == nil)
        #expect(VoiceRuntime.systemEndReason(.localHangup, endedViaSystem: false) == .remoteEnded)

        let claims = TokenClaims(callToken: token())
        #expect(claims?.callID == "call_1")
        #expect(claims?.to == "+4915112345678")
        #expect(claims?.from == "+4930123456")
        #expect(TokenClaims(callToken: token(cli: "anonymous"))?.from == nil)
        #expect(TokenClaims(callToken: "a.b") == nil)
        #expect(TokenClaims(callToken: "a.!!.c") == nil)

        let message = CallSnapshot(callID: "c", to: "1", state: .disconnected, endReason: .busy,
                                   error: VoiceError(code: "sip_486", message: "Busy Here", sipStatus: 486),
                                   warnings: [.lowMOS, .highRTT]).message
        #expect(message.state == .disconnected)
        #expect(message.endReason == .busy)
        #expect(message.error?.sipStatus == 486)
        #expect(message.qualityWarnings == ["high_rtt", "low_mos"])
    }
}
