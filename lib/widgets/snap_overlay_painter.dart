import 'dart:math';
import 'package:flutter/material.dart';

/// 스냅 유형 (우선순위: intersection > endpoint > center > node)
enum SnapType {
  intersection, // 교차 스냅 (엔티티 간 교차점) - 최우선
  endpoint, // 엔드포인트 스냅 (선/폴리라인 끝점)
  center, // 센터 스냅 (원/호의 중심)
  node, // 노드 스냅 (POINT 엔티티)
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

  /// 커서 그리기: 터치 위치에서 11시 방향으로 3cm 라인 + 화살촉
  void _drawCursor(Canvas canvas, Offset touch) {
    // 3cm를 픽셀로 변환 (모바일 기준 약 160dpi → 1cm ≈ 63px)
    // 하지만 실제로는 MediaQuery에서 가져와야 정확. 일단 약 38px/cm (96dpi) 기준
    const double pixelsPerCm = 38.0;
    final lineLength = _cursorLineLengthCm * pixelsPerCm;

    // 11시 방향 = 150도 (시계 반대, 수학 각도 기준)
    final angleRad = _cursorAngleDeg * pi / 180.0;
    final dx = cos(angleRad) * lineLength;
    final dy = -sin(angleRad) * lineLength; // Y축 반전 (화면 좌표)

    final tipPoint = Offset(touch.dx + dx, touch.dy + dy);

    // 커서 라인
    final cursorPaint = Paint()
      ..color = Colors.yellowAccent
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    canvas.drawLine(touch, tipPoint, cursorPaint);

    // 화살촉 (tip → 양쪽으로 벌어진 두 선)
    final arrowAngle = atan2(dy, dx); // 라인 방향 각도
    const arrowSpread = 25.0 * pi / 180.0; // 화살촉 벌림 각도

    final arrow1 = Offset(
      tipPoint.dx - _arrowHeadSize * cos(arrowAngle - arrowSpread),
      tipPoint.dy - _arrowHeadSize * sin(arrowAngle - arrowSpread),
    );
    final arrow2 = Offset(
      tipPoint.dx - _arrowHeadSize * cos(arrowAngle + arrowSpread),
      tipPoint.dy - _arrowHeadSize * sin(arrowAngle + arrowSpread),
    );

    final arrowPaint = Paint()
      ..color = Colors.yellowAccent
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    canvas.drawLine(tipPoint, arrow1, arrowPaint);
    canvas.drawLine(tipPoint, arrow2, arrowPaint);

    // 터치 위치에 작은 점
    canvas.drawCircle(
      touch,
      3.0,
      Paint()
        ..color = Colors.yellowAccent
        ..style = PaintingStyle.fill,
    );
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
        // AutoCAD 엔드포인트: 채워진 사각형
        markerPaint.color = Colors.greenAccent;
        final rect = Rect.fromCenter(center: pos, width: s, height: s);
        canvas.drawRect(
          rect,
          Paint()
            ..color = Colors.greenAccent
            ..style = PaintingStyle.fill,
        );
        canvas.drawRect(rect, markerPaint);
        break;

      case SnapType.center:
        // AutoCAD 센터: 원 안에 십자
        markerPaint.color = const Color(0xFFFF40FF);
        final halfS = s / 2;
        canvas.drawCircle(pos, halfS, markerPaint);
        // 십자
        canvas.drawLine(
          Offset(pos.dx - halfS, pos.dy),
          Offset(pos.dx + halfS, pos.dy),
          markerPaint,
        );
        canvas.drawLine(
          Offset(pos.dx, pos.dy - halfS),
          Offset(pos.dx, pos.dy + halfS),
          markerPaint,
        );
        break;

      case SnapType.intersection:
        // AutoCAD 교차: X 표식
        markerPaint.color = Colors.yellowAccent;
        final halfS = s / 2;
        canvas.drawLine(
          Offset(pos.dx - halfS, pos.dy - halfS),
          Offset(pos.dx + halfS, pos.dy + halfS),
          markerPaint,
        );
        canvas.drawLine(
          Offset(pos.dx + halfS, pos.dy - halfS),
          Offset(pos.dx - halfS, pos.dy + halfS),
          markerPaint,
        );
        break;

      case SnapType.node:
        // AutoCAD 노드: 원 안에 X
        markerPaint.color = Colors.cyanAccent;
        final halfS = s / 2;
        canvas.drawCircle(pos, halfS, markerPaint);
        final inner = halfS * 0.6;
        canvas.drawLine(
          Offset(pos.dx - inner, pos.dy - inner),
          Offset(pos.dx + inner, pos.dy + inner),
          markerPaint,
        );
        canvas.drawLine(
          Offset(pos.dx + inner, pos.dy - inner),
          Offset(pos.dx - inner, pos.dy + inner),
          markerPaint,
        );
        break;
    }

    // 스냅 좌표 텍스트
    final textSpan = TextSpan(
      text:
          '${snap.dxfX.toStringAsFixed(3)}, ${snap.dxfY.toStringAsFixed(3)}',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        backgroundColor: Color(0xAA000000),
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(pos.dx + s, pos.dy - s - 4));
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
    }
  }

  void _drawConfirmedMarker(Canvas canvas, Offset pos, SnapType type) {
    const s = _markerSize;
    final halfS = s / 2;

    final markerPaint = Paint()
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    // 스냅 타입별 색상
    switch (type) {
      case SnapType.endpoint:
        markerPaint.color = Colors.greenAccent;
        break;
      case SnapType.center:
        markerPaint.color = const Color(0xFFFF40FF);
        break;
      case SnapType.intersection:
        markerPaint.color = Colors.yellowAccent;
        break;
      case SnapType.node:
        markerPaint.color = Colors.cyanAccent;
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
