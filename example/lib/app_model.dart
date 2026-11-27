//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//
// Part of the Yolla Voice example app; see the LICENSE file in the example's folder.
//

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yolla_voice/yolla_voice.dart';

import 'settings.dart';
import 'token_provider.dart';

/// Owns the client, the settings and what the screens show of the call. It lives as long as the app: a call goes
/// on when the screen that started it is gone.
class AppModel extends ChangeNotifier {
  AppModel({VoiceClient? client, TokenProvider? tokens, SettingsStore? store})
    : client = client ?? VoiceClient(),
      _tokens = tokens ?? TokenProvider(),
      _store = store ?? SettingsStore() {
    this.client.call.addListener(_callChanged);
  }

  /// How long an ended call stays on screen: long enough to read how it ended.
  static const dismissAfter = Duration(seconds: 2);

  final VoiceClient client;
  final TokenProvider _tokens;
  final SettingsStore _store;

  Settings settings = const Settings();

  /// True from the tap on Call until the call is on its way or has failed: a second tap must not start another.
  bool isPlacing = false;

  /// The call on screen: the client's call, until it was dismissed after its end.
  Call? shownCall;

  /// When the call on screen was answered.
  DateTime? connectedAt;

  /// The latest statistics of the call on screen.
  CallStats? stats;

  /// Something to tell the user once; the screen shows it and clears it.
  String? alert;

  /// A command the SDK refused, shown on the call screen for a few seconds.
  String? lastError;

  Timer? _statsTimer;
  Timer? _dismissTimer;
  Timer? _errorTimer;

  Future<void> load() async {
    settings = await _store.load();
    notifyListeners();
  }

  Future<void> updateSettings(Settings value) async {
    settings = value;
    notifyListeners();
    await _store.save(value);
  }

  /// Entry point from the dialer: gets a token from the backend and hands it to the SDK.
  Future<void> placeCall(String number) async {
    number = number.trim();
    if (number.isEmpty || isPlacing) return;
    final problem = settings.problem;
    if (problem != null) return _alert(problem);
    if (client.call.value?.isActive == true) return _alert('A call is already active');
    isPlacing = true;
    notifyListeners();
    try {
      // The token carries the destination and the caller ID; a new one for every call.
      final token = await _tokens.token(settings, number);
      await client.connect(token);
    } on TokenException catch (e) {
      _alert(e.message);
    } on VoiceError catch (e) {
      // No call started at all; a call that fails later ends in `client.call` instead.
      if (e.code != 'cancelled') _alert('${e.code}: ${e.message}');
    } finally {
      isPlacing = false;
      notifyListeners();
    }
  }

  Future<void> hangup() => client.hangup();
  Future<void> toggleMute() => _command(() => client.setMuted(!(client.call.value?.isMuted ?? false)));
  Future<void> toggleHold() => _command(() => client.setOnHold(!(client.call.value?.isOnHold ?? false)));
  Future<void> sendDigit(String digit) => _command(() => client.sendDigits(digit));
  Future<void> selectRoute(AudioRoute route) => _command(() => client.selectAudioRoute(route));

  void clearAlert() => alert = null;

  Future<void> _command(Future<void> Function() command) async {
    try {
      await command();
    } on VoiceError catch (e) {
      lastError = '${e.code}: ${e.message}';
      _errorTimer?.cancel();
      _errorTimer = Timer(const Duration(seconds: 4), () {
        lastError = null;
        notifyListeners();
      });
      notifyListeners();
    }
  }

  void _alert(String text) {
    alert = text;
    notifyListeners();
  }

  /// Mirrors the client's call into what the screens show. States are read, not transitions: a snapshot may be
  /// skipped, the last one never is.
  void _callChanged() {
    final call = client.call.value;
    if (call == null) return;
    if (call.callId != shownCall?.callId || (call.isActive && shownCall?.isActive == false)) {
      // A new call.
      connectedAt = null;
      stats = null;
      lastError = null;
      _dismissTimer?.cancel();
    }
    shownCall = call;
    if (call.wasConnected && connectedAt == null && call.isActive) {
      connectedAt = DateTime.now();
      _statsTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => _refreshStats());
    }
    if (!call.isActive) {
      _statsTimer?.cancel();
      _statsTimer = null;
      _dismissTimer ??= Timer(dismissAfter, () {
        _dismissTimer = null;
        if (shownCall?.isActive == false) shownCall = null;
        notifyListeners();
      });
    }
    notifyListeners();
  }

  Future<void> _refreshStats() async {
    try {
      final value = await client.stats();
      if (value != null && shownCall?.isActive == true) {
        stats = value;
        notifyListeners();
      }
    } on VoiceError {
      // A failed sample is skipped; the next tick tries again.
    }
  }

  /// How a call ended, in words.
  static String describe(CallEndReason? reason, VoiceError? error) => switch (reason) {
    CallEndReason.busy => 'Busy',
    CallEndReason.noAnswer => 'No answer',
    CallEndReason.rejected => 'Rejected',
    CallEndReason.remoteHangup => 'Call ended by the other side',
    CallEndReason.localHangup => 'Call ended',
    CallEndReason.cancelled => 'Cancelled',
    CallEndReason.failed when error != null =>
      'Failed: ${error.code} (${error.message}${error.sipStatus == null ? '' : ', SIP ${error.sipStatus}'})',
    CallEndReason.failed => 'Failed',
    null => 'Call ended',
  };

  @override
  void dispose() {
    client.call.removeListener(_callChanged);
    _statsTimer?.cancel();
    _dismissTimer?.cancel();
    _errorTimer?.cancel();
    super.dispose();
  }
}
