import '../models/station_data.dart';

/// 레벨 계산 서비스
/// 측량 계산: IH, 목표값, 절/성토 판정
class LevelCalculationService {
  /// 읽을 값(목표값) 계산
  /// 공식: 읽을 값 = IH - 계획고
  ///
  /// [ih] 기계고 (Instrument Height)
  /// [planLevel] 계획고 (Plan Level)
  static double? calculateTargetReading(double? ih, double? planLevel) {
    if (ih == null || planLevel == null) return null;
    return ih - planLevel;
  }

  /// 절/성토 차이 계산
  /// 공식: 차이 = 읽을 값 - 읽은 값
  ///
  /// [targetReading] 읽을 값 (계산된 목표값)
  /// [actualReading] 읽은 값 (현장 측정값)
  static double? calculateCutFill(double? targetReading, double? actualReading) {
    if (targetReading == null || actualReading == null) return null;
    return targetReading - actualReading;
  }

  /// 절/성토 상태 판정
  /// - CUT (절토): 차이 > 0.0005 (0.5mm 이상)
  /// - FILL (성토): 차이 < -0.0005 (-0.5mm 이하)
  /// - ON_GRADE (계획고): -0.5mm ~ +0.5mm 범위
  ///
  /// [cutFill] 절/성토 차이
  /// [tolerance] 허용 오차 (기본 0.5mm = 0.0005m)
  static String? determineCutFillStatus(
    double? cutFill, {
    double tolerance = 0.0005,
  }) {
    if (cutFill == null) return null;

    if (cutFill > tolerance) {
      return 'CUT'; // 절토 (파내야 함)
    } else if (cutFill < -tolerance) {
      return 'FILL'; // 성토 (쌓아야 함)
    } else {
      return 'ON_GRADE'; // 계획고 맞음
    }
  }

  /// 측점 데이터에 레벨 계산 적용
  /// IH와 계획고 컬럼을 사용하여 목표값과 절/성토 계산
  ///
  /// [station] 측점 데이터
  /// [ih] 기계고
  /// [planLevelColumn] 계획고 컬럼 ('GH', 'IP', 'GH-D' 등)
  /// [tolerance] 허용 오차
  static StationData applyLevelCalculation(
    StationData station,
    double ih,
    String planLevelColumn, {
    double tolerance = 0.0005,
  }) {
    // 계획고 값 가져오기
    final double? planLevel = _getPlanLevel(station, planLevelColumn);
    if (planLevel == null) return station;

    // 읽을 값 계산
    final targetReading = calculateTargetReading(ih, planLevel);

    // 읽은 값이 있으면 절/성토 계산
    double? cutFill;
    String? cutFillStatus;

    if (station.actualReading != null && targetReading != null) {
      cutFill = calculateCutFill(targetReading, station.actualReading);
      cutFillStatus = determineCutFillStatus(cutFill, tolerance: tolerance);
    }

    return station.copyWith(
      targetReading: targetReading,
      cutFill: cutFill,
      cutFillStatus: cutFillStatus,
      lastModified: DateTime.now(),
    );
  }

  /// 여러 측점에 일괄 레벨 계산 적용
  static List<StationData> applyLevelCalculationToAll(
    List<StationData> stations,
    double ih,
    String planLevelColumn, {
    double tolerance = 0.0005,
  }) {
    return stations
        .map((s) => applyLevelCalculation(
              s,
              ih,
              planLevelColumn,
              tolerance: tolerance,
            ))
        .toList();
  }

  /// 계획고 컬럼에서 값 추출
  static double? _getPlanLevel(StationData station, String column) {
    switch (column) {
      case 'GH':
        return station.gh;
      case 'IP':
        return station.ip;
      case 'GH-D':
        return station.ghD;
      case 'GH-1':
        return station.gh1;
      case 'GH-2':
        return station.gh2;
      case 'GH-3':
        return station.gh3;
      case 'GH-4':
        return station.gh4;
      case 'GH-5':
        return station.gh5;
      default:
        return station.gh; // 기본값
    }
  }

  /// 절/성토 통계 계산
  static Map<String, dynamic> calculateStatistics(List<StationData> stations) {
    int cutCount = 0;
    int fillCount = 0;
    int onGradeCount = 0;
    double totalCut = 0.0;
    double totalFill = 0.0;

    for (final station in stations) {
      if (station.cutFillStatus == null || station.cutFill == null) continue;

      switch (station.cutFillStatus) {
        case 'CUT':
          cutCount++;
          totalCut += station.cutFill!;
          break;
        case 'FILL':
          fillCount++;
          totalFill += station.cutFill!.abs();
          break;
        case 'ON_GRADE':
          onGradeCount++;
          break;
      }
    }

    return {
      'cut_count': cutCount,
      'fill_count': fillCount,
      'on_grade_count': onGradeCount,
      'total_cut': totalCut,
      'total_fill': totalFill,
      'average_cut': cutCount > 0 ? totalCut / cutCount : 0.0,
      'average_fill': fillCount > 0 ? totalFill / fillCount : 0.0,
    };
  }
}
