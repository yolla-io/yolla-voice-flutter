//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_route.dart';
import 'call.dart';
import 'call_stats.dart';
import 'messages.g.dart';
import 'voice_error.dart';

/// Places calls through the Yolla voice platform, one at a time.
///
/// There is nothing to configure: where to connect, the SDK learns from the platform with the call token. Every
/// `VoiceClient()` is the same client; the call belongs to the app, not to a screen, and goes on when the screen
/// that started it is gone.
///
/// The plugin does the system's part of a call itself: CallKit on iOS, Telecom and the call notification on
/// Android, the audio session, the proximity sensor. It asks the user for the microphone (and on Android for
/// notifications and Bluetooth) when the first call is placed.
class VoiceClient {
  /// The app's client.
  factory VoiceClient() => _shared ??= VoiceClient._(VoiceHostApi(), null);

  /// A client over [api], for the plugin's own tests.
  @visibleForTesting
  VoiceClient.forTesting(VoiceHostApi api, {BinaryMessenger? binaryMessenger}) : this._(api, binaryMessenger);

  VoiceClient._(this._api, BinaryMessenger? binaryMessenger) {
    VoiceFlutterApi.setUp(_Events(this), binaryMessenger: binaryMessenger);
    unawaited(_sync());
  }

  static VoiceClient? _shared;

  final VoiceHostApi _api;
  final _call = ValueNotifier<Call?>(null);
  final _audioRoutes = ValueNotifier<AudioRoutes>(const AudioRoutes());
  bool _callReported = false;
  bool _routesReported = false;

  /// The client's call as it is now: null until the first call, then a new [Call] every time something about it
  /// changes.
  ///
  /// An ended call stays here until the next [connect], so its outcome ([Call.endReason], [Call.error]) is never
  /// lost. Record calls for history and analytics in a listener that lives as long as the app, not a screen.
  ValueListenable<Call?> get call => _call;

  /// [call] as a stream: the current value first, then every change.
  Stream<Call?> get calls => _stream(_call);

  /// The audio routes of the call in progress and the one in use.
  ValueListenable<AudioRoutes> get audioRoutes => _audioRoutes;

  /// The version of the native Yolla Voice SDK the plugin runs on.
  Future<String> get sdkVersion => _guard(_api.sdkVersion);

  /// Places a call with a call token from your backend, which gets it from the Yolla platform.
  ///
  /// A token is for one call and lives a short time: ask your backend for a new one right before every call.
  ///
  /// Returns as soon as the call has started; [call] then holds it in [CallState.connecting] and everything else
  /// (ringing, the answer, the end, a failure of the set-up) comes there. Throws [VoiceError] only when no call can
  /// start, and then [call] does not change: `invalid_token` (the token cannot be read), `microphone_denied`,
  /// `call_in_progress` (the client's call has not ended).
  Future<void> connect(String callToken) => _guard(() => _api.connect(callToken));

  /// Ends the call, at any moment: before the answer it ends as [CallEndReason.cancelled], after it as
  /// [CallEndReason.localHangup]. The end comes in [call]. Does nothing without a call and never throws.
  Future<void> hangup() async {
    try {
      await _api.hangup();
    } on PlatformException {
      // Nothing to end.
    }
  }

  /// Mutes or unmutes the microphone. Local and immediate: the other side hears silence. It can be set while the
  /// call is being set up. Throws [VoiceError] `invalid_call_state` when there is no call.
  Future<void> setMuted(bool muted) => _guard(() => _api.setMuted(muted));

  /// Puts the call on hold or resumes it. Hold is agreed with the other side, which takes a moment; while on hold
  /// no audio flows in either direction. Throws [VoiceError]: `invalid_call_state` when the call is not connected,
  /// `sip_<status>` or `timeout` when the network refused or did not answer; the call then stays as it was.
  Future<void> setOnHold(bool hold) => _guard(() => _api.setOnHold(hold));

  /// Sends DTMF digits (`0`–`9`, `*`, `#`, `A`–`D`), in order. Throws [VoiceError]: `invalid_call_state` when the
  /// call is not connected, `dtmf_unavailable` when this call cannot carry digits.
  Future<void> sendDigits(String digits) => _guard(() => _api.sendDigits(digits));

  /// The call's audio statistics at this moment; the last ones taken once the call has ended, null when there has
  /// been no call.
  Future<CallStats?> stats() async {
    final stats = await _guard(_api.stats);
    return stats == null ? null : _stats(stats);
  }

  /// Sends the call's audio to [route], one of [AudioRoutes.available]. The change shows in [audioRoutes] when
  /// the system has made it.
  Future<void> selectAudioRoute(AudioRoute route) => _guard(() => _api.selectAudioRoute(route.id));

