//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yolla_voice/src/messages.g.dart';
import 'package:yolla_voice/yolla_voice.dart';

/// The native side as the client sees it.
class FakeHost implements VoiceHostApi {
  CallMessage? current;
  AudioRoutesMessage routes = AudioRoutesMessage(routes: []);
  PlatformException? failure;
  final commands = <String>[];
  CallStatsMessage? statsValue;

  void _run(String command) {
    commands.add(command);
    final failure = this.failure;
    if (failure != null) throw failure;
  }

  @override
  Future<String> sdkVersion() async => '0.1.0';
  @override
  Future<CallMessage?> currentCall() async => current;
  @override
  Future<AudioRoutesMessage> audioRoutes() async => routes;
  @override
  Future<void> connect(String callToken) async => _run('connect $callToken');
  @override
  Future<void> hangup() async => _run('hangup');
  @override
  Future<void> setMuted(bool muted) async => _run('mute $muted');
  @override
  Future<void> setOnHold(bool hold) async => _run('hold $hold');
  @override
  Future<void> sendDigits(String digits) async => _run('digits $digits');
  @override
  Future<CallStatsMessage?> stats() async {
    _run('stats');
    return statsValue;
  }

  @override
  Future<void> selectAudioRoute(String id) async => _run('route $id');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CallMessage message({
  CallStateMessage state = CallStateMessage.connecting,
  EndReasonMessage? endReason,
  VoiceErrorMessage? error,
  String? from,
  bool muted = false,
  List<String> warnings = const [],
}) => CallMessage(
  callId: 'call_1',
  to: '+4915112345678',
  from: from,
  state: state,
  endReason: endReason,
  error: error,
  wasConnected: false,
  isMuted: muted,
  isOnHold: false,
  hasEarlyMedia: false,
  qualityWarnings: warnings,
);

/// Delivers a native event the way the engine does.
Future<void> send(String method, Object? argument) async {
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
    'dev.flutter.pigeon.yolla_voice.VoiceFlutterApi.$method',
    VoiceFlutterApi.pigeonChannelCodec.encodeMessage([argument]),
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeHost host;
  late VoiceClient client;

  Future<void> start() async {
    client = VoiceClient.forTesting(host);
    await pumpEventQueue();
  }

  setUp(() => host = FakeHost());

  test('starts without a call', () async {
    await start();
    expect(client.call.value, isNull);
    expect(client.audioRoutes.value, const AudioRoutes());
  });

  test('takes over a call the native side already has', () async {
    host.current = message(state: CallStateMessage.connected, from: '+4930123456');
    host.routes = AudioRoutesMessage(
      routes: [
        AudioRouteMessage(id: 'e', kind: AudioRouteKindMessage.earpiece, name: 'Phone'),
        AudioRouteMessage(id: 's', kind: AudioRouteKindMessage.speaker, name: 'Speaker'),
      ],
      currentId: 's',
    );
    await start();
    expect(client.call.value?.state, CallState.connected);
    expect(client.call.value?.from, const VerifiedCallerId('+4930123456'));
    expect(client.audioRoutes.value.available, hasLength(2));
    expect(client.audioRoutes.value.current?.kind, AudioRouteKind.speaker);
  });

  test('an event that arrives before the first read is not overwritten by it', () async {
    host.current = null;
    client = VoiceClient.forTesting(host);
    await send('onCallChanged', message(state: CallStateMessage.ringing));
    await pumpEventQueue();
    expect(client.call.value?.state, CallState.ringing);
  });

  test('follows the call to its end', () async {
    await start();
    final seen = <CallState?>[];
    final subscription = client.calls.listen((call) => seen.add(call?.state));
    await send('onCallChanged', message());
    await send('onCallChanged', message(state: CallStateMessage.ringing));
    await send('onCallChanged', message(state: CallStateMessage.connected));
    await send(
      'onCallChanged',
      message(
        state: CallStateMessage.disconnected,
        endReason: EndReasonMessage.failed,
        error: VoiceErrorMessage(code: 'sip_503', message: 'Service Unavailable', sipStatus: 503),
      ),
    );
    await pumpEventQueue();
    await subscription.cancel();
    expect(seen, [null, CallState.connecting, CallState.ringing, CallState.connected, CallState.disconnected]);
    final ended = client.call.value!;
    expect(ended.isActive, isFalse);
    expect(ended.endReason, CallEndReason.failed);
    expect(ended.error, const VoiceError('sip_503', 'Service Unavailable', sipStatus: 503));
    expect(ended.from, const AnonymousCallerId());
  });

  test('a snapshot equal to the last one is not announced again', () async {
    await start();
    var changes = 0;
    client.call.addListener(() => changes++);
    await send('onCallChanged', message(muted: true));
    await send('onCallChanged', message(muted: true));
    expect(changes, 1);
  });

  test('quality warnings this version does not know are left out', () async {
    await start();
    await send('onCallChanged', message(warnings: ['high_rtt', 'from_the_future', 'low_mos']));
    expect(client.call.value?.qualityWarnings, {CallQualityWarning.highRtt, CallQualityWarning.lowMos});
  });

  test('commands go to the native side', () async {
    await start();
    await client.connect('token');
    await client.setMuted(true);
    await client.setOnHold(true);
    await client.sendDigits('1#');
    await client.selectAudioRoute(const AudioRoute(id: 's', kind: AudioRouteKind.speaker, name: 'Speaker'));
    await client.hangup();
    expect(host.commands, ['connect token', 'mute true', 'hold true', 'digits 1#', 'route s', 'hangup']);
    expect(await client.sdkVersion, '0.1.0');
  });

  test('a refusal is a VoiceError with the code, the message and the SIP status', () async {
    await start();
    host.failure = PlatformException(code: 'sip_486', message: 'Busy Here', details: 486);
    await expectLater(client.setOnHold(true), throwsA(const VoiceError('sip_486', 'Busy Here', sipStatus: 486)));
    host.failure = PlatformException(code: VoiceError.callInProgress, message: 'Another call is active');
    await expectLater(
      client.connect('token'),
      throwsA(isA<VoiceError>().having((e) => e.code, 'code', 'call_in_progress')),
    );
  });

  test('hangup never throws', () async {
    await start();
    host.failure = PlatformException(code: VoiceError.invalidCallState);
    await client.hangup();
  });

  test('stats are null before the first call and mapped after', () async {
    await start();
    expect(await client.stats(), isNull);
    host.statsValue = CallStatsMessage(
      rttMs: 80,
      packetsSent: 10,
      packetsReceived: 9,
      packetsLost: 1,
      bytesReceived: 900,
      codec: 'opus',
      sampleMos: 4.2,
      warnings: ['high_jitter'],
    );
    final stats = await client.stats();
    expect(stats?.rttMs, 80);
    expect(stats?.codec, 'opus');
    expect(stats?.sampleMos, 4.2);
    expect(stats?.warnings, {CallQualityWarning.highJitter});
  });

  test('audio routes follow the native side', () async {
    await start();
    await send(
      'onAudioRoutesChanged',
      AudioRoutesMessage(
        routes: [AudioRouteMessage(id: 'b', kind: AudioRouteKindMessage.bluetooth, name: 'AirPods')],
        currentId: 'gone',
      ),
    );
    expect(client.audioRoutes.value.available.single.name, 'AirPods');
    expect(client.audioRoutes.value.current, isNull);
  });
}
