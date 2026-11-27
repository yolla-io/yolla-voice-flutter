//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import 'package:flutter/foundation.dart';

/// Why the SDK refused a command, or why a call failed.
///
/// The [code] is what an app acts on and what support asks for; the [message] is a description in English for the
/// log, not for the user. Codes the SDK itself raises are listed here as constants; a call that the network refused
/// has `sip_<status>` with [sipStatus] set, a refused platform request `http_<status>`, and the platform may add
/// codes of its own.
@immutable
class VoiceError implements Exception {
  const VoiceError(this.code, this.message, {this.sipStatus});

  final String code;
  final String message;

  /// The SIP status the network answered with, when that is what ended the call.
  final int? sipStatus;

  /// The call token cannot be read, has expired or was already used.
  static const invalidToken = 'invalid_token';

  /// The user has not allowed the microphone.
  static const microphoneDenied = 'microphone_denied';

  /// The client's call has not ended yet: one call at a time.
  static const callInProgress = 'call_in_progress';

  /// There is no call, or it is not in a state that allows the command.
  static const invalidCallState = 'invalid_call_state';

  /// This call cannot carry DTMF digits.
  static const dtmfUnavailable = 'dtmf_unavailable';

  /// The call's audio could not be set up.
  static const mediaFailed = 'media_failed';

  /// The call was lost and could not be restored in time.
  static const mediaTimeout = 'media_timeout';

  /// The platform could not be reached.
  static const networkError = 'network_error';

  /// The platform answered with something the SDK does not understand.
  static const protocolError = 'protocol_error';

  /// Nobody answered in time, or a request to the network was not answered.
  static const timeout = 'timeout';

  /// The system's call service (CallKit on iOS, Telecom on Android) did not take the call or a command.
  static const systemCallFailed = 'system_call_failed';

  /// Reconnection notices, see `CallState.reconnecting`: the network path changed.
  static const networkChanged = 'network_changed';

  /// Reconnection notice: the audio path was lost.
  static const iceFailed = 'ice_failed';

  /// Reconnection notice: the signalling connection was re-established.
  static const signalingReconnected = 'signaling_reconnected';

  @override
  bool operator ==(Object other) =>
      other is VoiceError && other.code == code && other.message == message && other.sipStatus == sipStatus;

  @override
  int get hashCode => Object.hash(code, message, sipStatus);

  @override
  String toString() => 'VoiceError($code: $message${sipStatus == null ? '' : ', SIP $sipStatus'})';
}
