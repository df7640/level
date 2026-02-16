import '../models/station_data.dart';

/// 보간 서비스
/// Python의 interpolation.py를 Flutter로 변환
class InterpolationService {
  /// 선형 보간 수행
  /// 두 값 사이를 선형적으로 보간
  ///
  /// 공식: value = v1 + (v2 - v1) * ((target_dist - d1) / (d2 - d1))
  static double? linearInterpolate({
    required double? v1, // 시작 값
    required double? v2, // 끝 값
    required double d1, // 시작 거리
    required double d2, // 끝 거리
    required double targetDist, // 목표 거리
  }) {
    // null 체크
    if (v1 == null || v2 == null) return null;
    if (d1 == d2) return v1; // 거리가 같으면 첫 번째 값 반환

    // 선형 보간
    final ratio = (targetDist - d1) / (d2 - d1);
    return v1 + (v2 - v1) * ratio;
  }

  /// 두 측점 사이에 플러스 체인 측점 생성
  /// 예: NO.1 (0m)과 NO.2 (20m) 사이에 +5m, +10m, +15m 생성
  static List<StationData> interpolateBetweenStations({
    required StationData station1,
    required StationData station2,
    required List<int> plusDistances, // [5, 10, 15]
  }) {
    final List<StationData> interpolated = [];

    // 거리 정보가 없으면 보간 불가
    if (station1.distance == null || station2.distance == null) {
      return interpolated;
    }

    final d1 = station1.distance!;
    final d2 = station2.distance!;
    final (baseNo, _) = station1.stationParts;

    // 각 플러스 거리에 대해 보간
    for (final plusDist in plusDistances) {
      final targetDist = d1 + plusDist;

      // 목표 거리가 두 측점 사이에 있는지 확인
      if (targetDist <= d1 || targetDist >= d2) continue;

      // 모든 숫자 컬럼 보간
      final interpolatedStation = StationData(
        no: 'NO.$baseNo+$plusDist',
        distance: targetDist,
        gh: linearInterpolate(
          v1: station1.gh,
          v2: station2.gh,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        ip: linearInterpolate(
          v1: station1.ip,
          v2: station2.ip,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        ghD: linearInterpolate(
          v1: station1.ghD,
          v2: station2.ghD,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        gh1: linearInterpolate(
          v1: station1.gh1,
          v2: station2.gh1,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        gh2: linearInterpolate(
          v1: station1.gh2,
          v2: station2.gh2,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        gh3: linearInterpolate(
          v1: station1.gh3,
          v2: station2.gh3,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        gh4: linearInterpolate(
          v1: station1.gh4,
          v2: station2.gh4,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        gh5: linearInterpolate(
          v1: station1.gh5,
          v2: station2.gh5,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        x: linearInterpolate(
          v1: station1.x,
          v2: station2.x,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        y: linearInterpolate(
          v1: station1.y,
          v2: station2.y,
          d1: d1,
          d2: d2,
          targetDist: targetDist,
        ),
        isInterpolated: true,
        lastModified: DateTime.now(),
      );

      interpolated.add(interpolatedStation);
    }

    return interpolated;
  }

  /// 전체 측점 목록에 대해 보간 수행
  static List<StationData> interpolateAllStations({
    required List<StationData> baseStations,
    required List<int> plusDistances,
  }) {
    final List<StationData> result = [];

    // 기본 측점만 필터링 (이미 정렬되어 있다고 가정)
    final bases =
        baseStations.where((s) => s.isBaseStation && s.distance != null).toList();

    if (bases.isEmpty) return result;

    // 인접한 두 측점 사이에 보간
    for (int i = 0; i < bases.length - 1; i++) {
      final station1 = bases[i];
      final station2 = bases[i + 1];

      // 현재 기본 측점 추가
      result.add(station1);

      // 보간된 측점들 추가
      final interpolated = interpolateBetweenStations(
        station1: station1,
        station2: station2,
        plusDistances: plusDistances,
      );
      result.addAll(interpolated);
    }

    // 마지막 기본 측점 추가
    if (bases.isNotEmpty) {
      result.add(bases.last);
    }

    return result;
  }

  /// 측점 번호로 정렬
  /// NO.1, NO.1+5, NO.1+10, NO.2, NO.2+5 ... 순서로 정렬
  static List<StationData> sortStations(List<StationData> stations) {
    final sorted = List<StationData>.from(stations);

    sorted.sort((a, b) {
      final (aBase, aPlus) = a.stationParts;
      final (bBase, bPlus) = b.stationParts;

      // 기본 번호 먼저 비교
      if (aBase != bBase) return aBase.compareTo(bBase);

      // 플러스 거리 비교 (null은 0으로 취급)
      final aPlusValue = aPlus ?? 0;
      final bPlusValue = bPlus ?? 0;
      return aPlusValue.compareTo(bPlusValue);
    });

    return sorted;
  }

  /// 누가거리 재계산
  /// 첫 번째 측점을 0으로 하고 순차적으로 계산
  static List<StationData> recalculateDistances(List<StationData> stations) {
    if (stations.isEmpty) return [];

    final sorted = sortStations(stations);
    final List<StationData> result = [];

    double currentDistance = 0.0;
    int? lastBaseNo;

    for (final station in sorted) {
      final (baseNo, plus) = station.stationParts;

      // 새로운 기본 측점이면 기존 거리 유지 또는 증가
      if (lastBaseNo != null && baseNo != lastBaseNo) {
        // 다음 기본 측점으로 넘어갈 때 거리 증가
        // 플러스 체인의 최대값을 고려하여 계산
        currentDistance = (currentDistance ~/ 20 + 1) * 20.0;
      }

      // 플러스 체인이 있으면 거리 추가
      if (plus != null) {
        currentDistance = (baseNo - 1) * 20.0 + plus;
      } else if (lastBaseNo == null || baseNo != lastBaseNo) {
        currentDistance = (baseNo - 1) * 20.0;
      }

      result.add(station.copyWith(distance: currentDistance));
      lastBaseNo = baseNo;
    }

    return result;
  }
}
