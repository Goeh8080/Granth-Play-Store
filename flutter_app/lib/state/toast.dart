import 'dart:async';

import 'package:flutter/foundation.dart';

/// `pe()` — the bottom toast (2.4 s).
class Toast {
  Toast._();
  static final ValueNotifier<String?> message = ValueNotifier(null);
  static Timer? _t;
  static int _serial = 0;
  static int get serial => _serial;

  static void show(String text) {
    _serial++;
    message.value = text;
    _t?.cancel();
    _t = Timer(const Duration(milliseconds: 2400), () => message.value = null);
  }
}
