import 'dart:math';

/// 측량 품질 검증 서비스 (LandStar IQualityController 참조)
/// PDOP/DiffAge/위성수 기반 측점 품질 필터링 + 경고
class SurveyQualityService {
  // 품질 기준값 (LandStar 기본값 기반)
  double pdopLimit = 6.0;
  double diffAgeLimit = 30.0; // 초
  int minSatellites = 5;
  double movementThreshold2d = 0.05; // m (2D 이동 감지)

  /// 품질 검사 결과
  QualityCheckResult checkQuality({
    required int fixQuality,
    double? pdop,
    double? diffAge,
    int satellites = 0,
  }) {
    final warnings = <QualityWarning>[];

    // Fix 상태 검사
    if (fixQuality < 4) {
      warnings.add(QualityWarning(
        type: QualityWarningType.noRtkFix,
        message: fixQuality == 5
            ? 'Float 상태 - RTK Fix 대기중'
            : fixQuality == 2
                ? 'DGPS - 정밀도 부족'
                : fixQuality == 1
                    ? '단독측위 - 정밀도 부족'
                    : '위성 탐색중',
        severity: fixQuality == 5
            ? WarningSeverity.warning
            : WarningSeverity.critical,
      ));
    }

    // PDOP 검사
    if (pdop != null && pdop > pdopLimit) {
      warnings.add(QualityWarning(
        type: QualityWarningType.pdopExceeded,
        message: 'PDOP ${pdop.toStringAsFixed(1)} > 제한값 ${pdopLimit.toStringAsFixed(1)}',
        severity: pdop > pdopLimit * 1.5
            ? WarningSeverity.critical
            : WarningSeverity.warning,
      ));
    }

    // DiffAge 검사
    if (diffAge != null && diffAge > diffAgeLimit) {
      warnings.add(QualityWarning(
        type: QualityWarningType.diffAgeExceeded,
        message: '보정나이 ${diffAge.toStringAsFixed(0)}초 > 제한값 ${diffAgeLimit.toStringAsFixed(0)}초',
        severity: diffAge > diffAgeLimit * 2
            ? WarningSeverity.critical
            : WarningSeverity.warning,
      ));
    }

    // 위성수 검사
    if (satellites < minSatellites) {
      warnings.add(QualityWarning(
        type: QualityWarningType.lowSatellites,
        message: '위성 ${satellites}개 < 최소 ${minSatellites}개',
        severity: satellites < 4
            ? WarningSeverity.critical
            : WarningSeverity.warning,
      ));
    }

    return QualityCheckResult(
      isAcceptable: warnings.every((w) => w.severity != WarningSeverity.critical),
      warnings: warnings,
    );
  }

  /// 측설 가능 여부 (critical 경고 없을 때만 허용)
  bool canStakeout({
    required int fixQuality,
    double? pdop,
    double? diffAge,
    int satellites = 0,
  }) {
    return checkQuality(
      fixQuality: fixQuality,
      pdop: pdop,
      diffAge: diffAge,
      satellites: satellites,
    ).isAcceptable;
  }
}

/// 다중 에폭 평균 계산기 (LandStar ObsCollector + PointAveragingMethod 참조)
class EpochAverager {
  final List<_EpochData> _epochs = [];
  int targetEpochs;

  EpochAverager({this.targetEpochs = 10});

  int get collectedCount => _epochs.length;
  bool get isComplete => _epochs.length >= targetEpochs;
  double get progress => targetEpochs > 0 ? _epochs.length / targetEpochs : 0.0;

  /// 에폭 추가
  void addEpoch({
    required double n,
    required double e,
    required double h,
    required int fixQuality,
    double? pdop,
  }) {
    _epochs.add(_EpochData(n: n, e: e, h: h, fixQuality: fixQuality, pdop: pdop));
  }

  /// 초기화
  void reset() => _epochs.clear();

  /// 평균 결과 계산
  AverageResult? compute() {
    if (_epochs.isEmpty) return null;

    final count = _epochs.length;
    double sumN = 0, sumE = 0, sumH = 0;
    for (final ep in _epochs) {
      sumN += ep.n;
      sumE += ep.e;
      sumH += ep.h;
    }
    final avgN = sumN / count;
    final avgE = sumE / count;
    final avgH = sumH / count;

    // RMS 계산
    double sum2d = 0, sum3d = 0;
    for (final ep in _epochs) {
      final dn = ep.n - avgN;
      final de = ep.e - avgE;
      final dh = ep.h - avgH;
      sum2d += dn * dn + de * de;
      sum3d += dn * dn + de * de + dh * dh;
    }
    final rms2d = sqrt(sum2d / count);
    final rms3d = sqrt(sum3d / count);

    return AverageResult(
      n: avgN,
      e: avgE,
      h: avgH,
      rms2d: rms2d,
      rms3d: rms3d,
      epochCount: count,
    );
  }
}

class _EpochData {
  final double n, e, h;
  final int fixQuality;
  final double? pdop;
  _EpochData({required this.n, required this.e, required this.h, required this.fixQuality, this.pdop});
}

/// 평균 결과
class AverageResult {
  final double n, e, h;
  final double rms2d, rms3d;
  final int epochCount;

  const AverageResult({
    required this.n, required this.e, required this.h,
    required this.rms2d, required this.rms3d,
    required this.epochCount,
  });
}

/// FBLR (전후좌우) 내비게이션 계산기 (LandStar PointNavigation 참조)
class StakeoutNavigation {
  // 이동방향 예측용 좌표 이력
  final List<({double n, double e, DateTime time})> _posHistory = [];
  static const int _historySize = 5;

