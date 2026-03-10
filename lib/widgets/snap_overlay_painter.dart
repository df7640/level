import 'dart:math';
import 'package:flutter/material.dart';

/// 스냅 유형 (AutoCAD OSNAP 전체 지원)
enum SnapType {
  endpoint,      // 끝점 (선/폴리라인/호 끝점) — ■ 채움 사각형
  midpoint,      // 중점 (선/폴리라인 세그먼트/호 중점) — △ 삼각형
  center,        // 중심 (원/호 중심) — ○ 안에 십자
  node,          // 노드 (POINT 엔티티) — ○ 안에 X
  quadrant,      // 사분점 (원/호 0°/90°/180°/270°) — ◇ 마름모
  intersection,  // 교차점 (엔티티 간 교차) — X
  insertion,     // 삽입점 (TEXT/INSERT 기준점) — ⊞ 사각+십자
  perpendicular, // 수직점 (엔티티에 수선의 발) — ⊥
  tangent,       // 접선점 (원/호 접점) — ○ 위 선
  nearest,       // 최근점 (엔티티 위 최근접점) — ⌛ 모래시계
}

/// 스냅 결과
class SnapResult {
  final SnapType type;
  final Offset screenPoint; // 화면 좌표
  final double dxfX; // DXF X 좌표
  final double dxfY; // DXF Y 좌표
  final Map<String, dynamic> entity; // 스냅된 엔티티

  SnapResult({
    required this.type,
    required this.screenPoint,
    required this.dxfX,
    required this.dxfY,
    required this.entity,
  });
}

/// 포인트 지정 커서 + 스냅 표식 오버레이 Painter
class SnapOverlayPainter extends CustomPainter {
  final Offset? touchPoint; // 터치 위치 (화면 좌표)
  final SnapResult? activeSnap; // 현재 활성 스냅
  final Map<String, dynamic>? highlightEntity; // 하이라이트할 엔티티
  final Offset Function(double, double)? transformPoint; // 좌표 변환 함수
  final double scale; // 현재 스케일

  // 커서 설정
  static const double _cursorLineLengthCm = 3.0; // 3cm
  static const double _cursorAngleDeg = 120.0; // 11시 방향 (120도)
  static const double _arrowHeadSize = 20.0; // 화살촉 크기 (px)
  static const double _snapMarkerSize = 12.0; // 스냅 표식 크기 (px)

