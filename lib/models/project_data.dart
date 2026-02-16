import 'station_data.dart';

/// 프로젝트 전체 데이터 모델
class ProjectData {
  final String? filePath; // Excel 파일 경로
  final String? projectName; // 프로젝트 이름
  final List<StationData> stations; // 모든 측점 데이터
  final DateTime? lastSaved; // 마지막 저장 시간
  final ProjectSettings settings; // 프로젝트 설정

  ProjectData({
    this.filePath,
    this.projectName,
    required this.stations,
    this.lastSaved,
    ProjectSettings? settings,
  }) : settings = settings ?? ProjectSettings();

  /// 특정 측점 번호로 데이터 찾기
  StationData? getStation(String no) {
    try {
      return stations.firstWhere((s) => s.no == no);
    } catch (e) {
      return null;
    }
  }

  /// 기본 측점만 필터링 (플러스 체인 제외)
  List<StationData> get baseStations {
    return stations.where((s) => s.isBaseStation).toList();
  }

  /// 보간된 데이터만 필터링
  List<StationData> get interpolatedStations {
    return stations.where((s) => s.isInterpolated).toList();
  }

  /// 측점 범위 필터링
  List<StationData> getStationsInRange(int startNo, int endNo) {
    return stations.where((s) {
      final (baseNo, _) = s.stationParts;
      return baseNo >= startNo && baseNo <= endNo;
    }).toList();
  }

  /// 측점 추가/업데이트
  ProjectData updateStation(StationData station) {
    final index = stations.indexWhere((s) => s.no == station.no);
    final List<StationData> newStations = List.from(stations);

    if (index >= 0) {
      newStations[index] = station;
    } else {
      newStations.add(station);
    }

    return copyWith(
      stations: newStations,
      lastSaved: DateTime.now(),
    );
  }

  /// 복사본 생성
  ProjectData copyWith({
    String? filePath,
    String? projectName,
    List<StationData>? stations,
    DateTime? lastSaved,
    ProjectSettings? settings,
  }) {
    return ProjectData(
      filePath: filePath ?? this.filePath,
      projectName: projectName ?? this.projectName,
      stations: stations ?? this.stations,
      lastSaved: lastSaved ?? this.lastSaved,
      settings: settings ?? this.settings,
    );
  }

  /// JSON으로 변환
  Map<String, dynamic> toJson() {
    return {
      'file_path': filePath,
      'project_name': projectName,
      'stations': stations.map((s) => s.toJson()).toList(),
      'last_saved': lastSaved?.toIso8601String(),
      'settings': settings.toJson(),
    };
  }

  /// JSON에서 생성
  factory ProjectData.fromJson(Map<String, dynamic> json) {
    return ProjectData(
      filePath: json['file_path'] as String?,
      projectName: json['project_name'] as String?,
      stations: (json['stations'] as List<dynamic>)
          .map((s) => StationData.fromJson(s as Map<String, dynamic>))
          .toList(),
      lastSaved: json['last_saved'] != null
          ? DateTime.parse(json['last_saved'] as String)
          : null,
      settings: json['settings'] != null
          ? ProjectSettings.fromJson(json['settings'] as Map<String, dynamic>)
          : ProjectSettings(),
    );
  }

  /// 빈 프로젝트 생성
  factory ProjectData.empty() {
    return ProjectData(stations: []);
  }
}

/// 프로젝트 설정
class ProjectSettings {
  final List<int> plusChainDistances; // 플러스 체인 거리 (예: [5, 10, 15])
  final String defaultPlanLevelColumn; // 기본 계획고 컬럼 (예: "GH")
  final double cutFillTolerance; // 절/성토 허용오차 (미터)
  final bool autoInterpolate; // 자동 보간 여부
  final Map<String, bool> visibleColumns; // 표시할 컬럼

  ProjectSettings({
    List<int>? plusChainDistances,
    this.defaultPlanLevelColumn = 'GH',
    this.cutFillTolerance = 0.0005, // 0.5mm
    this.autoInterpolate = true,
    Map<String, bool>? visibleColumns,
  })  : plusChainDistances = plusChainDistances ?? [5, 10, 15],
        visibleColumns = visibleColumns ?? _defaultVisibleColumns();

  static Map<String, bool> _defaultVisibleColumns() {
    return {
      'NO': true,
      '누가거리': true,
      'GH': true,
      'IP': true,
      'GH-D': true,
      'GH-1': false,
      'GH-2': false,
      'GH-3': false,
      'GH-4': false,
      'GH-5': false,
      'X': true,
      'Y': true,
      '읽을 값': true,
      '읽은 값': true,
      '절/성토': true,
    };
  }

  /// JSON으로 변환
  Map<String, dynamic> toJson() {
    return {
      'plus_chain_distances': plusChainDistances,
      'default_plan_level_column': defaultPlanLevelColumn,
      'cut_fill_tolerance': cutFillTolerance,
      'auto_interpolate': autoInterpolate,
      'visible_columns': visibleColumns,
    };
  }

  /// JSON에서 생성
  factory ProjectSettings.fromJson(Map<String, dynamic> json) {
    return ProjectSettings(
      plusChainDistances: (json['plus_chain_distances'] as List<dynamic>?)
              ?.map((e) => e as int)
              .toList() ??
          [5, 10, 15],
      defaultPlanLevelColumn:
          json['default_plan_level_column'] as String? ?? 'GH',
      cutFillTolerance: json['cut_fill_tolerance'] as double? ?? 0.0005,
      autoInterpolate: json['auto_interpolate'] as bool? ?? true,
      visibleColumns: (json['visible_columns'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as bool)) ??
          _defaultVisibleColumns(),
    );
  }

  /// 복사본 생성
  ProjectSettings copyWith({
    List<int>? plusChainDistances,
    String? defaultPlanLevelColumn,
    double? cutFillTolerance,
    bool? autoInterpolate,
    Map<String, bool>? visibleColumns,
  }) {
    return ProjectSettings(
      plusChainDistances: plusChainDistances ?? this.plusChainDistances,
      defaultPlanLevelColumn:
          defaultPlanLevelColumn ?? this.defaultPlanLevelColumn,
      cutFillTolerance: cutFillTolerance ?? this.cutFillTolerance,
      autoInterpolate: autoInterpolate ?? this.autoInterpolate,
      visibleColumns: visibleColumns ?? this.visibleColumns,
    );
  }
}
