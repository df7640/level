import 'package:flutter/services.dart';

/// 사운드 재생 서비스 (네이티브 SoundPool 사용)
/// LandStar 사운드 파일 기반: 연결/RTK/RTCM/측설 알람
class SoundService {
  static const _channel = MethodChannel('com.ysc.engineering/tone');

  /// 사운드 이름으로 재생
  /// 이름은 Android res/raw 파일명 (확장자 제외)
  static Future<void> play(String name, {double volume = 1.0}) async {
    try {
      await _channel.invokeMethod('playSound', {
        'name': name,
        'volume': volume,
      });
    } catch (_) {}
  }

  // === 편의 메서드 ===

  /// BT 연결 성공
  static Future<void> connectionSuccess() => play('connection_success');

  /// BT 연결 끊김
  static Future<void> connectionLost() => play('connection_lost');

  /// RTK Fixed 획득
  static Future<void> rtcFixed() => play('type_fixed');

  /// RTK Fixed 음성 ("Fixed")
  static Future<void> rtcFixedVoice() => play('type_fixed_voice');

  /// RTK Float
  static Future<void> rtcFloat() => play('type_float');

  /// RTK Float 음성 ("Float")
  static Future<void> rtcFloatVoice() => play('type_float_voice');

  /// RTCM 보정데이터 수신 중
  static Future<void> receivingCorrectionData() => play('receiving_correcting_data');

  /// 측설 알람 - 원거리 (0.5m ~ 1.0m)
  static Future<void> stakeoutAlarmLow() => play('stakeout_warning_alarm_low');

  /// 측설 알람 - 중거리 (0.05m ~ 0.5m)
  static Future<void> stakeoutAlarmMid() => play('stakeout_warning_alarm_mid');

  /// 측설 알람 - 밀접 (< 0.05m)
  static Future<void> stakeoutAlarmHigh() => play('stakeout_warning_alarm_high');
}
