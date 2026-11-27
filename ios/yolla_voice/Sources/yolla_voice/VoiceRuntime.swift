//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import Foundation
import YollaVoiceSDK

/// The call of the process and everything the system needs around it: CallKit, the audio session, the audio
/// routes, the proximity sensor. It outlives the Flutter engine; the plugin instances only look at it and send it
/// commands.
@MainActor
final class VoiceRuntime: SystemCallHandler {
    /// How long the tones last that the SDK plays when a call ends. The end report to CallKit and the release of the
    /// audio session wait for them: either one sooner cuts the tone.
    struct EndTones: Equatable {
        /// After a connected call.
        var ended: Duration = .milliseconds(500)
        var busy: Duration = .seconds(3)
        var noAnswer: Duration = .milliseconds(800)
        /// The call failed or was rejected before the answer.
        var failed: Duration = .seconds(2)
    }

    private let voice: any VoiceConnecting
    private let system: any SystemCalls
    private let audio: any AudioControlling
    private let tones: EndTones
    private let log: (String) -> Void

    /// `nil` until the first call; an ended call stays until the next one starts.
    private(set) var call: CallSnapshot? {
        didSet { if call != oldValue { for observer in observers.values { observer.call(call) } } }
    }
    /// The routes of the call in progress; empty without one.
    private(set) var routes = AudioRoutes() {
        didSet { if routes != oldValue { for observer in observers.values { observer.routes(routes) } } }
    }

    private var observers: [UUID: (call: (CallSnapshot?) -> Void, routes: (AudioRoutes) -> Void)] = [:]
    private var session: Session?
    /// The call being set up, until the system has taken it or it failed.
    private var attempt: Session?
    private var placing = false

    init(
        voice: any VoiceConnecting,
        system: any SystemCalls,
        audio: any AudioControlling,
        tones: EndTones = EndTones(),
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.voice = voice
        self.system = system
        self.audio = audio
        self.tones = tones
        self.log = log
        system.handler = self
        audio.onRoutesChanged = { [weak self] in self?.refreshRoutes() }
    }

    /// Tells `call` and `routes` every change from now on; the returned key ends it.
    func observe(
        call: @escaping (CallSnapshot?) -> Void,
        routes: @escaping (AudioRoutes) -> Void
    ) -> UUID {
        let key = UUID()
        observers[key] = (call, routes)
        return key
    }

    func removeObserver(_ key: UUID) { observers[key] = nil }

    // MARK: Commands

    /// Places a call. Returns once the system has taken it and the first snapshot is in `call`; everything else,
    /// a failure of the set-up included, comes there. Throws `VoiceError` when no call started: `call_in_progress`,
    /// `invalid_token`, `microphone_denied`, `cancelled` (a hang-up arrived meanwhile).
    func connect(callToken: String) async throws {
        guard !placing, session?.isActive != true else { throw VoiceError.callInProgress }
        placing = true
        defer { placing = false; attempt = nil }

        let uuid = try voice.callUUID(for: callToken)
        guard let claims = TokenClaims(callToken: callToken) else {
            throw VoiceError(code: "invalid_token", message: "The call token cannot be read")
        }
        let session = Session(runtime: self, uuid: uuid, claims: claims)
        attempt = session
        guard await voice.microphoneGranted() else { throw VoiceError.microphoneDenied }
        // CallKit has the previous call until its end is reported, after the end tone: a start before that is
        // refused, and with a reused token (the same UUID) the late report would end this call.
        await self.session?.released?.value
        // Hung up while the user was asked for the microphone: nothing is started at all.
        if session.hangupRequested { throw VoiceError.cancelled }
        do { try voice.configureAudio() } catch {
            throw VoiceError(code: "media_failed", message: "The audio session could not be set up for calls")
        }
        self.session?.forget()
        self.session = session

        do {
            try await system.start(uuid: uuid, number: claims.to)
            session.usesSystem = true
        } catch {
            // CallKit is not available to this app, or refused: the call goes on without the system's call screen,
            // and the plugin looks after the audio session itself.
            log("[callkit] not used for this call: \(error.localizedDescription)")
            do { try audio.setSessionActive(true) } catch {
                self.session = nil
                throw VoiceError(code: "media_failed", message: "The audio session could not be activated")
            }
            voice.setAudioEnabled(true)
        }
        // Hung up while CallKit was taking the call: nothing is dialed.
        if session.hangupRequested {
            session.release(reporting: .remoteEnded)
            self.session = nil
            throw VoiceError.cancelled
        }
        session.place(callToken: callToken)
    }

