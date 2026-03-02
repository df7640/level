import 'dart:math';
import 'package:flutter/material.dart';
import 'snap_overlay_painter.dart';

/// 확대 뷰(Magnification Box) Painter
/// 커서 팁 주변 DXF 도면을 현재 줌 대비 3배 확대하여 좌상단 사각형에 표시
class MagnificationPainter extends CustomPainter {
  final Offset cursorTipDxf; // 커서 팁 DXF 좌표
  final List<dynamic> entities;
  final Map<String, dynamic> bounds;
  final Set<String> hiddenLayers;
  final double zoom;
  final double viewScale; // 도면 뷰의 현재 실제 스케일
  final SnapResult? activeSnap;

  static const double _boxSize = 150.0; // 사각형 크기
  static const double _boxRadius = 8.0; // 라운드 코너
  static const double _margin = 16.0;
  static const double _magFactor = 3.0; // 도면 뷰 대비 추가 확대 배율

  MagnificationPainter({
    required this.cursorTipDxf,
    required this.entities,
    required this.bounds,
    required this.hiddenLayers,
    required this.zoom,
    required this.viewScale,
    this.activeSnap,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final halfSize = _boxSize / 2;
    final center = Offset(_margin + halfSize, _margin + halfSize);
    final boxRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: _boxSize, height: _boxSize),
      Radius.circular(_boxRadius),
    );

    // 배경 사각형 (어두운 배경)
    canvas.drawRRect(
      boxRect,
      Paint()..color = Colors.grey[900]!,
    );

    // 클리핑
    canvas.save();
    canvas.clipRRect(boxRect);

    // DXF 좌표계 → 확대 뷰 좌표계 변환 생성
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfW = maxX - minX;
    final dxfH = maxY - minY;
    if (dxfW <= 0 || dxfH <= 0) {
      canvas.restore();
      return;
    }

    // 확대 뷰 내부의 스케일: 도면 뷰의 실제 스케일 × 3배
    final magScale = viewScale * _magFactor;

    // 커서 팁 DXF 좌표가 중심에 오도록 오프셋 계산
    final magCenterOffX = (_boxSize - dxfW * magScale) / 2;
    final magCenterOffY = (_boxSize - dxfH * magScale) / 2;
    final magOffsetDx = center.dx - (cursorTipDxf.dx - minX) * magScale - magCenterOffX;
    final magOffsetDy = (_margin + _boxSize) - center.dy - (cursorTipDxf.dy - minY) * magScale - magCenterOffY;

    // 변환 함수
    Offset magTransform(double x, double y) {
      final sx = (x - minX) * magScale + magCenterOffX + magOffsetDx;
      final sy = (_margin + _boxSize) - ((y - minY) * magScale + magCenterOffY + magOffsetDy);
      return Offset(sx, sy);
    }

    // 확대 뷰에 보이는 DXF 좌표 범위 계산 (필터링용)
    final visibleDxfMinX = cursorTipDxf.dx - halfSize / magScale;
    final visibleDxfMaxX = cursorTipDxf.dx + halfSize / magScale;
    final visibleDxfMinY = cursorTipDxf.dy - halfSize / magScale;
    final visibleDxfMaxY = cursorTipDxf.dy + halfSize / magScale;

    // 엔티티 렌더링
    const strokeWidth = 1.5;
    for (final entity in entities) {
      final type = entity['type'] as String;
      final layer = entity['layer'] as String?;
      if (layer != null && hiddenLayers.contains(layer)) continue;

      if (!_isEntityInRange(entity, type, visibleDxfMinX, visibleDxfMaxX, visibleDxfMinY, visibleDxfMaxY)) {
        continue;
      }

      final color = Color((entity['resolvedColor'] as int?) ?? 0xFFFFFFFF);
      final paint = Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke;

      switch (type) {
        case 'LINE':
          _drawLine(canvas, entity, magTransform, paint);
          break;
        case 'LWPOLYLINE':
          _drawPolyline(canvas, entity, magTransform, paint);
          break;
        case 'CIRCLE':
          _drawCircle(canvas, entity, magTransform, paint, magScale);
          break;
        case 'ARC':
          _drawArc(canvas, entity, magTransform, paint, magScale);
          break;
        case 'POINT':
          _drawPoint(canvas, entity, magTransform, paint);
          break;
      }
    }

