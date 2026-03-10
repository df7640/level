import 'dart:math';
import 'package:flutter/material.dart';
import '../widgets/snap_overlay_painter.dart';

/// 스냅 포인트 계산 서비스 (AutoCAD OSNAP 전체 지원)
class SnapService {
  static const double _baseEntityHit = 30.0;
  static const double _baseSnapDisplay = 60.0;
  static const double _baseIntSearchRadius = 50.0;

  static double _entityHitTolerance(double zoom) =>
      (_baseEntityHit / zoom).clamp(10.0, 80.0);
  static double _snapDisplayTolerance(double zoom) =>
      (_baseSnapDisplay / zoom).clamp(15.0, 120.0);
  static double _intSearchRadius(double zoom) =>
      (_baseIntSearchRadius / zoom).clamp(15.0, 100.0);

  /// 스냅 타입별 우선순위 (낮을수록 우선)
  static int _snapPriority(SnapType type) {
    switch (type) {
      case SnapType.center:
        return 0;
      case SnapType.intersection:
        return 1;
      case SnapType.endpoint:
        return 2;
      case SnapType.midpoint:
        return 3;
      case SnapType.insertion:
        return 3;
      case SnapType.quadrant:
        return 4;
      case SnapType.perpendicular:
        return 5;
      case SnapType.tangent:
        return 5;
      case SnapType.node:
        return 6;
      case SnapType.nearest:
        return 7;
    }
  }

  /// 커서 팁 위치에서 스냅 포인트를 찾음
  static ({Map<String, dynamic>? entity, SnapResult? snap}) findSnap({
    required Offset cursorTip,
    required List<dynamic> entities,
    required Set<String> hiddenLayers,
    required Offset Function(double, double) transformPoint,
    required Offset Function(double, double) inverseTransform,
    required double scale,
    double zoom = 1.0,
  }) {
    final hitTol = _entityHitTolerance(zoom);
    final snapTol = _snapDisplayTolerance(zoom);
    final intRadius = _intSearchRadius(zoom);

    // 1단계: 커서 팁 근처의 엔티티들 수집
    final nearbyEntities = <(Map<String, dynamic>, double)>[];

    for (final entity in entities) {
      final type = entity['type'] as String;
      final layer = entity['layer'] as String?;
      if (layer != null && hiddenLayers.contains(layer)) continue;

      final dist = _distanceToEntity(
        cursorTip: cursorTip,
        entity: entity,
        type: type,
        transformPoint: transformPoint,
        scale: scale,
      );

      if (dist < intRadius) {
        nearbyEntities.add((entity, dist));
      }
    }

    if (nearbyEntities.isEmpty) return (entity: null, snap: null);

    nearbyEntities.sort((a, b) => a.$2.compareTo(b.$2));
    final bestEntity = nearbyEntities.first.$1;
    final bestEntityDist = nearbyEntities.first.$2;

    // 교차 스냅은 항상 계산
    final intSnap = _findIntersectionSnap(
      cursorTip, nearbyEntities, transformPoint, scale, snapTol,
    );

    // 히트 범위 밖이면 교차만 반환
    if (bestEntityDist >= hitTol) {
      if (intSnap != null) {
        return (entity: intSnap.entity, snap: intSnap);
      }
      return (entity: null, snap: null);
    }

    // 2단계: 엔티티별 스냅 포인트 계산
    final snaps = _getEntitySnaps(
      entity: bestEntity,
      type: bestEntity['type'] as String,
      cursorTip: cursorTip,
      transformPoint: transformPoint,
      inverseTransform: inverseTransform,
      scale: scale,
    );

    // 교차 스냅 추가
    if (intSnap != null) {
      snaps.add(intSnap);
    }

    // 3단계: 우선순위 기반 선택
    SnapResult? bestSnap;
    double bestSnapDist = double.infinity;
    int bestPriority = 999;

    for (final snap in snaps) {
      final dist = (snap.screenPoint - cursorTip).distance;
      if (dist >= snapTol) continue;

      final priority = _snapPriority(snap.type);
      if (priority < bestPriority ||
          (priority == bestPriority && dist < bestSnapDist)) {
        bestPriority = priority;
        bestSnapDist = dist;
        bestSnap = snap;
      }
    }

    return (entity: bestSnap?.entity ?? bestEntity, snap: bestSnap);
  }

  // ──────────────────────────────────────────────
  // 엔티티까지 거리 계산
  // ──────────────────────────────────────────────

