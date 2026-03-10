import '../models/station_data.dart';

/// 보간 서비스
/// 기본측점 구간(20m)을 5m 간격으로 보간
/// 원본 플러스체인이 있으면 보간 기준점으로 활용
class InterpolationService {
  /// 선형 보간 수행
  /// 두 값 사이를 선형적으로 보간
  static double? linearInterpolate({
    required double? v1,
    required double? v2,
    required double d1,
    required double d2,
    required double targetDist,
  }) {
    if (v1 == null || v2 == null) return null;
    if (d1 == d2) return v1;
    final ratio = (targetDist - d1) / (d2 - d1);
    return v1 + (v2 - v1) * ratio;
  }

  /// 두 앵커 포인트 사이에서 보간된 StationData 생성
  static StationData _interpolateStation({
    required StationData from,
    required StationData to,
    required double targetDist,
    required String name,
  }) {
    final d1 = from.distance!;
    final d2 = to.distance!;

    return StationData(
      no: name,
      distance: targetDist,
      intervalDistance: null,
      gh: linearInterpolate(v1: from.gh, v2: to.gh, d1: d1, d2: d2, targetDist: targetDist),
      deepestBedLevel: linearInterpolate(v1: from.deepestBedLevel, v2: to.deepestBedLevel, d1: d1, d2: d2, targetDist: targetDist),
      ip: linearInterpolate(v1: from.ip, v2: to.ip, d1: d1, d2: d2, targetDist: targetDist),
      plannedFloodLevel: linearInterpolate(v1: from.plannedFloodLevel, v2: to.plannedFloodLevel, d1: d1, d2: d2, targetDist: targetDist),
      leftBankHeight: linearInterpolate(v1: from.leftBankHeight, v2: to.leftBankHeight, d1: d1, d2: d2, targetDist: targetDist),
      rightBankHeight: linearInterpolate(v1: from.rightBankHeight, v2: to.rightBankHeight, d1: d1, d2: d2, targetDist: targetDist),
      plannedBankLeft: linearInterpolate(v1: from.plannedBankLeft, v2: to.plannedBankLeft, d1: d1, d2: d2, targetDist: targetDist),
      plannedBankRight: linearInterpolate(v1: from.plannedBankRight, v2: to.plannedBankRight, d1: d1, d2: d2, targetDist: targetDist),
      roadbedLeft: linearInterpolate(v1: from.roadbedLeft, v2: to.roadbedLeft, d1: d1, d2: d2, targetDist: targetDist),
      roadbedRight: linearInterpolate(v1: from.roadbedRight, v2: to.roadbedRight, d1: d1, d2: d2, targetDist: targetDist),
      foundationLevel: linearInterpolate(v1: from.foundationLevel, v2: to.foundationLevel, d1: d1, d2: d2, targetDist: targetDist),
      offsetLeft: linearInterpolate(v1: from.offsetLeft, v2: to.offsetLeft, d1: d1, d2: d2, targetDist: targetDist),
      offsetRight: linearInterpolate(v1: from.offsetRight, v2: to.offsetRight, d1: d1, d2: d2, targetDist: targetDist),
      height: linearInterpolate(v1: from.height, v2: to.height, d1: d1, d2: d2, targetDist: targetDist),
      singleCount: linearInterpolate(v1: from.singleCount, v2: to.singleCount, d1: d1, d2: d2, targetDist: targetDist),
      slope: linearInterpolate(v1: from.slope, v2: to.slope, d1: d1, d2: d2, targetDist: targetDist),
      angle: linearInterpolate(v1: from.angle, v2: to.angle, d1: d1, d2: d2, targetDist: targetDist),
      excavationDepth: linearInterpolate(v1: from.excavationDepth, v2: to.excavationDepth, d1: d1, d2: d2, targetDist: targetDist),
      ghD: linearInterpolate(v1: from.ghD, v2: to.ghD, d1: d1, d2: d2, targetDist: targetDist),
      gh1: linearInterpolate(v1: from.gh1, v2: to.gh1, d1: d1, d2: d2, targetDist: targetDist),
      gh2: linearInterpolate(v1: from.gh2, v2: to.gh2, d1: d1, d2: d2, targetDist: targetDist),
      gh3: linearInterpolate(v1: from.gh3, v2: to.gh3, d1: d1, d2: d2, targetDist: targetDist),
      gh4: linearInterpolate(v1: from.gh4, v2: to.gh4, d1: d1, d2: d2, targetDist: targetDist),
      gh5: linearInterpolate(v1: from.gh5, v2: to.gh5, d1: d1, d2: d2, targetDist: targetDist),
      x: linearInterpolate(v1: from.x, v2: to.x, d1: d1, d2: d2, targetDist: targetDist),
      y: linearInterpolate(v1: from.y, v2: to.y, d1: d1, d2: d2, targetDist: targetDist),
      isInterpolated: true,
      lastModified: DateTime.now(),
    );
  }

