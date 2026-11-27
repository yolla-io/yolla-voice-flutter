//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import AVFAudio
import Foundation
import YollaVoiceSDK

/// The one SDK client of the process.
@MainActor
final class SdkVoice: VoiceConnecting {
    /// Made at the first call: an app that never calls starts nothing.
    private lazy var client = VoiceClient()

    func callUUID(for callToken: String) throws -> UUID { try VoiceClient.callUUID(for: callToken) }

    func microphoneGranted() async -> Bool { await AVAudioApplication.requestRecordPermission() }

    func configureAudio() throws { try client.audioDevice.configure() }

    func setAudioEnabled(_ enabled: Bool) { client.audioDevice.isEnabled = enabled }

    func connect(
        callToken: String,
        events: any CallEvents
    ) async throws -> any CallControlling {
        try await client.connect(callToken: callToken, delegate: DelegateAdapter(events))
    }

    func disconnect() async { await client.disconnect() }
}

/// The SDK's delegate, turned into `CallEvents`. The SDK's call keeps it, and through it the events' receiver, until
/// the call object is released.
@MainActor
private final class DelegateAdapter: CallDelegate {
    private let events: any CallEvents

    init(_ events: any CallEvents) { self.events = events }

    func callDidStartRinging(
        _ call: Call,
        earlyMedia: Bool
    ) { events.callRang(earlyMedia: earlyMedia) }

    func callDidConnect(_ call: Call) { events.callConnected() }

    func callIsReconnecting(
        _ call: Call,
        error: VoiceError
    ) { events.callIsReconnecting(error) }

    func callDidReconnect(_ call: Call) { events.callReconnected() }

    func callDidFailToConnect(
        _ call: Call,
        error: VoiceError
    ) {
        // The delegate method carries no reason; the call knows whether it was busy, unanswered or rejected.
        let events = self.events
        Task { events.callEnded(reason: await call.endReason ?? .failed, error: error) }
    }

    func callDidDisconnect(
        _ call: Call,
        reason: Call.EndReason,
        error: VoiceError?
    ) { events.callEnded(reason: reason, error: error) }

    func callDidReceiveQualityWarnings(
        _ call: Call,
        current: Set<CallQualityWarning>,
        previous: Set<CallQualityWarning>
    ) { events.callQualityChanged(current) }
}
