//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import AVFAudio
import UIKit

/// The device's audio for a call: the routes `AVAudioSession` offers, the session's activation when CallKit is not
/// used, and the proximity sensor.
@MainActor
final class DeviceAudio: AudioControlling {
    var onRoutesChanged: (() -> Void)?

    private static let earpieceID = "earpiece"
    private static let speakerID = "speaker"
    private let session = AVAudioSession.sharedInstance()
    private var observer: (any NSObjectProtocol)?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onRoutesChanged?() }
        }
    }

    /// The built-in receiver and speaker, and every headset the session can record from (a call needs both ways).
    func routes() -> AudioRoutes {
        var routes: [AudioRoute] = []
        let output = session.currentRoute.outputs.first
        for input in session.availableInputs ?? [] {
            switch input.portType {
            case .builtInMic:
                if output?.portType == .headphones {
                    // Headphones without a microphone take the receiver's place.
                    routes.append(AudioRoute(id: Self.earpieceID, kind: .wired, name: output?.portName ?? "Headphones"))
                } else if UIDevice.current.userInterfaceIdiom == .phone {
                    routes.append(AudioRoute(id: Self.earpieceID, kind: .earpiece, name: UIDevice.current.localizedModel))
                }
            case .bluetoothHFP, .bluetoothLE:
                routes.append(AudioRoute(id: input.uid, kind: .bluetooth, name: input.portName))
            case .headsetMic, .usbAudio:
                routes.append(AudioRoute(id: input.uid, kind: .wired, name: input.portName))
            default:
                routes.append(AudioRoute(id: input.uid, kind: .other, name: input.portName))
            }
        }
        routes.append(AudioRoute(id: Self.speakerID, kind: .speaker, name: "Speaker"))

        let current: String?
        switch output?.portType {
        case nil: current = nil
        case .builtInSpeaker: current = Self.speakerID
        case .builtInReceiver: current = Self.earpieceID
        default:
            // A headset is the session's input as well; headphones without a microphone stand in for the receiver.
            let input = session.currentRoute.inputs.first
            current = routes.first { $0.id == input?.uid || $0.id == output?.uid }?.id
                ?? (output?.portType == .headphones ? Self.earpieceID : nil)
        }
        return AudioRoutes(routes: routes, currentID: current)
    }

    func select(routeID: String) throws {
        if routeID == Self.speakerID {
            try session.overrideOutputAudioPort(.speaker)
            return
        }
        try session.overrideOutputAudioPort(.none)
        let inputs = session.availableInputs ?? []
        let input = routeID == Self.earpieceID
            ? inputs.first { $0.portType == .builtInMic }
            : inputs.first { $0.uid == routeID }
        if let input { try session.setPreferredInput(input) }
    }

    func setSessionActive(_ active: Bool) throws {
        try session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
    }

    func setProximityMonitoring(_ on: Bool) {
        if UIDevice.current.isProximityMonitoringEnabled != on { UIDevice.current.isProximityMonitoringEnabled = on }
    }
}
