//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import Foundation
import YollaVoiceSDK

/// A snapshot of the client's call as the plugin reports it.
struct CallSnapshot: Equatable {
    var callID: String
    var to: String
    /// The caller ID; `nil` when the call is anonymous.
    var from: String?
    var state: Call.State = .connecting
    var endReason: Call.EndReason?
    var error: VoiceError?
    var wasConnected = false
    var isMuted = false
    var isOnHold = false
    var hasEarlyMedia = false
    var warnings: Set<CallQualityWarning> = []
}

/// A place the call's audio can go.
struct AudioRoute: Equatable {
    enum Kind { case earpiece, speaker, bluetooth, wired, other }
    var id: String
    var kind: Kind
    var name: String
}

struct AudioRoutes: Equatable {
    var routes: [AudioRoute] = []
    var currentID: String?
}

/// What the plugin needs of a call token before the call exists: CallKit and the first snapshot show these. The
/// token is not checked here; the SDK does that.
struct TokenClaims: Equatable {
    var callID: String
    var to: String
    var from: String?

    /// `nil` when the token cannot be read.
    init?(callToken: String) {
        let segments = callToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var b64 = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = claims["jti"] as? String, !id.isEmpty,
            let to = claims["to"] as? String, !to.isEmpty
        else { return nil }
        callID = id
        self.to = to
        if let cli = claims["cli"] as? String, !cli.isEmpty, cli != "anonymous" { from = cli }
    }
}

/// What happens to a call, as the SDK's `CallDelegate` tells it, without the `Call` object (which only the SDK
/// can make): the runtime listens to this, and its tests speak it.
@MainActor
protocol CallEvents: AnyObject {
    func callRang(earlyMedia: Bool)
    func callConnected()
    func callIsReconnecting(_ error: VoiceError)
    func callReconnected()
    func callEnded(
        reason: Call.EndReason,
        error: VoiceError?
    )
    func callQualityChanged(_ warnings: Set<CallQualityWarning>)
}

/// The part of the SDK's `Call` the runtime drives.
protocol CallControlling: AnyObject, Sendable {
    func setMuted(_ muted: Bool) async
    func setOnHold(_ hold: Bool) async throws
    func sendDigits(_ digits: String) async throws
    func hangup() async
    func stats() async -> CallStats
}

extension Call: CallControlling {}

/// The SDK client as the runtime uses it; tests put a fake in its place.
@MainActor
protocol VoiceConnecting: AnyObject {
    /// The UUID CallKit knows the call of this token by. Throws `invalid_token`.
    func callUUID(for callToken: String) throws -> UUID
    /// Asks the user for the microphone when they have not been asked yet.
    func microphoneGranted() async -> Bool
    /// Sets the audio session up for calls; does not activate it.
    func configureAudio() throws
    /// Whether the SDK may use audio: on while the audio session is active for a call.
    func setAudioEnabled(_ enabled: Bool)
    /// Places the call; `events` hears everything that happens to it, also before this returns.
    func connect(
        callToken: String,
        events: any CallEvents
    ) async throws -> any CallControlling
    func disconnect() async
}

/// Why the system's call ended, as CallKit wants it.
enum SystemEndReason: Equatable { case remoteEnded, unanswered, failed }

/// What the system's call service (CallKit) asks of the call.
@MainActor
protocol SystemCallHandler: AnyObject {
    /// CallKit took the call: `false` when it is not the one being started.
    func systemDidStart(_ uuid: UUID) -> Bool
    func systemWantsEnd(_ uuid: UUID) async -> Bool
    func systemWantsMute(
        _ uuid: UUID,
        muted: Bool
    ) async -> Bool
    func systemWantsHold(
        _ uuid: UUID,
        hold: Bool
    ) async -> Bool
    /// The audio session was activated or deactivated for the call.
    func systemAudio(active: Bool)
    /// CallKit dropped everything it knew.
    func systemDidReset()
}

/// The system's call service as the runtime uses it: `CallKitCalls`, or a fake in tests.
@MainActor
protocol SystemCalls: AnyObject {
    var handler: (any SystemCallHandler)? { get set }
    /// Returns once the system has taken the call; throws when it refuses.
    func start(
        uuid: UUID,
        number: String
    ) async throws
    func end(uuid: UUID) async throws
    func setMuted(
        uuid: UUID,
        _ muted: Bool
    ) async throws
    func setHeld(
        uuid: UUID,
        _ held: Bool
    ) async throws
    func reportConnected(_ uuid: UUID)
    func reportEnded(
        _ uuid: UUID,
        reason: SystemEndReason
    )
}

/// The audio session, the routes and the proximity sensor: `DeviceAudio`, or a fake in tests.
@MainActor
protocol AudioControlling: AnyObject {
    var onRoutesChanged: (() -> Void)? { get set }
    func routes() -> AudioRoutes
    func select(routeID: String) throws
    /// Without CallKit the plugin activates the audio session itself.
    func setSessionActive(_ active: Bool) throws
    /// Turns the screen off at the ear while a call goes to the earpiece.
    func setProximityMonitoring(_ on: Bool)
}

extension VoiceError {
    /// The plugin's own error code: the system's call service did not take the call or a command.
    static func systemCallFailed(_ message: String) -> VoiceError {
        VoiceError(code: "system_call_failed", message: message)
    }
}
