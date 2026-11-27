//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import AVFAudio
import CallKit
import Foundation

/// CallKit for the plugin's calls: the app's commands are requested as CX actions, and the provider performs them
/// against the call through `handler`, so that the system's call screen and the app stay in step.
@MainActor
final class CallKitCalls: NSObject, SystemCalls, CXProviderDelegate {
    weak var handler: (any SystemCallHandler)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var starts: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.phoneNumber]
        // A call listed in the Phone app's recents can be started from there, which hands the app an intent to
        // handle; the plugin does not take that on.
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)  // callbacks on the main queue
    }

    // MARK: Requests to the system

    /// Asks CallKit to start a call. Returns when the start action was performed, throws when CallKit refused.
    func start(
        uuid: UUID,
        number: String
    ) async throws {
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .phoneNumber, value: number))
        action.isVideo = false
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
            starts[uuid] = waiter  // stored before the request: the action may be performed first
            controller.request(CXTransaction(action: action)) { error in
                guard let error else { return }
                Task { @MainActor in self.finishStart(uuid, error: error) }
            }
        }
    }

    func end(uuid: UUID) async throws { try await request(CXEndCallAction(call: uuid)) }

    func setMuted(
        uuid: UUID,
        _ muted: Bool
    ) async throws { try await request(CXSetMutedCallAction(call: uuid, muted: muted)) }

    func setHeld(
        uuid: UUID,
        _ held: Bool
    ) async throws { try await request(CXSetHeldCallAction(call: uuid, onHold: held)) }

    private func request(_ action: CXAction) async throws {
        try await controller.request(CXTransaction(action: action))
    }

    func reportConnected(_ uuid: UUID) { provider.reportOutgoingCall(with: uuid, connectedAt: Date()) }

    func reportEnded(
        _ uuid: UUID,
        reason: SystemEndReason
    ) {
        let cxReason: CXCallEndedReason
        switch reason {
        case .remoteEnded: cxReason = .remoteEnded
        case .unanswered: cxReason = .unanswered
        case .failed: cxReason = .failed
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: cxReason)
    }

    private func finishStart(
        _ uuid: UUID,
        error: (any Error)?
    ) {
        guard let waiter = starts.removeValue(forKey: uuid) else { return }
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }

    // MARK: CXProviderDelegate (main queue)

    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            for uuid in Array(starts.keys) { finishStart(uuid, error: CancellationError()) }
            handler?.systemDidReset()
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        perform action: CXStartCallAction
    ) {
        MainActor.assumeIsolated {
            let uuid = action.callUUID
            guard handler?.systemDidStart(uuid) == true else {
                action.fail()
                finishStart(uuid, error: CancellationError())
                return
            }
            let update = CXCallUpdate()
            update.remoteHandle = action.handle
            update.supportsHolding = true
            update.supportsDTMF = true
            update.supportsGrouping = false
            update.supportsUngrouping = false
            update.hasVideo = false
            provider.reportCall(with: uuid, updated: update)
            action.fulfill()
            provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())  // the call is on its way
            finishStart(uuid, error: nil)
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        perform action: CXEndCallAction
    ) {
        MainActor.assumeIsolated {
            guard let handler else { return action.fail() }
            _ = Task { await handler.systemWantsEnd(action.callUUID) ? action.fulfill() : action.fail() }
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        perform action: CXSetMutedCallAction
    ) {
        MainActor.assumeIsolated {
            guard let handler else { return action.fail() }
            _ = Task {
                await handler.systemWantsMute(action.callUUID, muted: action.isMuted) ? action.fulfill() : action.fail()
            }
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        perform action: CXSetHeldCallAction
    ) {
        MainActor.assumeIsolated {
            guard let handler else { return action.fail() }
            _ = Task {
                await handler.systemWantsHold(action.callUUID, hold: action.isOnHold) ? action.fulfill() : action.fail()
            }
        }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        timedOutPerforming action: CXAction
    ) {
        MainActor.assumeIsolated { log("[callkit] timed out performing \(type(of: action))") }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        didActivate audioSession: AVAudioSession
    ) {
        MainActor.assumeIsolated { handler?.systemAudio(active: true) }
    }

    nonisolated func provider(
        _ provider: CXProvider,
        didDeactivate audioSession: AVAudioSession
    ) {
        MainActor.assumeIsolated { handler?.systemAudio(active: false) }
    }
}