    /// Ends the call at any moment, also while it is being set up; does nothing without one.
    func hangup() async {
        guard let session = attempt ?? self.session, session.isActive else { return }
        await session.requestHangup()
    }

    func setMuted(_ muted: Bool) async throws {
        let session = try active()
        guard session.usesSystem else { return await session.applyMute(muted) }
        do { try await system.setMuted(uuid: session.uuid, muted) } catch {
            throw VoiceError.systemCallFailed("CallKit did not take the mute: \(error.localizedDescription)")
        }
    }

    func setOnHold(_ hold: Bool) async throws {
        let session = try active()
        guard session.usesSystem else { return try await session.applyHold(hold) }
        try await session.holdThroughSystem(hold)
    }

    func sendDigits(_ digits: String) async throws {
        guard let call = try active().call else { throw VoiceError.invalidCallState }
        try await call.sendDigits(digits)
    }

    /// `nil` when there has been no call, or the SDK does not have it yet.
    func stats() async -> CallStats? { await session?.call?.stats() }

    func selectRoute(_ id: String) throws {
        guard session?.holdsAudio == true else { throw VoiceError.invalidCallState }
        do { try audio.select(routeID: id) } catch {
            throw VoiceError.systemCallFailed("The audio route could not be changed: \(error.localizedDescription)")
        }
        refreshRoutes()
    }

    private func active() throws -> Session {
        guard let session, session.isActive else { throw VoiceError.invalidCallState }
        return session
    }

    // MARK: SystemCallHandler

    func systemDidStart(_ uuid: UUID) -> Bool { (attempt ?? session)?.uuid == uuid }

    func systemWantsEnd(_ uuid: UUID) async -> Bool {
        guard let session = attempt ?? self.session, session.uuid == uuid else { return false }
        await session.hangup(viaSystem: true)
        return true
    }

    func systemWantsMute(
        _ uuid: UUID,
        muted: Bool
    ) async -> Bool {
        guard let session, session.uuid == uuid, session.isActive else { return false }
        await session.applyMute(muted)
        return true
    }

    func systemWantsHold(
        _ uuid: UUID,
        hold: Bool
    ) async -> Bool {
        guard let session, session.uuid == uuid, session.isActive else { return false }
        return await session.holdFromSystem(hold)
    }

    func systemAudio(active: Bool) {
        log("[callkit] audio \(active ? "activated" : "deactivated")")
        voice.setAudioEnabled(active)
        refreshRoutes()
    }

    func systemDidReset() {
        log("[callkit] reset")
        guard let session, session.isActive else { return }
        Task {
            await voice.disconnect()
            session.callEnded(reason: .failed, error: .systemCallFailed("CallKit was reset"))
        }
    }

    // MARK: Routes

    fileprivate func refreshRoutes() {
        let holdsAudio = session?.holdsAudio == true
        routes = holdsAudio ? audio.routes() : AudioRoutes()
        let atTheEar = routes.routes.first { $0.id == routes.currentID }?.kind == .earpiece
        audio.setProximityMonitoring(session?.isActive == true && (atTheEar || routes.currentID == nil))
    }

    // MARK: One call

