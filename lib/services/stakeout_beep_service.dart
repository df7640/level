import 'dart:async';
import 'package:flutter/services.dart';

enum _BeepMode { off, slow, fast }

/// 측설 비프음 서비스
/// Android ToneGenerator를 통해 거리 기반 비프음 제공
class StakeoutBeepService {
  static const _channel = MethodChannel('com.ysc.engineering/tone');
  Timer? _beepTimer;
  _BeepMode _currentMode = _BeepMode.off;

  void _playBeep({int durationMs = 80}) {
    try {
      _channel.invokeMethod('playBeep', {'durationMs': durationMs});
    } catch (_) {}
  }

  /// 거리에 따라 비프 모드 변경
  /// - > 10cm: 무음
  /// - 3cm ~ 10cm: 간헐적 (500ms 간격)
  /// - < 3cm: 연속 (120ms 간격)
  void updateForDistance(double distanceMeters) {
    _BeepMode newMode;
    if (distanceMeters > 0.10) {
      newMode = _BeepMode.off;
    } else if (distanceMeters > 0.03) {
      newMode = _BeepMode.slow;
    } else {
      newMode = _BeepMode.fast;
    }

    if (newMode == _currentMode) return;
    _currentMode = newMode;
    _beepTimer?.cancel();
    _beepTimer = null;

    switch (newMode) {
      case _BeepMode.off:
        break;
      case _BeepMode.slow:
        _playBeep(durationMs: 100);
        _beepTimer = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => _playBeep(durationMs: 100),
        );
        break;
      case _BeepMode.fast:
        _playBeep(durationMs: 50);
        _beepTimer = Timer.periodic(
          const Duration(milliseconds: 120),
          (_) => _playBeep(durationMs: 50),
        );
        break;
    }
  }

  void stop() {
    _beepTimer?.cancel();
    _beepTimer = null;
    _currentMode = _BeepMode.off;
  }

  void dispose() {
    stop();
  }
}