  /// 이동방향 방위각 (라디안). null이면 방향 불명
  double? _movingAzimuth;
  double? get movingAzimuth => _movingAzimuth;

  /// 이동 상태
  MovementState movementState = MovementState.unknown;

  /// 위치 업데이트 → 이동방향 예측
  void updatePosition(double n, double e) {
    final now = DateTime.now();
    _posHistory.add((n: n, e: e, time: now));
    if (_posHistory.length > _historySize) {
      _posHistory.removeAt(0);
    }
    _predictMovement();
  }

  void _predictMovement() {
    if (_posHistory.length < 2) {
      movementState = MovementState.unknown;
      return;
    }

    final first = _posHistory.first;
    final last = _posHistory.last;
    final dn = last.n - first.n;
    final de = last.e - first.e;
    final dist = sqrt(dn * dn + de * de);
    final dt = last.time.difference(first.time).inMilliseconds / 1000.0;

    if (dt < 0.1) return;

    final speed = dist / dt; // m/s

    if (speed < 0.05) {
      movementState = MovementState.stopped;
      // 정지 시 방위각 유지
      return;
    }

    final newAzimuth = atan2(de, dn); // 북기준 시계방향

    if (_movingAzimuth != null) {
      var angleDiff = (newAzimuth - _movingAzimuth!).abs();
      if (angleDiff > pi) angleDiff = 2 * pi - angleDiff;

      if (angleDiff > pi / 4) {
        movementState = MovementState.quickTurn;
      } else if (angleDiff > pi / 12) {
        movementState = MovementState.slowTurn;
      } else {
        movementState = MovementState.linear;
      }
    } else {
      movementState = MovementState.linear;
    }

    _movingAzimuth = newAzimuth;
  }

  /// FBLR 계산: 이동방향 기준 전후좌우 분해
  /// azimuth가 없으면 절대 방향(N/S E/W) 그대로
  ({double forward, double right, double distance2d, double azimuthToTarget})?
  calcFBLR({required double currentN, required double currentE,
            required double targetN, required double targetE}) {
    final dn = targetN - currentN;
    final de = targetE - currentE;
    final dist = sqrt(dn * dn + de * de);
    final azToTarget = atan2(de, dn);

    if (_movingAzimuth == null) return null;

    // 전진방향 기준 분해
    final relAngle = azToTarget - _movingAzimuth!;
    final forward = dist * cos(relAngle);
    final right = dist * sin(relAngle);

    return (
      forward: forward,
      right: right,
      distance2d: dist,
      azimuthToTarget: azToTarget,
    );
  }

  /// 방위각 (라디안 → 도°분'초")
  static String formatAzimuth(double radians) {
    var deg = radians * 180.0 / pi;
    if (deg < 0) deg += 360;
    final d = deg.floor();
    final mf = (deg - d) * 60;
    final m = mf.floor();
    final s = (mf - m) * 60;
    return '$d°${m.toString().padLeft(2, '0')}\'${s.toStringAsFixed(0).padLeft(2, '0')}"';
  }

  void reset() {
    _posHistory.clear();
    _movingAzimuth = null;
    movementState = MovementState.unknown;
  }
}

/// 이동 상태 (LandStar MovDirPredictor 참조)
enum MovementState { unknown, stopped, linear, slowTurn, quickTurn }

/// 측설 기록 데이터
class StakeoutRecord {
  final String pointName;
  final double designN, designE;
  final double? designH;
  final double measuredN, measuredE, measuredH;
  final double deltaN, deltaE, deltaH;
  final double distance2d, distance3d;
  final int fixQuality;
  final double? pdop;
  final double antennaHeight;
  final DateTime measuredAt;

  StakeoutRecord({
    required this.pointName,
    required this.designN,
    required this.designE,
    this.designH,
    required this.measuredN,
    required this.measuredE,
    required this.measuredH,
    required this.deltaN,
    required this.deltaE,
    required this.deltaH,
    required this.distance2d,
    required this.distance3d,
    required this.fixQuality,
    this.pdop,
    required this.antennaHeight,
    required this.measuredAt,
  });
}

// ==================== 안테나 높이 변환 ====================

/// 안테나 높이 입력 타입
enum AntennaHeightType { vertical, slant }

/// 경사 높이 → 수직 높이 변환 (LandStar BaseParams 참조)
/// slantHeight: 경사 높이
/// antennaRadius: 안테나 수평 반경 (m) — 기종별 다름
double slantToVertical(double slantHeight, double antennaRadius) {
  if (slantHeight <= antennaRadius) return 0.0;
  return sqrt(slantHeight * slantHeight - antennaRadius * antennaRadius);
}

/// 수직 높이 → 경사 높이 변환
double verticalToSlant(double verticalHeight, double antennaRadius) {
  return sqrt(verticalHeight * verticalHeight + antennaRadius * antennaRadius);
}

// ==================== 품질 관련 모델 ====================

enum QualityWarningType { pdopExceeded, diffAgeExceeded, lowSatellites, noRtkFix, movementDetected }
enum WarningSeverity { info, warning, critical }

class QualityWarning {
  final QualityWarningType type;
  final String message;
  final WarningSeverity severity;

  const QualityWarning({required this.type, required this.message, required this.severity});
}

class QualityCheckResult {
  final bool isAcceptable;
  final List<QualityWarning> warnings;

  const QualityCheckResult({required this.isAcceptable, required this.warnings});

  bool get hasCritical => warnings.any((w) => w.severity == WarningSeverity.critical);
  bool get hasWarning => warnings.any((w) => w.severity == WarningSeverity.warning);
  String get summaryMessage => warnings.isEmpty ? '' : warnings.first.message;
}
