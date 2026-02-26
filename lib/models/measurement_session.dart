/// 측량 세션 모델
/// 하루의 측량 작업을 하나의 세션으로 관리
class MeasurementSession {
  final int? id;
  final int projectId;
  final String name; // "2026-02-19 NO.0~NO.5" 형태
  final double? ih; // 기계고
  final String? planLevelColumn; // 사용한 계획고 컬럼
  final DateTime createdAt;
  final DateTime lastModified;
  final int recordCount; // 측량 기록 수

  MeasurementSession({
    this.id,
    required this.projectId,
    required this.name,
    this.ih,
    this.planLevelColumn,
    required this.createdAt,
    required this.lastModified,
    this.recordCount = 0,
  });
}

/// 측량 기록 (세션 내 개별 측정)
class MeasurementRecord {
  final int? id;
  final int sessionId;
  final String stationNo;
  final double? ih; // 이 측정 시점의 기계고
  final String? planLevelColumn; // 이 측정 시점의 계획고 컬럼
  final double? targetReading;
  final double? actualReading;
  final double? cutFill;
  final String? cutFillStatus;
  final DateTime measuredAt;

  MeasurementRecord({
    this.id,
    required this.sessionId,
    required this.stationNo,
    this.ih,
    this.planLevelColumn,
    this.targetReading,
    this.actualReading,
    this.cutFill,
    this.cutFillStatus,
    required this.measuredAt,
  });
}