    // 스냅 마커 표시
    if (activeSnap != null) {
      final snapPos = magTransform(activeSnap!.dxfX, activeSnap!.dxfY);
      _drawSnapMarkerInMag(canvas, snapPos, activeSnap!.type);
    }

    // 중앙 십자선
    final crossPaint = Paint()
      ..color = Colors.red.withValues(alpha: 0.7)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(center.dx - 8, center.dy),
      Offset(center.dx + 8, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - 8),
      Offset(center.dx, center.dy + 8),
      crossPaint,
    );

    canvas.restore();

    // 사각형 테두리
    canvas.drawRRect(
      boxRect,
      Paint()
        ..color = Colors.white70
        ..strokeWidth = 2.0
        ..style = PaintingStyle.stroke,
    );
  }

  /// 엔티티 바운딩 박스가 visible 범위와 교차하는지 확인
  /// 선분이 범위를 관통하는 경우도 포함 (AABB 교차 테스트)
  bool _isEntityInRange(dynamic entity, String type, double minX, double maxX, double minY, double maxY) {
    switch (type) {
      case 'LINE':
        final x1 = entity['x1'] as double;
        final y1 = entity['y1'] as double;
        final x2 = entity['x2'] as double;
        final y2 = entity['y2'] as double;
        return _segmentIntersectsRect(x1, y1, x2, y2, minX, minY, maxX, maxY);
      case 'LWPOLYLINE':
        final points = entity['points'] as List;
        if (points.isEmpty) return false;
        // 각 세그먼트가 범위와 교차하는지 체크
        for (int i = 0; i < points.length - 1; i++) {
          final p1 = points[i] as Map<String, dynamic>;
          final p2 = points[i + 1] as Map<String, dynamic>;
          if (_segmentIntersectsRect(
            p1['x'] as double, p1['y'] as double,
            p2['x'] as double, p2['y'] as double,
            minX, minY, maxX, maxY,
          )) return true;
        }
        final closed = entity['closed'] as bool? ?? false;
        if (closed && points.length > 1) {
          final pL = points.last as Map<String, dynamic>;
          final pF = points.first as Map<String, dynamic>;
          if (_segmentIntersectsRect(
            pL['x'] as double, pL['y'] as double,
            pF['x'] as double, pF['y'] as double,
            minX, minY, maxX, maxY,
          )) return true;
        }
        return false;
      case 'CIRCLE':
      case 'ARC':
        final cx = entity['cx'] as double;
        final cy = entity['cy'] as double;
        final r = entity['radius'] as double;
        return (cx + r) >= minX && (cx - r) <= maxX && (cy + r) >= minY && (cy - r) <= maxY;
      case 'POINT':
        final x = entity['x'] as double;
        final y = entity['y'] as double;
        return x >= minX && x <= maxX && y >= minY && y <= maxY;
      default:
        return true;
    }
  }

  void _drawLine(Canvas canvas, dynamic entity, Offset Function(double, double) transform, Paint paint) {
    final p1 = transform(entity['x1'] as double, entity['y1'] as double);
    final p2 = transform(entity['x2'] as double, entity['y2'] as double);
    canvas.drawLine(p1, p2, paint);
  }

  void _drawPolyline(Canvas canvas, dynamic entity, Offset Function(double, double) transform, Paint paint) {
    final points = entity['points'] as List;
    if (points.length < 2) return;

    final path = Path();
    final firstPoint = points[0] as Map<String, dynamic>;
    final start = transform(firstPoint['x'] as double, firstPoint['y'] as double);
    path.moveTo(start.dx, start.dy);

    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i] as Map<String, dynamic>;
      final p2 = points[i + 1] as Map<String, dynamic>;
      final bulge = p1['bulge'] as double? ?? 0.0;

      if (bulge.abs() > 1e-10) {
        _drawBulgeSegment(path, p1['x'] as double, p1['y'] as double,
            p2['x'] as double, p2['y'] as double, bulge, transform);
      } else {
        final end = transform(p2['x'] as double, p2['y'] as double);
        path.lineTo(end.dx, end.dy);
      }
    }

    final closed = entity['closed'] as bool? ?? false;
    if (closed && points.isNotEmpty) {
      final lastPoint = points.last as Map<String, dynamic>;
      final fPoint = points.first as Map<String, dynamic>;
      final bulge = lastPoint['bulge'] as double? ?? 0.0;
      if (bulge.abs() > 1e-10) {
        _drawBulgeSegment(path, lastPoint['x'] as double, lastPoint['y'] as double,
            fPoint['x'] as double, fPoint['y'] as double, bulge, transform);
      } else {
        path.close();
      }
    }

    canvas.drawPath(path, paint);
  }

  void _drawBulgeSegment(Path path, double x1, double y1, double x2, double y2,
      double bulge, Offset Function(double, double) transform) {
    final p2Screen = transform(x2, y2);
    if (bulge.abs() < 1e-10) {
      path.lineTo(p2Screen.dx, p2Screen.dy);
      return;
    }
    final p1Screen = transform(x1, y1);
    final dx = p2Screen.dx - p1Screen.dx;
    final dy = p2Screen.dy - p1Screen.dy;
    final chord = sqrt(dx * dx + dy * dy);
    if (chord < 1e-10) {
      path.lineTo(p2Screen.dx, p2Screen.dy);
      return;
    }
    final absB = bulge.abs();
    final radius = (chord * (1 + absB * absB)) / (4 * absB);
    path.arcToPoint(
      p2Screen,
      radius: Radius.circular(radius),
      clockwise: bulge < 0,
      largeArc: absB > 1.0,
    );
  }

  void _drawCircle(Canvas canvas, dynamic entity, Offset Function(double, double) transform, Paint paint, double scale) {
    final center = transform(entity['cx'] as double, entity['cy'] as double);
    canvas.drawCircle(center, (entity['radius'] as double) * scale, paint);
  }

  void _drawArc(Canvas canvas, dynamic entity, Offset Function(double, double) transform, Paint paint, double scale) {
    final cx = entity['cx'] as double;
    final cy = entity['cy'] as double;
    final radius = entity['radius'] as double;
    final startAngle = entity['startAngle'] as double;
    final endAngle = entity['endAngle'] as double;

    final center = transform(cx, cy);
    final scaledRadius = radius * scale;
    final startRad = -startAngle * pi / 180.0;
    double includedDeg = endAngle - startAngle;
    if (includedDeg <= 0) includedDeg += 360.0;
    final sweepRad = -includedDeg * pi / 180.0;
    final rect = Rect.fromCircle(center: center, radius: scaledRadius);
    canvas.drawArc(rect, startRad, sweepRad, false, paint);
  }

  void _drawPoint(Canvas canvas, dynamic entity, Offset Function(double, double) transform, Paint paint) {
    final position = transform(entity['x'] as double, entity['y'] as double);
    canvas.drawCircle(position, 2.0, paint..style = PaintingStyle.fill);
  }

  void _drawSnapMarkerInMag(Canvas canvas, Offset pos, SnapType type) {
    const s = 10.0;
    final paint = Paint()
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    switch (type) {
      case SnapType.endpoint:
        paint.color = Colors.greenAccent;
        final rect = Rect.fromCenter(center: pos, width: s, height: s);
        canvas.drawRect(rect, Paint()..color = Colors.greenAccent..style = PaintingStyle.fill);
        canvas.drawRect(rect, paint);
        break;
      case SnapType.center:
        paint.color = const Color(0xFFFF40FF);
        canvas.drawCircle(pos, s / 2, paint);
        canvas.drawLine(Offset(pos.dx - s / 2, pos.dy), Offset(pos.dx + s / 2, pos.dy), paint);
        canvas.drawLine(Offset(pos.dx, pos.dy - s / 2), Offset(pos.dx, pos.dy + s / 2), paint);
        break;
      case SnapType.intersection:
        paint.color = Colors.yellowAccent;
        canvas.drawLine(Offset(pos.dx - s / 2, pos.dy - s / 2), Offset(pos.dx + s / 2, pos.dy + s / 2), paint);
        canvas.drawLine(Offset(pos.dx + s / 2, pos.dy - s / 2), Offset(pos.dx - s / 2, pos.dy + s / 2), paint);
        break;
      case SnapType.node:
        paint.color = Colors.cyanAccent;
        canvas.drawCircle(pos, s / 2, paint);
        final inner = s / 2 * 0.6;
        canvas.drawLine(Offset(pos.dx - inner, pos.dy - inner), Offset(pos.dx + inner, pos.dy + inner), paint);
        canvas.drawLine(Offset(pos.dx + inner, pos.dy - inner), Offset(pos.dx - inner, pos.dy + inner), paint);
        break;
    }
  }

  /// 선분이 AABB 사각형과 교차하는지 판정 (Cohen-Sutherland 알고리즘 기반)
  bool _segmentIntersectsRect(
    double x1, double y1, double x2, double y2,
    double rMinX, double rMinY, double rMaxX, double rMaxY,
  ) {
    // 끝점이 사각형 안에 있으면 교차
    if (x1 >= rMinX && x1 <= rMaxX && y1 >= rMinY && y1 <= rMaxY) return true;
    if (x2 >= rMinX && x2 <= rMaxX && y2 >= rMinY && y2 <= rMaxY) return true;

    // 선분 바운딩 박스가 사각형과 겹치지 않으면 비교차
    final sMinX = x1 < x2 ? x1 : x2;
    final sMaxX = x1 > x2 ? x1 : x2;
    final sMinY = y1 < y2 ? y1 : y2;
    final sMaxY = y1 > y2 ? y1 : y2;
    if (sMaxX < rMinX || sMinX > rMaxX || sMaxY < rMinY || sMinY > rMaxY) {
      return false;
    }

    // 선분이 사각형의 4변과 교차하는지 확인
    if (_segSegCross(x1, y1, x2, y2, rMinX, rMinY, rMaxX, rMinY)) return true; // 하변
    if (_segSegCross(x1, y1, x2, y2, rMaxX, rMinY, rMaxX, rMaxY)) return true; // 우변
    if (_segSegCross(x1, y1, x2, y2, rMinX, rMaxY, rMaxX, rMaxY)) return true; // 상변
    if (_segSegCross(x1, y1, x2, y2, rMinX, rMinY, rMinX, rMaxY)) return true; // 좌변
    return false;
  }

  /// 두 선분이 교차하는지 판정
  bool _segSegCross(
    double ax, double ay, double bx, double by,
    double cx, double cy, double dx, double dy,
  ) {
    final d1 = (dx - cx) * (ay - cy) - (dy - cy) * (ax - cx);
    final d2 = (dx - cx) * (by - cy) - (dy - cy) * (bx - cx);
    if (d1 * d2 > 0) return false;
    final d3 = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
    final d4 = (bx - ax) * (dy - ay) - (by - ay) * (dx - ax);
    if (d3 * d4 > 0) return false;
    return true;
  }

  @override
  bool shouldRepaint(covariant MagnificationPainter oldDelegate) {
    return oldDelegate.cursorTipDxf != cursorTipDxf ||
        oldDelegate.zoom != zoom ||
        oldDelegate.activeSnap != activeSnap;
  }
}