    /// Follows one call's events, keeps CallKit in step and cleans up after it.
    @MainActor
    fileprivate final class Session: CallEvents {
        let uuid: UUID
        /// The call goes through CallKit; otherwise the plugin owns the audio session.
        var usesSystem = false
        private(set) var hangupRequested = false
        /// False once the call has ended (or never started).
        private(set) var isActive = true
        /// True from the start to the release of the audio after the end tone.
        private(set) var holdsAudio = false
        /// The SDK's call, once `connect` has returned it; kept after the end for the last statistics.
        private(set) var call: (any CallControlling)?
        /// Completes when the end was reported to CallKit and the audio released.
        private(set) var released: Task<Void, Never>?

        /// Strong on purpose: the runtime lives as long as the process, and a call's last task (the wait for its end
        /// tone) must still find it.
        private let runtime: VoiceRuntime
        private var snapshot: CallSnapshot
        private var endedViaSystem = false
        private var holdWaiter: CheckedContinuation<Void, any Error>?

        init(
            runtime: VoiceRuntime,
            uuid: UUID,
            claims: TokenClaims
        ) {
            self.runtime = runtime
            self.uuid = uuid
            snapshot = CallSnapshot(callID: claims.callID, to: claims.to, from: claims.from)
        }

        /// Shows the call and asks the SDK for it. `connect` takes as long as the network does, so it is not waited
        /// for: what it throws ends the call in the snapshots, as a failure of the set-up.
        func place(callToken: String) {
            holdsAudio = true
            publish()
            runtime.refreshRoutes()
            Task {
                do {
                    let call = try await runtime.voice.connect(callToken: callToken, events: self)
                    await attach(call)
                } catch {
                    let error = error as? VoiceError
                        ?? VoiceError(code: "protocol_error", message: error.localizedDescription)
                    // The user gave up meanwhile: to them the call was cancelled, not failed.
                    if hangupRequested { callEnded(reason: .cancelled, error: nil) } else {
                        callEnded(reason: .failed, error: error)
                    }
                }
            }
        }

        private func attach(_ call: any CallControlling) async {
            // A call can end before `connect` returns it.
            guard isActive else { return }
            self.call = call
            if snapshot.isMuted { await call.setMuted(true) }
            if hangupRequested { await call.hangup() }
        }

        /// The next call has started: the SDK's call object goes, and with it the delegate it keeps.
        func forget() { call = nil }

        // MARK: Commands

        /// A hang-up from the app: asked of CallKit when the call is there, so that the system's screen follows.
        func requestHangup() async {
            hangupRequested = true
            guard usesSystem else { return await hangup(viaSystem: false) }
            do { try await runtime.system.end(uuid: uuid) } catch {
                // Refused: end it anyway, and report the end.
                runtime.log("[callkit] end refused: \(error.localizedDescription)")
                await hangup(viaSystem: false)
            }
        }

        /// Ends the call now, or as soon as `connect` returns it.
        func hangup(viaSystem: Bool) async {
            guard isActive else { return }
            hangupRequested = true
            endedViaSystem = viaSystem
            runtime.log("hangup" + (viaSystem ? " (from CallKit)" : ""))
            if let call {
                await call.hangup()
            } else if holdsAudio, isActive {
                // The SDK is still setting the call up: this makes its `connect` give up at once.
                await runtime.voice.disconnect()
            }
        }

        /// Kept and applied when the SDK's call arrives, if it is not there yet.
        func applyMute(_ muted: Bool) async {
            snapshot.isMuted = muted
            publish()
            await call?.setMuted(muted)
        }

        func applyHold(_ hold: Bool) async throws {
            guard let call else { throw VoiceError.invalidCallState }
            try await call.setOnHold(hold)
            snapshot.isOnHold = hold
            publish()
        }

        /// Asks CallKit for the hold and waits for what the SDK said when CallKit performed it.
        func holdThroughSystem(_ hold: Bool) async throws {
            guard call != nil, holdWaiter == nil else { throw VoiceError.invalidCallState }
            let system = runtime.system, uuid = self.uuid
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                holdWaiter = waiter
                Task {
                    do { try await system.setHeld(uuid: uuid, hold) } catch {
                        self.finishHold(
                            .failure(VoiceError.systemCallFailed("CallKit did not take the hold: \(error.localizedDescription)"))
                        )
                    }
                }
            }
        }