  SnapOverlayPainter({
    this.touchPoint,
    this.activeSnap,
    this.highlightEntity,
    this.transformPoint,
    this.scale = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (touchPoint == null) return;

    // 1. 커서 라인 + 화살촉 그리기
    _drawCursor(canvas, touchPoint!);

    // 2. 하이라이트된 엔티티 그리기
    if (highlightEntity != null && transformPoint != null) {
      _drawHighlightEntity(canvas, highlightEntity!, size);
    }

    // 3. 스냅 표식 그리기
    if (activeSnap != null) {
      _drawSnapMarker(canvas, activeSnap!);
    }
  }

  /// 커서 그리기: 11시 방향 화살촉 → 라인 → 터치점에 큰 흰색 원
  void _drawCursor(Canvas canvas, Offset touch) {
    const double circleRadius = 20.0;
    final pen = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    // 터치점: 흰색 채움 원 + 테두리 + 외곽 테두리(옵셋 2px)
    canvas.drawCircle(touch, circleRadius,
      Paint()..color = Colors.white..style = PaintingStyle.fill);
    canvas.drawCircle(touch, circleRadius, pen);
    canvas.drawCircle(touch, circleRadius + 2, pen);

    // 11시 방향 라인 (1px)
    const double pixelsPerCm = 38.0;
    final lineLength = _cursorLineLengthCm * pixelsPerCm;
    final angleRad = _cursorAngleDeg * pi / 180.0;
    final dx = cos(angleRad) * lineLength;
    final dy = -sin(angleRad) * lineLength;
    final tip = Offset(touch.dx + dx, touch.dy + dy);

    // 외곽 원 테두리에서 시작
    final startR = circleRadius + 2;
    final lineStart = Offset(
      touch.dx + cos(angleRad) * startR,
      touch.dy - sin(angleRad) * startR,
    );
    canvas.drawLine(lineStart, tip, pen);

    // 화살촉 (라인만, 채움 없음, 좁은 각도, 크기 2배)
    const double headLen = 28.0;
    const double headAngle = 15.0 * pi / 180.0;
    final backAngle = atan2(-dy, -dx);

    final left = Offset(
      tip.dx + headLen * cos(backAngle + headAngle),
      tip.dy + headLen * sin(backAngle + headAngle),
    );
    final right = Offset(
      tip.dx + headLen * cos(backAngle - headAngle),
      tip.dy + headLen * sin(backAngle - headAngle),
    );
    canvas.drawLine(tip, left, pen);
    canvas.drawLine(tip, right, pen);
  }

  /// 커서 팁(화살촉 끝) 위치 계산 (외부에서 사용)
  static Offset getCursorTip(Offset touchPoint) {
    const double pixelsPerCm = 38.0;
    final lineLength = _cursorLineLengthCm * pixelsPerCm;
    final angleRad = _cursorAngleDeg * pi / 180.0;
    final dx = cos(angleRad) * lineLength;
    final dy = -sin(angleRad) * lineLength;
    return Offset(touchPoint.dx + dx, touchPoint.dy + dy);
  }

  /// 하이라이트 엔티티 그리기
  void _drawHighlightEntity(
      Canvas canvas, Map<String, dynamic> entity, Size size) {
    final transform = transformPoint!;
    final type = entity['type'] as String;

    final highlightPaint = Paint()
      ..color = Colors.cyanAccent
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    switch (type) {
      case 'LINE':
        final p1 = transform(entity['x1'] as double, entity['y1'] as double);
        final p2 = transform(entity['x2'] as double, entity['y2'] as double);
        canvas.drawLine(p1, p2, highlightPaint);
        break;

      case 'LWPOLYLINE':
        final points = entity['points'] as List;
        if (points.length < 2) return;
        final path = Path();
        final firstPt = points[0] as Map<String, dynamic>;
        final start = transform(firstPt['x'] as double, firstPt['y'] as double);
        path.moveTo(start.dx, start.dy);
        for (int i = 0; i < points.length - 1; i++) {
          final p1 = points[i] as Map<String, dynamic>;
          final p2 = points[i + 1] as Map<String, dynamic>;
          final bulge = p1['bulge'] as double? ?? 0.0;
          if (bulge.abs() > 1e-10) {
            _drawBulgeSegment(path, p1['x'], p1['y'], p2['x'], p2['y'], bulge, transform);
          } else {
            final p = transform(p2['x'] as double, p2['y'] as double);
            path.lineTo(p.dx, p.dy);
          }
        }
        final closed = entity['closed'] as bool? ?? false;
        if (closed && points.isNotEmpty) {
          final lastPt = points.last as Map<String, dynamic>;
          final fPt = points.first as Map<String, dynamic>;
          final bulge = lastPt['bulge'] as double? ?? 0.0;
          if (bulge.abs() > 1e-10) {
            _drawBulgeSegment(path, lastPt['x'], lastPt['y'], fPt['x'], fPt['y'], bulge, transform);
          } else {
            path.close();
          }
        }
        canvas.drawPath(path, highlightPaint);
        break;

      case 'CIRCLE':
        final center = transform(
            entity['cx'] as double, entity['cy'] as double);
        final radius = (entity['radius'] as double) * scale;
        canvas.drawCircle(center, radius, highlightPaint);
        break;

      case 'ARC':
        final center = transform(
            entity['cx'] as double, entity['cy'] as double);
        final radius = (entity['radius'] as double) * scale;
        final startAngle = entity['startAngle'] as double;
        final endAngle = entity['endAngle'] as double;
        final startRad = -startAngle * pi / 180.0;
        double includedDeg = endAngle - startAngle;
        if (includedDeg <= 0) includedDeg += 360.0;
        final sweepRad = -includedDeg * pi / 180.0;
        final rect = Rect.fromCircle(center: center, radius: radius);
        canvas.drawArc(rect, startRad, sweepRad, false, highlightPaint);
        break;
    }
  }

  /// Bulge → arc 변환 (DxfPainter와 동일 로직)
  void _drawBulgeSegment(
    Path path,
    double x1, double y1,
    double x2, double y2,
    double bulge,
    Offset Function(double, double) transform,
  ) {
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

  /// 스냅 표식 그리기 (AutoCAD 스타일)
  void _drawSnapMarker(Canvas canvas, SnapResult snap) {
    final pos = snap.screenPoint;
    const s = _snapMarkerSize;

    final markerPaint = Paint()
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    switch (snap.type) {
      case SnapType.endpoint:
        // 끝점: 채워진 사각형 ■
        markerPaint.color = Colors.greenAccent;
        final rect = Rect.fromCenter(center: pos, width: s, height: s);
        canvas.drawRect(rect, Paint()..color = Colors.greenAccent..style = PaintingStyle.fill);
        canvas.drawRect(rect, markerPaint);
        break;

      case SnapType.midpoint:
        // 중점: 삼각형 △
        markerPaint.color = Colors.greenAccent;
        final halfS = s / 2;
        final path = Path()
          ..moveTo(pos.dx, pos.dy - halfS)
          ..lineTo(pos.dx - halfS, pos.dy + halfS)
          ..lineTo(pos.dx + halfS, pos.dy + halfS)
          ..close();
        canvas.drawPath(path, markerPaint);
        break;

      case SnapType.center:
        // 중심: 원 안에 십자 ⊕
        markerPaint.color = const Color(0xFFFF40FF);
        final halfS = s / 2;
        canvas.drawCircle(pos, halfS, markerPaint);
        canvas.drawLine(Offset(pos.dx - halfS, pos.dy), Offset(pos.dx + halfS, pos.dy), markerPaint);
        canvas.drawLine(Offset(pos.dx, pos.dy - halfS), Offset(pos.dx, pos.dy + halfS), markerPaint);
        break;

      case SnapType.node:
        // 노드: 원 안에 X ⊗
        markerPaint.color = Colors.cyanAccent;
        final halfS = s / 2;
        canvas.drawCircle(pos, halfS, markerPaint);
        final inner = halfS * 0.6;
        canvas.drawLine(Offset(pos.dx - inner, pos.dy - inner), Offset(pos.dx + inner, pos.dy + inner), markerPaint);
        canvas.drawLine(Offset(pos.dx + inner, pos.dy - inner), Offset(pos.dx - inner, pos.dy + inner), markerPaint);
        break;

      case SnapType.quadrant:
        // 사분점: 마름모 ◇
        markerPaint.color = Colors.greenAccent;
        final halfS = s / 2;
        final path = Path()
          ..moveTo(pos.dx, pos.dy - halfS)
          ..lineTo(pos.dx + halfS, pos.dy)
          ..lineTo(pos.dx, pos.dy + halfS)
          ..lineTo(pos.dx - halfS, pos.dy)
          ..close();
        canvas.drawPath(path, markerPaint);
        break;

      case SnapType.intersection:
        // 교차: X
        markerPaint.color = Colors.yellowAccent;
        final halfS = s / 2;
        canvas.drawLine(Offset(pos.dx - halfS, pos.dy - halfS), Offset(pos.dx + halfS, pos.dy + halfS), markerPaint);
        canvas.drawLine(Offset(pos.dx + halfS, pos.dy - halfS), Offset(pos.dx - halfS, pos.dy + halfS), markerPaint);
        break;

      case SnapType.insertion:
        // 삽입점: 사각형 안에 십자 ⊞
        markerPaint.color = Colors.yellow;
        final halfS = s / 2;
        final rect = Rect.fromCenter(center: pos, width: s, height: s);
        canvas.drawRect(rect, markerPaint);
        canvas.drawLine(Offset(pos.dx - halfS, pos.dy), Offset(pos.dx + halfS, pos.dy), markerPaint);
        canvas.drawLine(Offset(pos.dx, pos.dy - halfS), Offset(pos.dx, pos.dy + halfS), markerPaint);
        break;

      case SnapType.perpendicular:
        // 수직: ⊥ 기호
        markerPaint.color = Colors.greenAccent;
        final halfS = s / 2;
        canvas.drawLine(Offset(pos.dx - halfS, pos.dy + halfS), Offset(pos.dx + halfS, pos.dy + halfS), markerPaint);
        canvas.drawLine(Offset(pos.dx, pos.dy - halfS), Offset(pos.dx, pos.dy + halfS), markerPaint);
        break;

      case SnapType.tangent:
        // 접선: 원 위에 수평선
        markerPaint.color = Colors.greenAccent;
        final halfS = s / 2;
        canvas.drawCircle(pos, halfS * 0.7, markerPaint);
        canvas.drawLine(Offset(pos.dx - halfS, pos.dy - halfS * 0.7), Offset(pos.dx + halfS, pos.dy - halfS * 0.7), markerPaint);
        break;

      case SnapType.nearest:
        // 최근점: 모래시계 ⌛
        markerPaint.color = Colors.greenAccent;
        final halfS = s / 2;
        final path = Path()
          ..moveTo(pos.dx - halfS, pos.dy - halfS)
          ..lineTo(pos.dx + halfS, pos.dy - halfS)
          ..lineTo(pos.dx - halfS, pos.dy + halfS)
          ..lineTo(pos.dx + halfS, pos.dy + halfS)
          ..close();
        canvas.drawPath(path, markerPaint);
        break;
    }

    // 스냅 좌표 텍스트 (2줄: N, E)
    const coordStyle = TextStyle(
      color: Colors.white,
      fontSize: 11,
      backgroundColor: Color(0xAA000000),
    );
    final tp1 = TextPainter(
      text: TextSpan(text: 'N ${snap.dxfY.toStringAsFixed(4)}', style: coordStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final tp2 = TextPainter(
      text: TextSpan(text: 'E ${snap.dxfX.toStringAsFixed(4)}', style: coordStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    tp1.paint(canvas, Offset(pos.dx + s, pos.dy - s - 4));
    tp2.paint(canvas, Offset(pos.dx + s, pos.dy - s - 4 + tp1.height + 2));
  }

  @override
  bool shouldRepaint(covariant SnapOverlayPainter oldDelegate) {
    return oldDelegate.touchPoint != touchPoint ||
        oldDelegate.activeSnap != activeSnap ||
        oldDelegate.highlightEntity != highlightEntity;
  }
}

/// 확정된 포인트 표식을 DXF 좌표 기반으로 그리는 Painter
/// 줌/팬 시에도 DXF 좌표가 유지됨
class ConfirmedPointsPainter extends CustomPainter {
  final List<({SnapType type, double dxfX, double dxfY})> points;
  final Offset Function(double, double)? transformPoint;

  static const double _markerSize = 14.0;

  ConfirmedPointsPainter({
    required this.points,
    this.transformPoint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (transformPoint == null || points.isEmpty) return;

    for (final pt in points) {
      final pos = transformPoint!(pt.dxfX, pt.dxfY);
      _drawConfirmedMarker(canvas, pos, pt.type);
      _drawCoordLabel(canvas, pos, pt.dxfX, pt.dxfY);
    }
  }

  /// 확정 포인트 옆에 좌표 2줄 표시
  void _drawCoordLabel(Canvas canvas, Offset pos, double dxfX, double dxfY) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 11,
      backgroundColor: Color(0xAA000000),
    );
    final tp1 = TextPainter(
      text: TextSpan(text: 'N ${dxfY.toStringAsFixed(4)}', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final tp2 = TextPainter(
      text: TextSpan(text: 'E ${dxfX.toStringAsFixed(4)}', style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    final x = pos.dx + _markerSize + 4;
    final y = pos.dy - tp1.height;
    tp1.paint(canvas, Offset(x, y));
    tp2.paint(canvas, Offset(x, y + tp1.height + 2));
  }

  void _drawConfirmedMarker(Canvas canvas, Offset pos, SnapType type) {
    const s = _markerSize;
    final halfS = s / 2;

    final markerPaint = Paint()
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    // 스냅 타입별 색상
    switch (type) {
      case SnapType.center:
        markerPaint.color = const Color(0xFFFF40FF);
        break;
      case SnapType.intersection:
        markerPaint.color = Colors.yellowAccent;
        break;
      case SnapType.node:
        markerPaint.color = Colors.cyanAccent;
        break;
      case SnapType.insertion:
        markerPaint.color = Colors.yellow;
        break;
      default:
        markerPaint.color = Colors.greenAccent;
        break;
    }

    // 빨간 십자 + 원 (확정 표식 공통)
    final confirmPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    // 원형 외곽
    canvas.drawCircle(pos, halfS + 2, confirmPaint);

    // 십자
    canvas.drawLine(
      Offset(pos.dx - halfS, pos.dy),
      Offset(pos.dx + halfS, pos.dy),
      confirmPaint,
    );
    canvas.drawLine(
      Offset(pos.dx, pos.dy - halfS),
      Offset(pos.dx, pos.dy + halfS),
      confirmPaint,
    );

    // 내부에 스냅 타입 표시 (작은 점)
    canvas.drawCircle(
      pos,
      3.0,
      Paint()
        ..color = markerPaint.color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant ConfirmedPointsPainter oldDelegate) {
    return oldDelegate.points.length != points.length ||
        oldDelegate.transformPoint != transformPoint;
  }
}
