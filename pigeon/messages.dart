//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// The messages between the Dart side of the plugin and its native sides. After a change run
//   dart run pigeon --input pigeon/messages.dart && dart format lib/src/messages.g.dart
// and commit the three generated files with it.
//

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartPackageName: 'yolla_voice',
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/com/yollacalls/flutter/voice/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.yollacalls.flutter.voice'),
    swiftOut: ['ios/yolla_voice/Sources/yolla_voice/Messages.g.swift'],
  ),
)
enum CallStateMessage { connecting, ringing, connected, reconnecting, disconnected }

enum EndReasonMessage { localHangup, remoteHangup, busy, noAnswer, rejected, failed, cancelled }

enum AudioRouteKindMessage { earpiece, speaker, bluetooth, wired, other }

class VoiceErrorMessage {
  VoiceErrorMessage({required this.code, required this.message, this.sipStatus});
  String code;
  String message;
  int? sipStatus;
}

/// One snapshot of the client's call.
class CallMessage {
  CallMessage({
    required this.callId,
    required this.to,
    this.from,
    required this.state,
    this.endReason,
    this.error,
    required this.wasConnected,
    required this.isMuted,
    required this.isOnHold,
    required this.hasEarlyMedia,
    required this.qualityWarnings,
  });
  String callId;
  String to;

  /// The caller ID; null when the call is anonymous.
  String? from;
  CallStateMessage state;
  EndReasonMessage? endReason;
  VoiceErrorMessage? error;
  bool wasConnected;
  bool isMuted;
  bool isOnHold;
  bool hasEarlyMedia;

  /// The warnings' raw values (`high_rtt`, …): a newer SDK may know more of them than this plugin.
  List<String> qualityWarnings;
}

class CallStatsMessage {
  CallStatsMessage({
    this.rttMs,
    this.jitterMs,
    required this.packetsSent,
    required this.packetsReceived,
    required this.packetsLost,
    required this.bytesReceived,
    this.audioLevelIn,
    this.codec,
    this.candidateType,
    this.sampleRttMs,
    this.sampleJitterMs,
    this.sampleLossPercent,
    this.sampleMos,
    required this.warnings,
  });
  double? rttMs;
  double? jitterMs;
  int packetsSent;
  int packetsReceived;
  int packetsLost;
  int bytesReceived;
  double? audioLevelIn;
  String? codec;
  String? candidateType;
  double? sampleRttMs;
  double? sampleJitterMs;
  double? sampleLossPercent;
  double? sampleMos;
  List<String> warnings;
}

class AudioRouteMessage {
  AudioRouteMessage({required this.id, required this.kind, required this.name});
  String id;
  AudioRouteKindMessage kind;
  String name;
}

class AudioRoutesMessage {
  AudioRoutesMessage({required this.routes, this.currentId});
  List<AudioRouteMessage> routes;
  String? currentId;
}

/// Dart to native. A refusal is a `PlatformException` whose code and message are the `VoiceError`'s and whose
/// details are its SIP status.
@HostApi()
abstract class VoiceHostApi {
  String sdkVersion();

  /// The call as it is now, for a Dart side that starts while the native side already has one.
  CallMessage? currentCall();

  AudioRoutesMessage audioRoutes();

  @async
  void connect(String callToken);

  void hangup();

  @async
  void setMuted(bool muted);

  @async
  void setOnHold(bool hold);

  @async
  void sendDigits(String digits);

  @async
  CallStatsMessage? stats();

  @async
  void selectAudioRoute(String id);
}

/// Native to Dart.
@FlutterApi()
abstract class VoiceFlutterApi {
  void onCallChanged(CallMessage? call);

  void onAudioRoutesChanged(AudioRoutesMessage routes);
}
