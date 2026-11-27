//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//
// Part of the Yolla Voice example app; see the LICENSE file in the example's folder.
//

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:yolla_voice/yolla_voice.dart';

import 'app_model.dart';
import 'keypad.dart';

/// The call on screen: its state, its controls and its quality.
class InCallScreen extends StatefulWidget {
  const InCallScreen({super.key, required this.model, required this.call});
  final AppModel model;
  final Call call;

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  bool _showKeypad = false;
  late final Timer _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    _ticker; // starts the clock of the call's duration
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  String get _status {
    final call = widget.call;
    return switch (call.state) {
      CallState.connecting => 'Connecting…',
      CallState.ringing => call.hasEarlyMedia ? 'Ringing (early media)' : 'Ringing…',
      CallState.connected => call.isOnHold ? 'On hold' : _duration,
      CallState.reconnecting => 'Reconnecting (${call.error?.code ?? '…'})…',
      CallState.disconnected => AppModel.describe(call.endReason, call.error),
    };
  }

  String get _duration {
    final start = widget.model.connectedAt;
    if (start == null) return 'Connected';
    final seconds = DateTime.now().difference(start).inSeconds;
    return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Color? _statusColor(ColorScheme colors) => switch (widget.call.state) {
    CallState.connected => Colors.green,
    CallState.reconnecting => Colors.orange,
    CallState.disconnected => colors.onSurfaceVariant,
    _ => null,
  };

  static String _statsLine(CallStats stats) {
    String value(double? number, String unit, int digits) =>
        number == null ? '–' : '${number.toStringAsFixed(digits)}$unit';
    return 'RTT ${value(stats.sampleRttMs, ' ms', 0)} · jitter ${value(stats.sampleJitterMs, ' ms', 0)} · '
        'loss ${value(stats.sampleLossPercent, '%', 1)} · MOS ${value(stats.sampleMos, '', 1)}'
        '${stats.candidateType == null ? '' : ' · ${stats.candidateType}'}';
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model, call = widget.call;
    final theme = Theme.of(context);
    final connected = call.state == CallState.connected;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const Spacer(),
              Text(call.to, style: theme.textTheme.headlineMedium),
              const SizedBox(height: 12),
              Text(
                _status,
                key: const ValueKey('status'),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(color: _statusColor(theme.colorScheme)),
              ),
              const SizedBox(height: 8),
              Text(call.callId, style: theme.textTheme.bodySmall),
              if (call.qualityWarnings.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 6,
                    children: [for (final warning in call.qualityWarnings) Chip(label: Text(warning.rawValue))],
                  ),
                ),
              if (model.stats != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_statsLine(model.stats!), style: theme.textTheme.bodySmall),
                ),
              if (model.lastError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(model.lastError!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              const Spacer(),
              if (_showKeypad)
                Keypad(showsBackspace: false, onKey: model.sendDigit)
              else
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Mute is local and works while the call is being set up; hold and digits need an answer.
                    _Control(
                      icon: call.isMuted ? Icons.mic_off : Icons.mic,
                      label: 'Mute',
                      active: call.isMuted,
                      onPressed: call.isActive ? model.toggleMute : null,
                    ),
                    _Control(
                      icon: Icons.pause,
                      label: 'Hold',
                      active: call.isOnHold,
                      onPressed: connected ? model.toggleHold : null,
                    ),
                    _AudioRouteControl(model: model, enabled: call.isActive),
                  ],
                ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _Control(
                    icon: Icons.dialpad,
                    label: 'Keypad',
                    active: _showKeypad,
                    onPressed: connected || _showKeypad ? () => setState(() => _showKeypad = !_showKeypad) : null,
                  ),
                  FloatingActionButton.large(
                    key: const ValueKey('hangup'),
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    shape: const CircleBorder(),
                    onPressed: call.isActive ? model.hangup : null,
                    child: const Icon(Icons.call_end),
                  ),
                  const SizedBox(width: 72),
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _Control extends StatelessWidget {
  const _Control({required this.icon, required this.label, required this.onPressed, this.active = false});
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 72,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        active
            ? IconButton.filled(onPressed: onPressed, icon: Icon(icon), tooltip: label)
            : IconButton.filledTonal(onPressed: onPressed, icon: Icon(icon), tooltip: label),
        Text(label, style: Theme.of(context).textTheme.bodySmall, overflow: TextOverflow.ellipsis),
      ],
    ),
  );
}

/// The audio route in use; a tap offers the others.
class _AudioRouteControl extends StatelessWidget {
  const _AudioRouteControl({required this.model, required this.enabled});
  final AppModel model;
  final bool enabled;

  static IconData _icon(AudioRouteKind? kind) => switch (kind) {
    AudioRouteKind.speaker => Icons.volume_up,
    AudioRouteKind.bluetooth => Icons.bluetooth_audio,
    AudioRouteKind.wired => Icons.headset,
    _ => Icons.phone_in_talk,
  };

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<AudioRoutes>(
    valueListenable: model.client.audioRoutes,
    builder: (context, routes, _) => _Control(
      icon: _icon(routes.current?.kind),
      label: routes.current?.name ?? 'Audio',
      active: routes.current?.kind == AudioRouteKind.speaker,
      onPressed: !enabled || routes.available.isEmpty
          ? null
          : () => showModalBottomSheet<void>(
              context: context,
              builder: (sheet) => SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final route in routes.available)
                      ListTile(
                        leading: Icon(_icon(route.kind)),
                        title: Text(route.name),
                        trailing: route == routes.current ? const Icon(Icons.check) : null,
                        onTap: () {
                          Navigator.pop(sheet);
                          model.selectRoute(route);
                        },
                      ),
                  ],
                ),
              ),
            ),
    ),
  );
}