        /// CallKit performs a hold: the app's own request, or the system's (another call wants the line).
        func holdFromSystem(_ hold: Bool) async -> Bool {
            do {
                try await applyHold(hold)
                finishHold(.success(()))
                return true
            } catch {
                runtime.log("hold \(hold) failed: \(error)")
                finishHold(.failure(error))
                return false
            }
        }

        private func finishHold(_ result: Result<Void, any Error>) {
            guard let waiter = holdWaiter else { return }
            holdWaiter = nil
            waiter.resume(with: result)
        }

        // MARK: CallEvents

        func callRang(earlyMedia: Bool) {
            guard isActive else { return }
            snapshot.state = .ringing
            snapshot.hasEarlyMedia = earlyMedia
            publish()
        }

        func callConnected() {
            guard isActive else { return }
            snapshot.state = .connected
            snapshot.wasConnected = true
            snapshot.error = nil
            publish()
            if usesSystem { runtime.system.reportConnected(uuid) }
        }

        func callIsReconnecting(_ error: VoiceError) {
            guard isActive else { return }
            snapshot.state = .reconnecting
            snapshot.error = error
            publish()
        }

        func callReconnected() {
            guard isActive else { return }
            snapshot.state = .connected
            snapshot.error = nil
            publish()
        }

        func callQualityChanged(_ warnings: Set<CallQualityWarning>) {
            guard isActive else { return }
            snapshot.warnings = warnings
            publish()
        }

        func callEnded(
            reason: Call.EndReason,
            error: VoiceError?
        ) {
            guard isActive else { return }
            isActive = false
            snapshot.state = .disconnected
            snapshot.endReason = reason
            snapshot.error = error
            publish()
            runtime.log("ended: \(reason)" + (error.map { " (\($0.code))" } ?? ""))
            finishHold(.failure(VoiceError.invalidCallState))
            let tone = VoiceRuntime.endToneDuration(
                reason: reason,
                wasConnected: snapshot.wasConnected,
                tones: runtime.tones
            )
            let report = VoiceRuntime.systemEndReason(reason, endedViaSystem: endedViaSystem)
            released = Task {
                try? await Task.sleep(for: tone)
                self.release(reporting: report)
            }
        }

        /// Lets the system's side of the call go: the end report to CallKit, or the audio session without it.
        func release(reporting reason: SystemEndReason?) {
            isActive = false
            holdsAudio = false
            if usesSystem {
                if let reason { runtime.system.reportEnded(uuid, reason: reason) }
            } else {
                runtime.voice.setAudioEnabled(false)
                try? runtime.audio.setSessionActive(false)
            }
            runtime.refreshRoutes()
        }

        private func publish() {
            // Only the runtime's current call is shown: a late event of an older one changes nothing.
            if runtime.session === self { runtime.call = snapshot }
        }
    }

    // MARK: Mapping

    /// How long the SDK's tone for the end of a call lasts, with a small margin; zero when the SDK plays none.
    nonisolated static func endToneDuration(
        reason: Call.EndReason,
        wasConnected: Bool,
        tones: EndTones
    ) -> Duration {
        let tone: Duration
        if wasConnected {
            tone = tones.ended
        } else {
            switch reason {
            case .busy: tone = tones.busy
            case .noAnswer: tone = tones.noAnswer
            case .failed, .rejected: tone = tones.failed
            case .localHangup, .remoteHangup, .cancelled: return .zero
            @unknown default: return .zero
            }
        }
        return tone + .milliseconds(100)
    }

    /// What to report to CallKit. `nil` when the end was performed through CallKit's own end action (fulfilling it
    /// already told CallKit). A local end that bypassed CallKit is still reported so that no stale system call
    /// remains.
    nonisolated static func systemEndReason(
        _ reason: Call.EndReason,
        endedViaSystem: Bool
    ) -> SystemEndReason? {
        switch reason {
        case .remoteHangup: return .remoteEnded
        case .noAnswer: return .unanswered
        case .busy, .rejected, .failed: return .failed
        case .localHangup, .cancelled: return endedViaSystem ? nil : .remoteEnded
        @unknown default: return .failed
        }
    }
}
