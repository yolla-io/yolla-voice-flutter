//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//
// Part of the Yolla Voice example app; see the LICENSE file in the example's folder.
//

import 'package:material_ui/material_ui.dart';

import 'app_model.dart';
import 'keypad.dart';

class DialerScreen extends StatefulWidget {
  const DialerScreen({super.key, required this.model});
  final AppModel model;

  @override
  State<DialerScreen> createState() => _DialerScreenState();
}

class _DialerScreenState extends State<DialerScreen> {
  final _number = TextEditingController();

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  void _type(String key) {
    final text = _number.text;
    if (key != Keypad.backspace) {
      _number.text = text + key;
    } else if (text.isNotEmpty) {
      _number.text = text.substring(0, text.length - 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final problem = model.settings.problem;
    return ListenableBuilder(
      listenable: _number,
      builder: (context, _) {
        final canCall = problem == null && _number.text.trim().isNotEmpty && !model.isPlacing;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('number'),
                  controller: _number,
                  keyboardType: TextInputType.phone,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                  decoration: const InputDecoration(hintText: 'Phone number', border: InputBorder.none),
                ),
                const SizedBox(height: 8),
                Keypad(onKey: _type),
                if (problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text('Settings: $problem', style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const ValueKey('call'),
                    style: FilledButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.all(16)),
                    onPressed: canCall
                        ? () {
                            FocusScope.of(context).unfocus();
                            model.placeCall(_number.text);
                          }
                        : null,
                    icon: const Icon(Icons.call),
                    label: Text(model.isPlacing ? 'Calling…' : 'Call'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
