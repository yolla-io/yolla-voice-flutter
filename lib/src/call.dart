//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import 'package:flutter/foundation.dart';

import 'voice_error.dart';

/// Where a call is in its life. Later versions can add values: keep a default branch.
enum CallState {
  /// The call is being set up; the other side is not ringing yet.
  connecting,

  /// The other side is ringing.
  ringing,

  /// The call was answered; audio flows in both directions (in none while the call is on hold).
  connected,

  /// The network changed during the call and the SDK is restoring it. [Call.error] says what was noticed
  /// (`network_changed`, `ice_failed`, `signaling_reconnected`); it is information, not a failure. The call goes
  /// back to [connected], or ends as `failed` with `media_timeout` after 20 seconds.
  reconnecting,

  /// The call is over; [Call.endReason] says why.
  disconnected,
}

/// Why a call ended. Later versions can add values: keep a default branch.
enum CallEndReason {
  /// You hung up a connected call.
  localHangup,

  /// The other side hung up.
  remoteHangup,

  /// The other side is busy.
  busy,

  /// The network reported that nobody answered, or that the number is not available.
  noAnswer,

  /// The other side declined the call.
  rejected,

  /// Anything else: the call could not be set up or was lost. [Call.error] has the details.
  failed,

  /// You hung up before the answer.
  cancelled,
}

/// A sign that the audio quality of a connected call is poor.
enum CallQualityWarning {
  /// The round trip takes 400 ms or more.
  highRtt('high_rtt'),

  /// The jitter is 30 ms or more.
  highJitter('high_jitter'),

  /// 3 % of the incoming audio packets or more are lost.
  highPacketLoss('high_packet_loss'),

  /// The estimated MOS is below 3.5.
  lowMos('low_mos');

  const CallQualityWarning(this.rawValue);

  /// The warning's name on the platform.
  final String rawValue;

  /// The warnings among [rawValues] that this version knows.
  static Set<CallQualityWarning> parse(Iterable<String> rawValues) => {
    for (final raw in rawValues)
      for (final warning in values)
        if (warning.rawValue == raw) warning,
  };
}

/// The caller ID of a call: what the called side sees as the calling number. It is decided when your backend asks
/// the platform for the call token.
@immutable
sealed class CallerId {
  const CallerId();
}

/// The call is placed without a caller ID.
final class AnonymousCallerId extends CallerId {
  const AnonymousCallerId();

  @override
  bool operator ==(Object other) => other is AnonymousCallerId;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'anonymous';
}

/// The call shows [number], one verified for your account on the platform.
final class VerifiedCallerId extends CallerId {
  const VerifiedCallerId(this.number);

  final String number;

  @override
  bool operator ==(Object other) => other is VerifiedCallerId && other.number == number;

  @override
  int get hashCode => number.hashCode;

  @override
  String toString() => number;
}

/// A call as it was at one moment. It never changes: the current one is `VoiceClient.call`.
///
/// The constructor exists for your tests and previews; the SDK makes the values an app works with.
@immutable
class Call {
  const Call({
    required this.callId,
    required this.to,
    this.from = const AnonymousCallerId(),
    this.state = CallState.connecting,
    this.endReason,
    this.error,
    this.wasConnected = false,
    this.isMuted = false,
    this.isOnHold = false,
    this.hasEarlyMedia = false,
    this.qualityWarnings = const {},
  });

  /// The call's ID on the platform, the one inside the call token. Log it and quote it when you contact support.
  final String callId;

  /// The destination, as the call token has it.
  final String to;

  /// The caller ID the called side sees, as the call token has it.
  final CallerId from;

  final CallState state;

  /// Why the call ended; null while it is not over.
  final CallEndReason? endReason;

  /// With [CallState.disconnected] and [CallEndReason.failed] (or a refusal by the network): what went wrong. With
  /// [CallState.reconnecting]: what was noticed. Null otherwise.
  final VoiceError? error;

  /// Whether the call was answered: tells "never got through" from "dropped after the answer".
  final bool wasConnected;

  /// Whether the microphone is muted with `VoiceClient.setMuted`.
  final bool isMuted;

  final bool isOnHold;

  /// While ringing: the network sends audio of its own (a ringback tone or an announcement), which the user hears.
  /// When nothing audible arrives the SDK plays a ringback tone itself.
  final bool hasEarlyMedia;

  /// The quality warnings in effect; empty when the quality is good.
  final Set<CallQualityWarning> qualityWarnings;

  /// False once the call is over.
  bool get isActive => state != CallState.disconnected;

  @override
  bool operator ==(Object other) =>
      other is Call &&
      other.callId == callId &&
      other.to == to &&
      other.from == from &&
      other.state == state &&
      other.endReason == endReason &&
      other.error == error &&
      other.wasConnected == wasConnected &&
      other.isMuted == isMuted &&
      other.isOnHold == isOnHold &&
      other.hasEarlyMedia == hasEarlyMedia &&
      setEquals(other.qualityWarnings, qualityWarnings);

  @override
  int get hashCode => Object.hash(
    callId,
    to,
    from,
    state,
    endReason,
    error,
    wasConnected,
    isMuted,
    isOnHold,
    hasEarlyMedia,
    Object.hashAllUnordered(qualityWarnings),
  );

  @override
  String toString() =>
      'Call($callId to $to, ${state.name}'
      '${endReason == null ? '' : ', ${endReason!.name}'}'
      '${error == null ? '' : ', ${error!.code}'}'
      '${isMuted ? ', muted' : ''}${isOnHold ? ', on hold' : ''})';
}
