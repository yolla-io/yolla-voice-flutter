//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//

// The plugin's generated bridge is its private API; the example's tests stand in for the native side with it.
// ignore_for_file: implementation_imports, invalid_use_of_visible_for_testing_member

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yolla_voice/src/messages.g.dart';
import 'package:yolla_voice/yolla_voice.dart';
import 'package:yolla_voice_example/app_model.dart';
import 'package:yolla_voice_example/main.dart';
import 'package:yolla_voice_example/settings.dart';
import 'package:yolla_voice_example/token_provider.dart';

/// The native side: remembers the commands and answers `connect` as told.
class FakeHost implements VoiceHostApi {
  final commands = <String>[];
  PlatformException? connectFailure;

  @override
  Future<void> connect(String callToken) async {
    if (connectFailure != null) throw connectFailure!;
    commands.add('connect $callToken');
  }

  @override
  Future<void> hangup() async => commands.add('hangup');
  @override
  Future<void> setMuted(bool muted) async => commands.add('mute $muted');
  @override
  Future<void> setOnHold(bool hold) async =>
      throw PlatformException(code: 'sip_488', message: 'Not Acceptable Here', details: 488);
  @override
  Future<void> sendDigits(String digits) async => commands.add('digits $digits');
  @override
  Future<CallStatsMessage?> stats() async => null;
  @override
  Future<CallMessage?> currentCall() async => null;
  @override
  Future<AudioRoutesMessage> audioRoutes() async => AudioRoutesMessage(routes: []);
  @override
  Future<String> sdkVersion() async => '0.1.0';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> report({
  CallStateMessage state = CallStateMessage.connecting,
  EndReasonMessage? endReason,
  VoiceErrorMessage? error,
  bool wasConnected = false,
  bool muted = false,
}) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
  'dev.flutter.pigeon.yolla_voice.VoiceFlutterApi.onCallChanged',
  VoiceFlutterApi.pigeonChannelCodec.encodeMessage([
    CallMessage(
      callId: 'call_1',
      to: '+4915112345678',
      state: state,
      endReason: endReason,
      error: error,
      wasConnected: wasConnected,
      isMuted: muted,
      isOnHold: false,
      hasEarlyMedia: false,
      qualityWarnings: [],
    ),
  ]),
  (_) {},
);

void main() {
  late FakeHost host;
  late AppModel model;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    host = FakeHost();
    model = AppModel(
      client: VoiceClient.forTesting(host),
      tokens: TokenProvider(
        demoToken: 'demo',
        request: (_, _, body) async => (status: 201, body: '{"callToken":"a.b.c"}'),
      ),
    );
  });

  Future<void> dial(WidgetTester tester, String number) async {
    await tester.pumpWidget(ExampleApp(model: model));
    for (final digit in number.split('')) {
      await tester.tap(find.byKey(ValueKey('key $digit')));
    }
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('call')));
    await tester.pump();
  }

  testWidgets('a call from the dialer to its end', (tester) async {
    await dial(tester, '+49151');
    expect(host.commands, ['connect a.b.c']);

    await report();
    await tester.pump();
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.text('+4915112345678'), findsOneWidget);

    await report(state: CallStateMessage.ringing);
    await tester.pump();
    expect(find.text('Ringing…'), findsOneWidget);

    await report(state: CallStateMessage.connected, wasConnected: true);
    await tester.pump();
    expect(find.text('00:00'), findsOneWidget);

    await tester.tap(find.byTooltip('Mute'));
    await tester.tap(find.byTooltip('Hold'));
    await tester.pump();
    expect(host.commands.last, 'mute true');
    expect(find.textContaining('sip_488'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('hangup')));
    expect(host.commands.last, 'hangup');
    await report(state: CallStateMessage.disconnected, endReason: EndReasonMessage.localHangup, wasConnected: true);
    await tester.pump();
    expect(find.text('Call ended'), findsOneWidget);

    // The ended call leaves the screen by itself.
    await tester.pump(AppModel.dismissAfter + const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('call')), findsOneWidget);
  });

  testWidgets('a call that fails says why', (tester) async {
    await dial(tester, '1');
    await report(
      state: CallStateMessage.disconnected,
      endReason: EndReasonMessage.failed,
      error: VoiceErrorMessage(code: 'sip_503', message: 'Service Unavailable', sipStatus: 503),
    );
    await tester.pump();
    expect(find.text('Failed: sip_503 (Service Unavailable, SIP 503)'), findsOneWidget);
    await tester.pump(AppModel.dismissAfter);
  });

  testWidgets('a call that cannot start is an alert, not a call screen', (tester) async {
    host.connectFailure = PlatformException(
      code: 'microphone_denied',
      message: 'Microphone permission was not granted',
    );
    await dial(tester, '1');
    await tester.pump();
    expect(find.textContaining('microphone_denied'), findsOneWidget);
    expect(model.shownCall, isNull);
    expect(model.isPlacing, isFalse);
  });

  test('how a call ended, in words', () {
    expect(AppModel.describe(CallEndReason.busy, null), 'Busy');
    expect(AppModel.describe(CallEndReason.failed, null), 'Failed');
    expect(
      AppModel.describe(CallEndReason.failed, const VoiceError('timeout', 'No answer in time')),
      'Failed: timeout (No answer in time)',
    );
  });

  test('settings survive a restart', () async {
    await model.updateSettings(
      const Settings(tokenUrl: 'https://example.com/token', usePastedToken: true, pastedToken: 't'),
    );
    final again = await SettingsStore().load();
    expect(again.tokenUrl, 'https://example.com/token');
    expect(again.usePastedToken, isTrue);
    expect(again.pastedToken, 't');
  });
}