  /// What the native side has when this side starts: a call may be up (the app's screen was closed and opened
  /// again during a call).
  Future<void> _sync() async {
    try {
      final call = await _api.currentCall();
      if (!_callReported) _call.value = call == null ? null : _toCall(call);
      final routes = await _api.audioRoutes();
      if (!_routesReported) _audioRoutes.value = _toRoutes(routes);
    } on PlatformException {
      // No native side (a unit test of the app, an unsupported platform): the client stays empty.
    } on MissingPluginException {
      // The same.
    }
  }

  static Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on PlatformException catch (e) {
      final details = e.details;
      throw VoiceError(e.code, e.message ?? '', sipStatus: details is int ? details : null);
    }
  }

  static Stream<T> _stream<T>(ValueListenable<T> source) {
    late final StreamController<T> controller;
    void forward() => controller.add(source.value);
    controller = StreamController<T>(
      onListen: () {
        controller.add(source.value);
        source.addListener(forward);
      },
      onCancel: () => source.removeListener(forward),
    );
    return controller.stream;
  }

  static Call _toCall(CallMessage m) => Call(
    callId: m.callId,
    to: m.to,
    from: m.from == null ? const AnonymousCallerId() : VerifiedCallerId(m.from!),
    state: switch (m.state) {
      CallStateMessage.connecting => CallState.connecting,
      CallStateMessage.ringing => CallState.ringing,
      CallStateMessage.connected => CallState.connected,
      CallStateMessage.reconnecting => CallState.reconnecting,
      CallStateMessage.disconnected => CallState.disconnected,
    },
    endReason: switch (m.endReason) {
      null => null,
      EndReasonMessage.localHangup => CallEndReason.localHangup,
      EndReasonMessage.remoteHangup => CallEndReason.remoteHangup,
      EndReasonMessage.busy => CallEndReason.busy,
      EndReasonMessage.noAnswer => CallEndReason.noAnswer,
      EndReasonMessage.rejected => CallEndReason.rejected,
      EndReasonMessage.failed => CallEndReason.failed,
      EndReasonMessage.cancelled => CallEndReason.cancelled,
    },
    error: m.error == null ? null : VoiceError(m.error!.code, m.error!.message, sipStatus: m.error!.sipStatus),
    wasConnected: m.wasConnected,
    isMuted: m.isMuted,
    isOnHold: m.isOnHold,
    hasEarlyMedia: m.hasEarlyMedia,
    qualityWarnings: CallQualityWarning.parse(m.qualityWarnings),
  );

  static CallStats _stats(CallStatsMessage m) => CallStats(
    rttMs: m.rttMs,
    jitterMs: m.jitterMs,
    packetsSent: m.packetsSent,
    packetsReceived: m.packetsReceived,
    packetsLost: m.packetsLost,
    bytesReceived: m.bytesReceived,
    audioLevelIn: m.audioLevelIn,
    codec: m.codec,
    candidateType: m.candidateType,
    sampleRttMs: m.sampleRttMs,
    sampleJitterMs: m.sampleJitterMs,
    sampleLossPercent: m.sampleLossPercent,
    sampleMos: m.sampleMos,
    warnings: CallQualityWarning.parse(m.warnings),
  );

  static AudioRoutes _toRoutes(AudioRoutesMessage m) {
    final available = [
      for (final route in m.routes)
        AudioRoute(
          id: route.id,
          kind: switch (route.kind) {
            AudioRouteKindMessage.earpiece => AudioRouteKind.earpiece,
            AudioRouteKindMessage.speaker => AudioRouteKind.speaker,
            AudioRouteKindMessage.bluetooth => AudioRouteKind.bluetooth,
            AudioRouteKindMessage.wired => AudioRouteKind.wired,
            AudioRouteKindMessage.other => AudioRouteKind.other,
          },
          name: route.name,
        ),
    ];
    AudioRoute? current;
    for (final route in available) {
      if (route.id == m.currentId) current = route;
    }
    return AudioRoutes(available: List.unmodifiable(available), current: current);
  }
}

class _Events implements VoiceFlutterApi {
  _Events(this._client);

  final VoiceClient _client;

  @override
  void onCallChanged(CallMessage? call) {
    _client._callReported = true;
    _client._call.value = call == null ? null : VoiceClient._toCall(call);
  }

  @override
  void onAudioRoutesChanged(AudioRoutesMessage routes) {
    _client._routesReported = true;
    _client._audioRoutes.value = VoiceClient._toRoutes(routes);
  }
}
