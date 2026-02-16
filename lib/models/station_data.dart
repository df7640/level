/// 측점 데이터 모델
/// Python의 PandasModel을 Flutter로 변환
class StationData {
  final String no; // 측점 번호 (예: "NO.1", "NO.1+5", "NO.1+10")

  // CSV 원본 필드들
  final double? intervalDistance; // 점간거리
  final double? distance; // 누가거리
  final double? gh; // 지반고
  final double? deepestBedLevel; // 최심하상고
  final double? ip; // 계획하상고
  final double? plannedFloodLevel; // 계획홍수위
  final double? leftBankHeight; // 좌안제방고
  final double? rightBankHeight; // 우안제방고
  final double? plannedBankLeft; // 계획제방고_좌안
  final double? plannedBankRight; // 계획제방고_우안
  final double? roadbedLeft; // 노체_좌안
  final double? roadbedRight; // 노체_우안

  // 기존 필드들 (호환성 유지)
  final double? ghD; // GH-D
  final double? gh1; // GH-1
  final double? gh2; // GH-2
  final double? gh3; // GH-3
  final double? gh4; // GH-4
  final double? gh5; // GH-5
  final double? actualReading; // 읽은 값 (현장 측정)
  final double? targetReading; // 읽을 값 (계산된 목표값)
  final double? cutFill; // 절/성토 차이
  final String? cutFillStatus; // "CUT", "FILL", "ON_GRADE"

  // 좌표 (DXF에서 선택한 경우)
  final double? x;
  final double? y;

  // 메타데이터
  final bool isInterpolated; // 보간된 데이터인지 여부
  final DateTime? lastModified;

  StationData({
    required this.no,
    this.intervalDistance,
    this.distance,
    this.gh,
    this.deepestBedLevel,
    this.ip,
    this.plannedFloodLevel,
    this.leftBankHeight,
    this.rightBankHeight,
    this.plannedBankLeft,
    this.plannedBankRight,
    this.roadbedLeft,
    this.roadbedRight,
    this.ghD,
    this.gh1,
    this.gh2,
    this.gh3,
    this.gh4,
    this.gh5,
    this.actualReading,
    this.targetReading,
    this.cutFill,
    this.cutFillStatus,
    this.x,
    this.y,
    this.isInterpolated = false,
    this.lastModified,
  });

  /// 측점 번호에서 기본 번호와 플러스 거리 추출
  /// 예: "NO.1+5" -> (1, 5)
  (int, int?) get stationParts {
    final match = RegExp(r'NO\.(\d+)(?:\+(\d+))?').firstMatch(no);
    if (match == null) return (0, null);

    final baseNo = int.parse(match.group(1)!);
    final plus = match.group(2) != null ? int.parse(match.group(2)!) : null;
    return (baseNo, plus);
  }

  /// 기본 측점인지 확인 (플러스 체인이 없는 경우)
  bool get isBaseStation => !no.contains('+');

  /// 복사본 생성 (일부 필드 변경)
  StationData copyWith({
    String? no,
    double? distance,
    double? gh,
    double? ip,
    double? ghD,
    double? gh1,
    double? gh2,
    double? gh3,
    double? gh4,
    double? gh5,
    double? actualReading,
    double? targetReading,
    double? cutFill,
    String? cutFillStatus,
    double? x,
    double? y,
    bool? isInterpolated,
    DateTime? lastModified,
  }) {
    return StationData(
      no: no ?? this.no,
      distance: distance ?? this.distance,
      gh: gh ?? this.gh,
      ip: ip ?? this.ip,
      ghD: ghD ?? this.ghD,
      gh1: gh1 ?? this.gh1,
      gh2: gh2 ?? this.gh2,
      gh3: gh3 ?? this.gh3,
      gh4: gh4 ?? this.gh4,
      gh5: gh5 ?? this.gh5,
      actualReading: actualReading ?? this.actualReading,
      targetReading: targetReading ?? this.targetReading,
      cutFill: cutFill ?? this.cutFill,
      cutFillStatus: cutFillStatus ?? this.cutFillStatus,
      x: x ?? this.x,
      y: y ?? this.y,
      isInterpolated: isInterpolated ?? this.isInterpolated,
      lastModified: lastModified ?? this.lastModified,
    );
  }

  /// JSON으로 변환
  Map<String, dynamic> toJson() {
    return {
      'no': no,
      'distance': distance,
      'gh': gh,
      'ip': ip,
      'gh_d': ghD,
      'gh1': gh1,
      'gh2': gh2,
      'gh3': gh3,
      'gh4': gh4,
      'gh5': gh5,
      'actual_reading': actualReading,
      'target_reading': targetReading,
      'cut_fill': cutFill,
      'cut_fill_status': cutFillStatus,
      'x': x,
      'y': y,
      'is_interpolated': isInterpolated,
      'last_modified': lastModified?.toIso8601String(),
    };
  }

  /// JSON에서 생성
  factory StationData.fromJson(Map<String, dynamic> json) {
    return StationData(
      no: json['no'] as String,
      distance: json['distance'] as double?,
      gh: json['gh'] as double?,
      ip: json['ip'] as double?,
      ghD: json['gh_d'] as double?,
      gh1: json['gh1'] as double?,
      gh2: json['gh2'] as double?,
      gh3: json['gh3'] as double?,
      gh4: json['gh4'] as double?,
      gh5: json['gh5'] as double?,
      actualReading: json['actual_reading'] as double?,
      targetReading: json['target_reading'] as double?,
      cutFill: json['cut_fill'] as double?,
      cutFillStatus: json['cut_fill_status'] as String?,
      x: json['x'] as double?,
      y: json['y'] as double?,
      isInterpolated: json['is_interpolated'] as bool? ?? false,
      lastModified: json['last_modified'] != null
          ? DateTime.parse(json['last_modified'] as String)
          : null,
    );
  }

  /// CSV 행으로 변환
  List<String> toCsvRow() {
    return [
      no,
      distance?.toString() ?? '',
      gh?.toString() ?? '',
      ip?.toString() ?? '',
      ghD?.toString() ?? '',
      gh1?.toString() ?? '',
      gh2?.toString() ?? '',
      gh3?.toString() ?? '',
      gh4?.toString() ?? '',
      gh5?.toString() ?? '',
      x?.toString() ?? '',
      y?.toString() ?? '',
      actualReading?.toString() ?? '',
      targetReading?.toString() ?? '',
      cutFill?.toString() ?? '',
      cutFillStatus ?? '',
    ];
  }

  @override
  String toString() {
    return 'StationData(no: $no, distance: $distance, gh: $gh, interpolated: $isInterpolated)';
  }
}
