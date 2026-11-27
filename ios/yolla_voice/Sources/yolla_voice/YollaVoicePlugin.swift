//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import Flutter
import UIKit
import YollaVoiceSDK

/// The iOS side of the Yolla Voice plugin: hands the Dart side's commands to the process's `VoiceRuntime` and
/// sends it the call's snapshots and audio routes. The call is not this object's: it lives in the runtime.
public final class YollaVoicePlugin: NSObject, FlutterPlugin, VoiceHostApi {
    /// The one runtime of the process.
    @MainActor static let runtime: VoiceRuntime = {
        let log: (String) -> Void = { NSLog("[YollaVoice] %@", $0) }
        return VoiceRuntime(voice: SdkVoice(), system: CallKitCalls(log: log), audio: DeviceAudio(), log: log)
    }()

    private enum Report {
        case call(CallSnapshot?)
        case routes(AudioRoutes)
    }

    private var observation: UUID?
    private var reports: Task<Void, Never>?

    public static func register(with registrar: any FlutterPluginRegistrar) {
        MainActor.assumeIsolated {
            let plugin = YollaVoicePlugin()
            VoiceHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: plugin)
            plugin.report(to: VoiceFlutterApi(binaryMessenger: registrar.messenger()))
            registrar.publish(plugin)
        }
    }

    public func detachFromEngine(for registrar: any FlutterPluginRegistrar) {
        MainActor.assumeIsolated {
            VoiceHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
            if let observation { Self.runtime.removeObserver(observation) }
            observation = nil
            reports?.cancel()
            reports = nil
        }
    }

    /// Sends the Dart side every change, one after the other, starting with what there is now.
    @MainActor
    private func report(to events: VoiceFlutterApi) {
        let (stream, continuation) = AsyncStream.makeStream(of: Report.self)
        continuation.yield(.call(Self.runtime.call))
        continuation.yield(.routes(Self.runtime.routes))
        observation = Self.runtime.observe(
            call: { continuation.yield(.call($0)) },
            routes: { continuation.yield(.routes($0)) }
        )
        reports = Task { @MainActor in
            for await report in stream {
                // A Dart side that is not listening (yet, or any more) is not an error.
                switch report {
                case .call(let call): try? await events.onCallChanged(call: call?.message)
                case .routes(let routes): try? await events.onAudioRoutesChanged(routes: routes.message)
                }
            }
        }
    }

    // MARK: VoiceHostApi (called on the main thread)

    func sdkVersion() throws -> String { VoiceSDK.version }

    func currentCall() throws -> CallMessage? { MainActor.assumeIsolated { Self.runtime.call?.message } }

    func audioRoutes() throws -> AudioRoutesMessage { MainActor.assumeIsolated { Self.runtime.routes.message } }

    func connect(callToken: String) async throws {
        try await refusing { try await Self.runtime.connect(callToken: callToken) }
    }

    func hangup() throws {
        MainActor.assumeIsolated { _ = Task { await Self.runtime.hangup() } }
    }

    func setMuted(muted: Bool) async throws { try await refusing { try await Self.runtime.setMuted(muted) } }

    func setOnHold(hold: Bool) async throws { try await refusing { try await Self.runtime.setOnHold(hold) } }

    func sendDigits(digits: String) async throws { try await refusing { try await Self.runtime.sendDigits(digits) } }

    func stats() async throws -> CallStatsMessage? { await Self.runtime.stats()?.message }

    func selectAudioRoute(id: String) async throws { try await refusing { try await Self.runtime.selectRoute(id) } }

    /// The SDK's refusal as the Dart side reads it: the code, the message and the SIP status.
    private func refusing<T>(_ command: @MainActor () async throws -> T) async throws -> T {
        do { return try await command() } catch let error as VoiceError {
            throw PigeonError(code: error.code, message: error.message, details: error.sipStatus.map { Int64($0) })
        }
    }
}

extension CallSnapshot {
    var message: CallMessage {
        let stateMessage: CallStateMessage
        switch state {
        case .connecting: stateMessage = .connecting
        case .ringing: stateMessage = .ringing
        case .connected: stateMessage = .connected
        case .reconnecting: stateMessage = .reconnecting
        case .disconnected: stateMessage = .disconnected
        @unknown default: stateMessage = .connected  // a state added by a newer SDK: the call is still up
        }
        let reasonMessage: EndReasonMessage?
        switch endReason {
        case nil: reasonMessage = nil
        case .localHangup: reasonMessage = .localHangup
        case .remoteHangup: reasonMessage = .remoteHangup
        case .busy: reasonMessage = .busy
        case .noAnswer: reasonMessage = .noAnswer
        case .rejected: reasonMessage = .rejected
        case .failed: reasonMessage = .failed
        case .cancelled: reasonMessage = .cancelled
        @unknown default: reasonMessage = .failed
        }
        return CallMessage(
            callId: callID,
            to: to,
            from: from,
            state: stateMessage,
            endReason: reasonMessage,
            error: error.map { error in
                VoiceErrorMessage(code: error.code, message: error.message, sipStatus: error.sipStatus.map { Int64($0) })
            },
            wasConnected: wasConnected,
            isMuted: isMuted,
            isOnHold: isOnHold,
            hasEarlyMedia: hasEarlyMedia,
            qualityWarnings: warnings.map(\.rawValue).sorted()
        )
    }
}

extension CallStats {
    var message: CallStatsMessage {
        CallStatsMessage(
            rttMs: media.rttMs,
            jitterMs: media.jitterMs,
            packetsSent: Int64(media.packetsSent),
            packetsReceived: Int64(media.packetsReceived),
            packetsLost: Int64(media.packetsLost),
            bytesReceived: Int64(media.bytesReceived),
            audioLevelIn: media.audioLevelIn,
            codec: media.codec,
            candidateType: media.candidateType,
            sampleRttMs: sample.rttMs,
            sampleJitterMs: sample.jitterMs,
            sampleLossPercent: sample.lossPercent,
            sampleMos: sample.mos,
            warnings: warnings.map(\.rawValue).sorted()
        )
    }
}

extension AudioRoutes {
    var message: AudioRoutesMessage {
        AudioRoutesMessage(
            routes: routes.map { route in
                let kind: AudioRouteKindMessage
                switch route.kind {
                case .earpiece: kind = .earpiece
                case .speaker: kind = .speaker
                case .bluetooth: kind = .bluetooth
                case .wired: kind = .wired
                case .other: kind = .other
                }
                return AudioRouteMessage(id: route.id, kind: kind, name: route.name)
            },
            currentId: currentID
        )
    }
}