  static double _distanceToEntity({
    required Offset cursorTip,
    required Map<String, dynamic> entity,
    required String type,
    required Offset Function(double, double) transformPoint,
    required double scale,
  }) {
    switch (type) {
      case 'LINE':
        return _distToLine(cursorTip, entity, transformPoint);
      case 'LWPOLYLINE':
        return _distToPolyline(cursorTip, entity, transformPoint);
      case 'CIRCLE':
        return _distToCircle(cursorTip, entity, transformPoint, scale);
      case 'ARC':
        return _distToArc(cursorTip, entity, transformPoint, scale);
      case 'POINT':
        return _distToPoint(cursorTip, entity, transformPoint);
      case 'TEXT':
      case 'MTEXT':
        return _distToText(cursorTip, entity, transformPoint);
      case 'INSERT':
        return _distToInsert(cursorTip, entity, transformPoint);
      default:
        return double.infinity;
    }
  }

  static double _distToLine(Offset cursor, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final p1 = transformPoint(entity['x1'] as double, entity['y1'] as double);
    final p2 = transformPoint(entity['x2'] as double, entity['y2'] as double);
    return _pointToSegmentDist(cursor, p1, p2);
  }

  static double _distToPolyline(Offset cursor, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final points = entity['points'] as List;
    if (points.isEmpty) return double.infinity;

    double minDist = double.infinity;
    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i] as Map<String, dynamic>;
      final p2 = points[i + 1] as Map<String, dynamic>;
      final bulge = (p1['bulge'] as double?) ?? 0.0;
      final d = bulge.abs() > 1e-10
          ? _distToBulgeSegment(cursor, p1, p2, bulge, transformPoint)
          : _pointToSegmentDist(cursor,
              transformPoint(p1['x'] as double, p1['y'] as double),
              transformPoint(p2['x'] as double, p2['y'] as double));
      if (d < minDist) minDist = d;
    }

    final closed = entity['closed'] as bool? ?? false;
    if (closed && points.length > 1) {
      final pLast = points.last as Map<String, dynamic>;
      final pFirst = points.first as Map<String, dynamic>;
      final bulge = (pLast['bulge'] as double?) ?? 0.0;
      final d = bulge.abs() > 1e-10
          ? _distToBulgeSegment(cursor, pLast, pFirst, bulge, transformPoint)
          : _pointToSegmentDist(cursor,
              transformPoint(pLast['x'] as double, pLast['y'] as double),
              transformPoint(pFirst['x'] as double, pFirst['y'] as double));
      if (d < minDist) minDist = d;
    }

    return minDist;
  }

  /// 벌지(호) 세그먼트까지의 화면 거리
  static double _distToBulgeSegment(Offset cursor, Map<String, dynamic> p1, Map<String, dynamic> p2,
      double bulge, Offset Function(double, double) transformPoint) {
    final x1 = p1['x'] as double, y1 = p1['y'] as double;
    final x2 = p2['x'] as double, y2 = p2['y'] as double;
    // DXF 좌표에서 호의 중심과 반지름 계산
    final dx = x2 - x1, dy = y2 - y1;
    final chord = sqrt(dx * dx + dy * dy);
    if (chord < 1e-10) return double.infinity;
    final sagitta = (chord / 2) * bulge;
    final radius = ((chord * chord / 4) + sagitta * sagitta) / (2 * sagitta.abs());
    final mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
    final nx = -dy / chord, ny = dx / chord; // 수직 단위벡터
    final dist2center = radius - sagitta.abs();
    final sign = bulge > 0 ? 1.0 : -1.0;
    final cx = mx + nx * dist2center * sign;
    final cy = my + ny * dist2center * sign;

    // 화면 좌표로 변환
    final screenCenter = transformPoint(cx, cy);
    final screenP1 = transformPoint(x1, y1);
    final screenP2 = transformPoint(x2, y2);
    final screenRadius = (screenP1 - screenCenter).distance;

    // 커서에서 호까지의 거리 (원 위의 최근점 기준)
    final distToCenter = (cursor - screenCenter).distance;
    final distToArc = (distToCenter - screenRadius).abs();

    // 커서가 호의 각도 범위 내에 있는지 확인
    final a1 = atan2(screenP1.dy - screenCenter.dy, screenP1.dx - screenCenter.dx);
    final a2 = atan2(screenP2.dy - screenCenter.dy, screenP2.dx - screenCenter.dx);
    final ac = atan2(cursor.dy - screenCenter.dy, cursor.dx - screenCenter.dx);

    if (_isAngleInBulgeArc(ac, a1, a2, bulge > 0)) {
      return distToArc;
    }
    // 범위 밖이면 양 끝점까지 거리
    final d1 = (cursor - screenP1).distance;
    final d2 = (cursor - screenP2).distance;
    return d1 < d2 ? d1 : d2;
  }

  /// 라디안 각도가 벌지 호의 범위 내인지 확인
  static bool _isAngleInBulgeArc(double angle, double startAngle, double endAngle, bool ccw) {
    double normalize(double a) {
      while (a < -pi) { a += 2 * pi; }
      while (a > pi) { a -= 2 * pi; }
      return a;
    }
    final a = normalize(angle - startAngle);
    final sweep = normalize(endAngle - startAngle);
    if (ccw) {
      return sweep > 0 ? (a >= 0 && a <= sweep) : (a >= 0 || a <= sweep + 2 * pi);
    } else {
      return sweep < 0 ? (a <= 0 && a >= sweep) : (a <= 0 || a >= sweep - 2 * pi);
    }
  }

  static double _distToCircle(Offset cursor, Map<String, dynamic> entity, Offset Function(double, double) transformPoint, double scale) {
    final center = transformPoint(entity['cx'] as double, entity['cy'] as double);
    final screenRadius = (entity['radius'] as double) * scale;
    final distToCenter = (cursor - center).distance;
    final distToPerimeter = (distToCenter - screenRadius).abs();
    return min(distToPerimeter, distToCenter);
  }

  static double _distToArc(Offset cursor, Map<String, dynamic> entity, Offset Function(double, double) transformPoint, double scale) {
    final cx = entity['cx'] as double;
    final cy = entity['cy'] as double;
    final radius = entity['radius'] as double;
    final startAngle = entity['startAngle'] as double;
    final endAngle = entity['endAngle'] as double;

    final center = transformPoint(cx, cy);
    final screenRadius = radius * scale;
    final dx = cursor.dx - center.dx;
    final dy = cursor.dy - center.dy;
    final distToCenter = sqrt(dx * dx + dy * dy);

    if (distToCenter < _baseEntityHit) return distToCenter;

    final screenAngle = atan2(dy, dx);
    final dxfAngle = -screenAngle;
    double dxfAngleDeg = dxfAngle * 180.0 / pi;
    if (dxfAngleDeg < 0) dxfAngleDeg += 360.0;

    if (_isAngleInArc(dxfAngleDeg, startAngle, endAngle)) {
      return (distToCenter - screenRadius).abs();
    }

    final startRad = startAngle * pi / 180.0;
    final endRad = endAngle * pi / 180.0;
    final startPt = transformPoint(cx + radius * cos(startRad), cy + radius * sin(startRad));
    final endPt = transformPoint(cx + radius * cos(endRad), cy + radius * sin(endRad));

    return min((cursor - startPt).distance, (cursor - endPt).distance);
  }

  static double _distToPoint(Offset cursor, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final pt = transformPoint(entity['x'] as double, entity['y'] as double);
    return (cursor - pt).distance;
  }

  static double _distToText(Offset cursor, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final x = entity['x'] as double? ?? 0.0;
    final y = entity['y'] as double? ?? 0.0;
    final pt = transformPoint(x, y);
    return (cursor - pt).distance;
  }

  static double _distToInsert(Offset cursor, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final x = entity['x'] as double? ?? 0.0;
    final y = entity['y'] as double? ?? 0.0;
    final pt = transformPoint(x, y);
    return (cursor - pt).distance;
  }

  static double _pointToSegmentDist(Offset p, Offset a, Offset b) {
    final abx = b.dx - a.dx;
    final aby = b.dy - a.dy;
    final lenSq = abx * abx + aby * aby;
    if (lenSq < 0.001) return (p - a).distance;
    final t = ((p.dx - a.dx) * abx + (p.dy - a.dy) * aby) / lenSq;
    final tc = t.clamp(0.0, 1.0);
    final proj = Offset(a.dx + tc * abx, a.dy + tc * aby);
    return (p - proj).distance;
  }

  // ──────────────────────────────────────────────
  // 엔티티별 스냅 포인트 계산
  // ──────────────────────────────────────────────

  static List<SnapResult> _getEntitySnaps({
    required Map<String, dynamic> entity,
    required String type,
    required Offset cursorTip,
    required Offset Function(double, double) transformPoint,
    required Offset Function(double, double) inverseTransform,
    required double scale,
  }) {
    switch (type) {
      case 'LINE':
        return _getLineSnaps(entity, cursorTip, transformPoint, inverseTransform, scale);
      case 'LWPOLYLINE':
        return _getPolylineSnaps(entity, cursorTip, transformPoint, inverseTransform, scale);
      case 'CIRCLE':
        return _getCircleSnaps(entity, cursorTip, transformPoint, inverseTransform, scale);
      case 'ARC':
        return _getArcSnaps(entity, cursorTip, transformPoint, inverseTransform, scale);
      case 'POINT':
        return _getPointSnaps(entity, transformPoint);
      case 'TEXT':
      case 'MTEXT':
        return _getTextSnaps(entity, transformPoint);
      case 'INSERT':
        return _getInsertSnaps(entity, transformPoint);
      default:
        return [];
    }
  }

  /// POINT → 노드 스냅
  static List<SnapResult> _getPointSnaps(Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final x = entity['x'] as double;
    final y = entity['y'] as double;
    return [
      SnapResult(type: SnapType.node, screenPoint: transformPoint(x, y), dxfX: x, dxfY: y, entity: entity),
    ];
  }

  /// TEXT/MTEXT → 삽입점 스냅
  static List<SnapResult> _getTextSnaps(Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final x = entity['x'] as double? ?? 0.0;
    final y = entity['y'] as double? ?? 0.0;
    return [
      SnapResult(type: SnapType.insertion, screenPoint: transformPoint(x, y), dxfX: x, dxfY: y, entity: entity),
    ];
  }

  /// INSERT → 삽입점 스냅
  static List<SnapResult> _getInsertSnaps(Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final x = entity['x'] as double? ?? 0.0;
    final y = entity['y'] as double? ?? 0.0;
    return [
      SnapResult(type: SnapType.insertion, screenPoint: transformPoint(x, y), dxfX: x, dxfY: y, entity: entity),
    ];
  }

  /// LINE → 끝점 + 중점 + 수직점 + 최근점
  static List<SnapResult> _getLineSnaps(
    Map<String, dynamic> entity,
    Offset cursorTip,
    Offset Function(double, double) transformPoint,
    Offset Function(double, double) inverseTransform,
    double scale,
  ) {
    final x1 = entity['x1'] as double;
    final y1 = entity['y1'] as double;
    final x2 = entity['x2'] as double;
    final y2 = entity['y2'] as double;

    final snaps = <SnapResult>[
      // 끝점
      SnapResult(type: SnapType.endpoint, screenPoint: transformPoint(x1, y1), dxfX: x1, dxfY: y1, entity: entity),
      SnapResult(type: SnapType.endpoint, screenPoint: transformPoint(x2, y2), dxfX: x2, dxfY: y2, entity: entity),
      // 중점
      _midpointSnap(x1, y1, x2, y2, entity, transformPoint),
    ];

    // 수직점
    final perp = _perpToSegment(cursorTip, x1, y1, x2, y2, entity, transformPoint);
    if (perp != null) snaps.add(perp);

    // 최근점
    final near = _nearestOnSegment(cursorTip, x1, y1, x2, y2, entity, transformPoint);
    if (near != null) snaps.add(near);

    return snaps;
  }

  /// LWPOLYLINE → 꼭짓점 + 각 세그먼트 중점 + 수직점 + 최근점
  static List<SnapResult> _getPolylineSnaps(
    Map<String, dynamic> entity,
    Offset cursorTip,
    Offset Function(double, double) transformPoint,
    Offset Function(double, double) inverseTransform,
    double scale,
  ) {
    final points = entity['points'] as List;
    if (points.isEmpty) return [];

    final snaps = <SnapResult>[];

    // 꼭짓점 (끝점)
    for (final pt in points) {
      final p = pt as Map<String, dynamic>;
      final px = p['x'] as double;
      final py = p['y'] as double;
      snaps.add(SnapResult(type: SnapType.endpoint, screenPoint: transformPoint(px, py), dxfX: px, dxfY: py, entity: entity));
    }

    // 각 세그먼트의 중점 + 수직점 + 최근점
    double bestNearDist = double.infinity;
    SnapResult? bestNear;

    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i] as Map<String, dynamic>;
      final p2 = points[i + 1] as Map<String, dynamic>;
      final x1 = p1['x'] as double, y1 = p1['y'] as double;
      final x2 = p2['x'] as double, y2 = p2['y'] as double;

      snaps.add(_midpointSnap(x1, y1, x2, y2, entity, transformPoint));

      final perp = _perpToSegment(cursorTip, x1, y1, x2, y2, entity, transformPoint);
      if (perp != null) snaps.add(perp);

      final near = _nearestOnSegment(cursorTip, x1, y1, x2, y2, entity, transformPoint);
      if (near != null) {
        final d = (near.screenPoint - cursorTip).distance;
        if (d < bestNearDist) {
          bestNearDist = d;
          bestNear = near;
        }
      }
    }

    // 닫힌 폴리라인 마지막 세그먼트
    final closed = entity['closed'] as bool? ?? false;
    if (closed && points.length > 1) {
      final pL = points.last as Map<String, dynamic>;
      final pF = points.first as Map<String, dynamic>;
      final x1 = pL['x'] as double, y1 = pL['y'] as double;
      final x2 = pF['x'] as double, y2 = pF['y'] as double;
      snaps.add(_midpointSnap(x1, y1, x2, y2, entity, transformPoint));
      final perp = _perpToSegment(cursorTip, x1, y1, x2, y2, entity, transformPoint);
      if (perp != null) snaps.add(perp);
    }

    if (bestNear != null) snaps.add(bestNear);

    return snaps;
  }

  /// CIRCLE → 중심 + 사분점 + 수직점(최근점) + 접선
  static List<SnapResult> _getCircleSnaps(
    Map<String, dynamic> entity,
    Offset cursorTip,
    Offset Function(double, double) transformPoint,
    Offset Function(double, double) inverseTransform,
    double scale,
  ) {
    final cx = entity['cx'] as double;
    final cy = entity['cy'] as double;
    final radius = entity['radius'] as double;

    final snaps = <SnapResult>[
      // 중심
      SnapResult(type: SnapType.center, screenPoint: transformPoint(cx, cy), dxfX: cx, dxfY: cy, entity: entity),
    ];

    // 사분점 (0°, 90°, 180°, 270°)
    for (final deg in [0.0, 90.0, 180.0, 270.0]) {
      final rad = deg * pi / 180.0;
      final qx = cx + radius * cos(rad);
      final qy = cy + radius * sin(rad);
      snaps.add(SnapResult(type: SnapType.quadrant, screenPoint: transformPoint(qx, qy), dxfX: qx, dxfY: qy, entity: entity));
    }

    // 수직점 (= 커서에서 원에 가장 가까운 점)
    final nearPerp = _nearestOnCircle(cursorTip, cx, cy, radius, entity, transformPoint);
    if (nearPerp != null) {
      snaps.add(SnapResult(type: SnapType.perpendicular, screenPoint: nearPerp.screenPoint, dxfX: nearPerp.dxfX, dxfY: nearPerp.dxfY, entity: entity));
      snaps.add(nearPerp); // nearest
    }

    // 접선점
    final tangents = _tangentOnCircle(cursorTip, cx, cy, radius, entity, transformPoint);
    snaps.addAll(tangents);

    return snaps;
  }

  /// ARC → 중심 + 시작/끝 끝점 + 중점 + 사분점 + 수직점 + 접선
  static List<SnapResult> _getArcSnaps(
    Map<String, dynamic> entity,
    Offset cursorTip,
    Offset Function(double, double) transformPoint,
    Offset Function(double, double) inverseTransform,
    double scale,
  ) {
    final cx = entity['cx'] as double;
    final cy = entity['cy'] as double;
    final radius = entity['radius'] as double;
    final startAngle = entity['startAngle'] as double;
    final endAngle = entity['endAngle'] as double;

    final startRad = startAngle * pi / 180.0;
    final endRad = endAngle * pi / 180.0;
    final sx = cx + radius * cos(startRad);
    final sy = cy + radius * sin(startRad);
    final ex = cx + radius * cos(endRad);
    final ey = cy + radius * sin(endRad);

    final snaps = <SnapResult>[
      // 중심
      SnapResult(type: SnapType.center, screenPoint: transformPoint(cx, cy), dxfX: cx, dxfY: cy, entity: entity),
      // 시작/끝 끝점
      SnapResult(type: SnapType.endpoint, screenPoint: transformPoint(sx, sy), dxfX: sx, dxfY: sy, entity: entity),
      SnapResult(type: SnapType.endpoint, screenPoint: transformPoint(ex, ey), dxfX: ex, dxfY: ey, entity: entity),
    ];

    // 호 중점
    double midAngle = (startAngle + endAngle) / 2;
    if (endAngle < startAngle) midAngle += 180;
    final midRad = midAngle * pi / 180.0;
    final mx = cx + radius * cos(midRad);
    final my = cy + radius * sin(midRad);
    snaps.add(SnapResult(type: SnapType.midpoint, screenPoint: transformPoint(mx, my), dxfX: mx, dxfY: my, entity: entity));

    // 사분점 (호 범위 내만)
    for (final deg in [0.0, 90.0, 180.0, 270.0]) {
      if (_isAngleInArc(deg, startAngle, endAngle)) {
        final rad = deg * pi / 180.0;
        final qx = cx + radius * cos(rad);
        final qy = cy + radius * sin(rad);
        snaps.add(SnapResult(type: SnapType.quadrant, screenPoint: transformPoint(qx, qy), dxfX: qx, dxfY: qy, entity: entity));
      }
    }

    // 수직점/최근점 (호 범위 내)
    final nearPerp = _nearestOnCircle(cursorTip, cx, cy, radius, entity, transformPoint);
    if (nearPerp != null) {
      double angle = atan2(nearPerp.dxfY - cy, nearPerp.dxfX - cx) * 180 / pi;
      if (angle < 0) angle += 360;
      if (_isAngleInArc(angle, startAngle, endAngle)) {
        snaps.add(SnapResult(type: SnapType.perpendicular, screenPoint: nearPerp.screenPoint, dxfX: nearPerp.dxfX, dxfY: nearPerp.dxfY, entity: entity));
        snaps.add(nearPerp);
      }
    }

    return snaps;
  }

  // ──────────────────────────────────────────────
  // 스냅 헬퍼: 중점, 수직, 최근점, 접선
  // ──────────────────────────────────────────────

  /// 선분 중점
  static SnapResult _midpointSnap(double x1, double y1, double x2, double y2, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final mx = (x1 + x2) / 2;
    final my = (y1 + y2) / 2;
    return SnapResult(type: SnapType.midpoint, screenPoint: transformPoint(mx, my), dxfX: mx, dxfY: my, entity: entity);
  }

  /// 선분에 수선의 발 (perpendicular)
  static SnapResult? _perpToSegment(Offset cursor, double x1, double y1, double x2, double y2, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final p1 = transformPoint(x1, y1);
    final p2 = transformPoint(x2, y2);
    final abx = p2.dx - p1.dx;
    final aby = p2.dy - p1.dy;
    final lenSq = abx * abx + aby * aby;
    if (lenSq < 0.001) return null;
    final t = ((cursor.dx - p1.dx) * abx + (cursor.dy - p1.dy) * aby) / lenSq;
    if (t < 0.01 || t > 0.99) return null; // 끝점 근처 제외 (끝점 스냅과 겹침 방지)

    final px = x1 + t * (x2 - x1);
    final py = y1 + t * (y2 - y1);
    return SnapResult(type: SnapType.perpendicular, screenPoint: transformPoint(px, py), dxfX: px, dxfY: py, entity: entity);
  }

  /// 선분 위 최근접점 (nearest)
  static SnapResult? _nearestOnSegment(Offset cursor, double x1, double y1, double x2, double y2, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final p1 = transformPoint(x1, y1);
    final p2 = transformPoint(x2, y2);
    final abx = p2.dx - p1.dx;
    final aby = p2.dy - p1.dy;
    final lenSq = abx * abx + aby * aby;
    if (lenSq < 0.001) return null;
    final t = ((cursor.dx - p1.dx) * abx + (cursor.dy - p1.dy) * aby) / lenSq;
    final tc = t.clamp(0.0, 1.0);
    final px = x1 + tc * (x2 - x1);
    final py = y1 + tc * (y2 - y1);
    return SnapResult(type: SnapType.nearest, screenPoint: transformPoint(px, py), dxfX: px, dxfY: py, entity: entity);
  }

  /// 원 위 최근접점 (nearest / perpendicular)
  static SnapResult? _nearestOnCircle(Offset cursor, double cx, double cy, double radius, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final center = transformPoint(cx, cy);
    final dx = cursor.dx - center.dx;
    final dy = cursor.dy - center.dy;
    final dist = sqrt(dx * dx + dy * dy);
    if (dist < 1e-6) return null;

    // DXF 각도 (화면 Y 반전)
    final screenAngle = atan2(dy, dx);
    final dxfAngle = -screenAngle;
    final nx = cx + radius * cos(dxfAngle);
    final ny = cy + radius * sin(dxfAngle);

    return SnapResult(type: SnapType.nearest, screenPoint: transformPoint(nx, ny), dxfX: nx, dxfY: ny, entity: entity);
  }

  /// 원에 대한 접선점
  static List<SnapResult> _tangentOnCircle(Offset cursor, double cx, double cy, double radius, Map<String, dynamic> entity, Offset Function(double, double) transformPoint) {
    final center = transformPoint(cx, cy);
    final dx = cursor.dx - center.dx;
    final dy = cursor.dy - center.dy;
    final dist = sqrt(dx * dx + dy * dy);

    // 커서가 원 밖에 있어야 접선 존재
    // 화면 좌표 기준으로 판단하기 어려우므로 DXF 좌표 사용
    // 간이: 접선점 = 중심에서 커서 방향으로 radius 만큼 이동한 점 (근사)
    // 실제 접선: d > r 일 때만
    if (dist < 1e-6) return [];

    final screenAngle = atan2(dy, dx);
    final dxfAngle = -screenAngle;

    // 접선각 계산
    final sinT = radius / (dist / (radius / 1.0)); // 근사
    if (sinT.abs() > 1.0) return [];

    // 접선점 2개
    final results = <SnapResult>[];
    final tangentAngle = asin((radius * radius) / (dist * radius)).clamp(-pi / 2, pi / 2);

    for (final sign in [1.0, -1.0]) {
      final angle = dxfAngle + sign * tangentAngle;
      final tx = cx + radius * cos(angle);
      final ty = cy + radius * sin(angle);
      results.add(SnapResult(type: SnapType.tangent, screenPoint: transformPoint(tx, ty), dxfX: tx, dxfY: ty, entity: entity));
    }

    return results;
  }

  // ──────────────────────────────────────────────
  // 교차 스냅 (Intersection)
  // ──────────────────────────────────────────────

  static SnapResult? _findIntersectionSnap(
    Offset cursorTip,
    List<(Map<String, dynamic>, double)> nearbyEntities,
    Offset Function(double, double) transformPoint,
    double scale,
    double snapTol,
  ) {
    if (nearbyEntities.length < 2) return null;

    SnapResult? bestSnap;
    double bestDist = double.infinity;

    final limit = nearbyEntities.length < 10 ? nearbyEntities.length : 10;
    for (int i = 0; i < limit; i++) {
      for (int j = i + 1; j < limit; j++) {
        final e1 = nearbyEntities[i].$1;
        final e2 = nearbyEntities[j].$1;

        final pts = _intersectEntities(e1, e2, transformPoint, scale);
        for (final pt in pts) {
          final dist = (pt.screenPoint - cursorTip).distance;
          if (dist < snapTol && dist < bestDist) {
            bestDist = dist;
            bestSnap = pt;
          }
        }
      }
    }

    return bestSnap;
  }

  static List<SnapResult> _intersectEntities(
    Map<String, dynamic> e1,
    Map<String, dynamic> e2,
    Offset Function(double, double) transformPoint,
    double scale,
  ) {
    final segs1 = _entityToSegments(e1);
    final segs2 = _entityToSegments(e2);
    final t1 = e1['type'] as String;
    final t2 = e2['type'] as String;

    final results = <SnapResult>[];

    // 선분-선분 교차
    for (final s1 in segs1) {
      for (final s2 in segs2) {
        final ip = _segSegIntersect(s1, s2);
        if (ip != null) {
          results.add(SnapResult(type: SnapType.intersection, screenPoint: transformPoint(ip.dx, ip.dy), dxfX: ip.dx, dxfY: ip.dy, entity: e1));
        }
      }
    }

    // 선분-원/호 교차
    if (_isCircular(t1) || _isCircular(t2)) {
      final circular = _isCircular(t1) ? e1 : e2;
      final other = _isCircular(t1) ? e2 : e1;
      final otherSegs = _isCircular(t1) ? segs2 : segs1;

      final cx = circular['cx'] as double;
      final cy = circular['cy'] as double;
      final radius = circular['radius'] as double;
      final isArc = circular['type'] == 'ARC';
      final startAngle = isArc ? circular['startAngle'] as double : 0.0;
      final endAngle = isArc ? circular['endAngle'] as double : 360.0;

      for (final seg in otherSegs) {
        final pts = _segCircleIntersect(seg, cx, cy, radius);
        for (final pt in pts) {
          if (isArc) {
            double angle = atan2(pt.dy - cy, pt.dx - cx) * 180.0 / pi;
            if (angle < 0) angle += 360;
            if (!_isAngleInArc(angle, startAngle, endAngle)) continue;
          }
          results.add(SnapResult(type: SnapType.intersection, screenPoint: transformPoint(pt.dx, pt.dy), dxfX: pt.dx, dxfY: pt.dy, entity: other));
        }
      }
    }

    // 원-원, 원-호, 호-호 교차
    if (_isCircular(t1) && _isCircular(t2)) {
      final pts = _circleCircleIntersect(e1, e2);
      for (final pt in pts) {
        bool valid = true;
        for (final e in [e1, e2]) {
          if (e['type'] == 'ARC') {
            double angle = atan2(pt.dy - (e['cy'] as double), pt.dx - (e['cx'] as double)) * 180.0 / pi;
            if (angle < 0) angle += 360;
            if (!_isAngleInArc(angle, e['startAngle'] as double, e['endAngle'] as double)) {
              valid = false;
              break;
            }
          }
        }
        if (valid) {
          results.add(SnapResult(type: SnapType.intersection, screenPoint: transformPoint(pt.dx, pt.dy), dxfX: pt.dx, dxfY: pt.dy, entity: e1));
        }
      }
    }

    return results;
  }

  static bool _isCircular(String type) => type == 'CIRCLE' || type == 'ARC';

  static List<(double, double, double, double)> _entityToSegments(Map<String, dynamic> entity) {
    final type = entity['type'] as String;
    final segs = <(double, double, double, double)>[];

    switch (type) {
      case 'LINE':
        segs.add((entity['x1'] as double, entity['y1'] as double, entity['x2'] as double, entity['y2'] as double));
        break;
      case 'LWPOLYLINE':
        final points = entity['points'] as List;
        for (int i = 0; i < points.length - 1; i++) {
          final p1 = points[i] as Map<String, dynamic>;
          final p2 = points[i + 1] as Map<String, dynamic>;
          segs.add((p1['x'] as double, p1['y'] as double, p2['x'] as double, p2['y'] as double));
        }
        final closed = entity['closed'] as bool? ?? false;
        if (closed && points.length > 1) {
          final pL = points.last as Map<String, dynamic>;
          final pF = points.first as Map<String, dynamic>;
          segs.add((pL['x'] as double, pL['y'] as double, pF['x'] as double, pF['y'] as double));
        }
        break;
    }
    return segs;
  }

  static Offset? _segSegIntersect((double, double, double, double) s1, (double, double, double, double) s2) {
    final (x1, y1, x2, y2) = s1;
    final (x3, y3, x4, y4) = s2;

    final denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
    if (denom.abs() < 1e-10) return null;

    final t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom;
    final u = -((x1 - x2) * (y1 - y3) - (y1 - y2) * (x1 - x3)) / denom;

    if (t < -0.001 || t > 1.001 || u < -0.001 || u > 1.001) return null;

    return Offset(x1 + t * (x2 - x1), y1 + t * (y2 - y1));
  }

  static List<Offset> _segCircleIntersect((double, double, double, double) seg, double cx, double cy, double radius) {
    final (x1, y1, x2, y2) = seg;
    final dx = x2 - x1;
    final dy = y2 - y1;
    final fx = x1 - cx;
    final fy = y1 - cy;

    final a = dx * dx + dy * dy;
    final b = 2 * (fx * dx + fy * dy);
    final c = fx * fx + fy * fy - radius * radius;

    var discriminant = b * b - 4 * a * c;
    if (discriminant < 0) return [];

    final results = <Offset>[];
    discriminant = sqrt(discriminant);

    final t1 = (-b - discriminant) / (2 * a);
    final t2 = (-b + discriminant) / (2 * a);

    if (t1 >= -0.001 && t1 <= 1.001) {
      results.add(Offset(x1 + t1 * dx, y1 + t1 * dy));
    }
    if (t2 >= -0.001 && t2 <= 1.001 && (t2 - t1).abs() > 1e-10) {
      results.add(Offset(x1 + t2 * dx, y1 + t2 * dy));
    }

    return results;
  }

  static List<Offset> _circleCircleIntersect(Map<String, dynamic> e1, Map<String, dynamic> e2) {
    final cx1 = e1['cx'] as double;
    final cy1 = e1['cy'] as double;
    final r1 = e1['radius'] as double;
    final cx2 = e2['cx'] as double;
    final cy2 = e2['cy'] as double;
    final r2 = e2['radius'] as double;

    final dx = cx2 - cx1;
    final dy = cy2 - cy1;
    final d = sqrt(dx * dx + dy * dy);

    if (d > r1 + r2 + 0.001) return [];
    if (d < (r1 - r2).abs() - 0.001) return [];
    if (d < 1e-10) return [];

    final a = (r1 * r1 - r2 * r2 + d * d) / (2 * d);
    final hSq = r1 * r1 - a * a;
    if (hSq < 0) return [];
    final h = sqrt(hSq);

    final mx = cx1 + a * dx / d;
    final my = cy1 + a * dy / d;

    if (h < 1e-10) {
      return [Offset(mx, my)];
    }

    return [
      Offset(mx + h * dy / d, my - h * dx / d),
      Offset(mx - h * dy / d, my + h * dx / d),
    ];
  }

  // ──────────────────────────────────────────────
  // 유틸리티
  // ──────────────────────────────────────────────

  static bool _isAngleInArc(double angleDeg, double startDeg, double endDeg) {
    double a = angleDeg % 360;
    if (a < 0) a += 360;
    double s = startDeg % 360;
    if (s < 0) s += 360;
    double e = endDeg % 360;
    if (e < 0) e += 360;

    if (s <= e) {
      return a >= s && a <= e;
    } else {
      return a >= s || a <= e;
    }
  }
}