  /// 전체 측점에 대해 보간 수행
  ///
  /// [allStations]: 기본측점 + 원본 플러스체인 (거리순 정렬)
  /// [interval]: 보간 간격 (기본 5m)
  ///
  /// 로직:
  /// 1. 인접 기본측점 구간마다 처리
  /// 2. 해당 구간의 원본 플러스체인을 앵커 포인트로 포함
  /// 3. 5m 간격 중 원본에 없는 것만 보간 생성
  /// 4. 보간 시 가장 가까운 앵커 포인트 사이에서 선형 보간
  static List<StationData> interpolateAllStations({
    required List<StationData> allStations,
    required int interval, // 5, 10, 15, 20
    bool includeOriginalPlus = true,
  }) {
    final List<StationData> result = [];

    // 거리순 정렬
    final sorted = allStations.where((s) => s.distance != null).toList()
      ..sort((a, b) => a.distance!.compareTo(b.distance!));

    if (sorted.isEmpty) return result;

    // 기본측점 인덱스 찾기
    final baseIndices = <int>[];
    for (int i = 0; i < sorted.length; i++) {
      if (sorted[i].isBaseStation) {
        baseIndices.add(i);
      }
    }

    if (baseIndices.length < 2) {
      // 기본측점이 1개 이하면 보간 불가, 원본 그대로 반환
      return sorted;
    }

    // 인접 기본측점 구간마다 처리
    for (int bi = 0; bi < baseIndices.length - 1; bi++) {
      final startIdx = baseIndices[bi];
      final endIdx = baseIndices[bi + 1];
      final baseStation1 = sorted[startIdx];
      final baseStation2 = sorted[endIdx];
      final d1 = baseStation1.distance!;
      final d2 = baseStation2.distance!;
      final (baseNo, _) = baseStation1.stationParts;

      // 이 구간의 앵커 포인트들 (기본측점1 + 원본 플러스체인들 + 기본측점2)
      final anchors = <StationData>[baseStation1];
      for (int i = startIdx + 1; i < endIdx; i++) {
        anchors.add(sorted[i]); // 원본 플러스체인
      }
      anchors.add(baseStation2);

      // 이 구간에 이미 존재하는 플러스 거리(정수) 집합
      final existingPlusDistances = <int>{};
      for (int i = startIdx + 1; i < endIdx; i++) {
        final plusDist = sorted[i].distance! - d1;
        existingPlusDistances.add(plusDist.round());
      }

      // 기본측점1 추가
      result.add(baseStation1);

      // interval 간격으로 보간할 플러스 거리 목록 생성 (이미 있는 것 제외)
      final newPlusDistances = <int>[];
      for (int d = interval; d1 + d < d2; d += interval) {
        if (!existingPlusDistances.contains(d)) {
          newPlusDistances.add(d);
        }
      }

      // 원본 플러스체인 + 새 보간을 거리순으로 합치기
      // 먼저 모든 플러스체인(원본+보간)의 거리를 모아서 정렬
      final allPlusInSection = <_PlusEntry>[];

      // 원본 플러스체인
      for (int i = startIdx + 1; i < endIdx; i++) {
        allPlusInSection.add(_PlusEntry(
          distance: sorted[i].distance!,
          station: sorted[i],
          isOriginal: true,
        ));
      }

      // 새 보간
      for (final pd in newPlusDistances) {
        final targetDist = d1 + pd;
        // 앵커 중에서 targetDist 앞뒤를 찾아 보간
        StationData fromAnchor = anchors.first;
        StationData toAnchor = anchors.last;
        for (int a = 0; a < anchors.length - 1; a++) {
          if (anchors[a].distance! <= targetDist && anchors[a + 1].distance! >= targetDist) {
            fromAnchor = anchors[a];
            toAnchor = anchors[a + 1];
            break;
          }
        }

        final interpolated = _interpolateStation(
          from: fromAnchor,
          to: toAnchor,
          targetDist: targetDist,
          name: 'NO.$baseNo+$pd',
        );
        allPlusInSection.add(_PlusEntry(
          distance: targetDist,
          station: interpolated,
          isOriginal: false,
        ));
      }

      // 거리순 정렬 후 결과에 추가
      allPlusInSection.sort((a, b) => a.distance.compareTo(b.distance));
      for (final entry in allPlusInSection) {
        if (includeOriginalPlus || !entry.isOriginal) {
          result.add(entry.station);
        }
      }
    }

    // 마지막 기본측점 추가
    result.add(sorted[baseIndices.last]);

    // 마지막 기본측점 이후의 원본 플러스체인 추가
    if (includeOriginalPlus) {
      final lastBaseIdx = baseIndices.last;
      for (int i = lastBaseIdx + 1; i < sorted.length; i++) {
        result.add(sorted[i]);
      }
    }

    return result;
  }

  /// 측점 번호로 정렬
  static List<StationData> sortStations(List<StationData> stations) {
    final sorted = List<StationData>.from(stations);
    sorted.sort((a, b) {
      final (aBase, aPlus) = a.stationParts;
      final (bBase, bPlus) = b.stationParts;
      if (aBase != bBase) return aBase.compareTo(bBase);
      final aPlusValue = aPlus ?? 0;
      final bPlusValue = bPlus ?? 0;
      return aPlusValue.compareTo(bPlusValue);
    });
    return sorted;
  }
}

/// 내부용: 플러스체인 정렬을 위한 임시 구조체
class _PlusEntry {
  final double distance;
  final StationData station;
  final bool isOriginal;

  _PlusEntry({
    required this.distance,
    required this.station,
    required this.isOriginal,
  });
}
