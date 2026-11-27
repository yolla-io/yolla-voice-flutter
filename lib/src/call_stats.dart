//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import 'package:flutter/foundation.dart';

import 'call.dart';

/// A call's audio statistics at one moment, from `VoiceClient.stats`. The values change once a second while the
/// call is connected; before the answer the optional values are null and the counters zero.
@immutable
class CallStats {
  const CallStats({
    this.rttMs,
    this.jitterMs,
    this.packetsSent = 0,
    this.packetsReceived = 0,
    this.packetsLost = 0,
    this.bytesReceived = 0,
    this.audioLevelIn,
    this.codec,
    this.candidateType,
    this.sampleRttMs,
    this.sampleJitterMs,
    this.sampleLossPercent,
    this.sampleMos,
    this.warnings = const {},
  });

  /// Since the start of the call: the round-trip time, in milliseconds.
  final double? rttMs;

  /// Since the start of the call: the jitter of the incoming audio, in milliseconds.
  final double? jitterMs;
  final int packetsSent;
  final int packetsReceived;
  final int packetsLost;
  final int bytesReceived;

  /// The level of the incoming audio, 0 to 1.
  final double? audioLevelIn;

  /// The audio codec in use, for example `opus`.
  final String? codec;

  /// How the audio travels: `host`, `srflx`, `prflx` or `relay`.
  final String? candidateType;

  /// Over the last second: the round-trip time, in milliseconds.
  final double? sampleRttMs;

  /// Over the last second: the jitter, in milliseconds.
  final double? sampleJitterMs;

  /// Over the last second: the share of incoming packets lost, in percent.
  final double? sampleLossPercent;

  /// Over the last second: the estimated mean opinion score, 1 (bad) to 4.5 (excellent).
  final double? sampleMos;

  /// The quality warnings in effect.
  final Set<CallQualityWarning> warnings;

  @override
  bool operator ==(Object other) =>
      other is CallStats &&
      other.rttMs == rttMs &&
      other.jitterMs == jitterMs &&
      other.packetsSent == packetsSent &&
      other.packetsReceived == packetsReceived &&
      other.packetsLost == packetsLost &&
      other.bytesReceived == bytesReceived &&
      other.audioLevelIn == audioLevelIn &&
      other.codec == codec &&
      other.candidateType == candidateType &&
      other.sampleRttMs == sampleRttMs &&
      other.sampleJitterMs == sampleJitterMs &&
      other.sampleLossPercent == sampleLossPercent &&
      other.sampleMos == sampleMos &&
      setEquals(other.warnings, warnings);

  @override
  int get hashCode => Object.hash(
    rttMs,
    jitterMs,
    packetsSent,
    packetsReceived,
    packetsLost,
    bytesReceived,
    audioLevelIn,
    codec,
    candidateType,
    sampleRttMs,
    sampleJitterMs,
    sampleLossPercent,
    sampleMos,
    Object.hashAllUnordered(warnings),
  );
}
