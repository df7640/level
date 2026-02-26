import 'dart:math';
import 'package:flutter/material.dart';
import '../models/dimension_data.dart';
import 'snap_overlay_painter.dart';

/// 치수선(Dimension Line) Painter
/// AutoCAD 스타일: 포인트 → 보조선(extension line) → 치수선 + 화살촉 + 거리/각도 텍스트
class DimensionPainter extends CustomPainter {
  /// 확정된 치수 결과
  final List<DimensionResult> results;
  /// 진행 중인 첫 번째 점
  final ({SnapType type, double dxfX, double dxfY})? firstPoint;
  /// 각도 치수용 두 번째 점 (꼭짓점)
  final ({SnapType type, double dxfX, double dxfY})? secondPoint;
  /// 배치 대기 중인 치수
  final ({double x1, double y1, double x2, double y2, double value, DimensionType type, double? x3, double? y3})? pending;
  /// 배치 드래그 위치 (DXF 좌표)
  final Offset? placementDxf;
  final Offset Function(double, double)? transformPoint;
  /// 전역 기본 스타일
  final DimensionStyle defaultStyle;
  /// 선택된 치수 인덱스 (편집/삭제 하이라이트)
  final int? selectedDimIndex;

  DimensionPainter({
    required this.results,
    this.firstPoint,
    this.secondPoint,
    this.pending,
    this.placementDxf,
    this.transformPoint,
    this.defaultStyle = const DimensionStyle(),
    this.selectedDimIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (transformPoint == null) return;

    // 확정된 치수선 그리기
    for (int i = 0; i < results.length; i++) {
      final dim = results[i];
      final isSelected = i == selectedDimIndex;
      switch (dim.type) {
        case DimensionType.aligned:
          _drawAlignedDimension(canvas, dim, isSelected);
          break;
        case DimensionType.horizontal:
          _drawHorizontalDimension(canvas, dim, isSelected);
          break;
        case DimensionType.vertical:
          _drawVerticalDimension(canvas, dim, isSelected);
          break;
        case DimensionType.angular:
          _drawAngularDimension(canvas, dim, isSelected);
          break;
      }
    }

    // 배치 대기 중인 치수 (프리뷰)
    if (pending != null && placementDxf != null) {
      switch (pending!.type) {
        case DimensionType.aligned:
          _drawAlignedPreview(canvas);
          break;
        case DimensionType.horizontal:
          _drawHorizontalPreview(canvas);
          break;
        case DimensionType.vertical:
          _drawVerticalPreview(canvas);
          break;
        case DimensionType.angular:
          _drawAngularPreview(canvas);
          break;
      }
    }

    // 진행 중인 첫 번째 점 마커
    if (firstPoint != null) {
      final pos = transformPoint!(firstPoint!.dxfX, firstPoint!.dxfY);
      _drawPointMarker(canvas, pos, Colors.redAccent);
    }
    // 각도 치수용 두 번째 점 마커
    if (secondPoint != null) {
      final pos = transformPoint!(secondPoint!.dxfX, secondPoint!.dxfY);
      _drawPointMarker(canvas, pos, Colors.orangeAccent);
    }
  }

  // ─────────────────────────────────────────────────────
  // 정렬(사선) 치수 (기존 로직)
  // ─────────────────────────────────────────────────────

  void _drawAlignedDimension(Canvas canvas, DimensionResult dim, bool isSelected) {
    final style = dim.style;
    final offsetDxf = Offset(dim.offsetX, dim.offsetY);
    _drawAligned(canvas, dim.x1, dim.y1, dim.x2, dim.y2, dim.value, offsetDxf, style, isSelected, false);
  }

  void _drawAlignedPreview(Canvas canvas) {
    final p = pending!;
    _drawAligned(canvas, p.x1, p.y1, p.x2, p.y2, p.value, placementDxf!, defaultStyle, false, true);
  }

  void _drawAligned(
    Canvas canvas,
    double x1, double y1, double x2, double y2,
    double value, Offset offsetDxf, DimensionStyle style,
    bool isSelected, bool isPreview,
  ) {
    final p1 = transformPoint!(x1, y1);
    final p2 = transformPoint!(x2, y2);

    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final length = sqrt(dx * dx + dy * dy);
    if (length < 1.0) return;

    final ux = dx / length;
    final uy = dy / length;
    final nx = -uy;
    final ny = ux;

    final oScreen = transformPoint!(offsetDxf.dx, offsetDxf.dy);
    final toOx = oScreen.dx - p1.dx;
    final toOy = oScreen.dy - p1.dy;
    final dimOffset = toOx * nx + toOy * ny;

    final dp1 = Offset(p1.dx + nx * dimOffset, p1.dy + ny * dimOffset);
    final dp2 = Offset(p2.dx + nx * dimOffset, p2.dy + ny * dimOffset);

    final alpha = isPreview ? 0.6 : 1.0;
    final dimColor = isSelected
        ? Colors.cyanAccent.withValues(alpha: alpha)
        : style.color.withValues(alpha: alpha);

    _drawDimLine(canvas, dp1, dp2, dimColor, style);
    _drawArrowhead(canvas, dp1, ux, uy, dimColor, style.arrowStyle, style.arrowSize);
    _drawArrowhead(canvas, dp2, -ux, -uy, dimColor, style.arrowStyle, style.arrowSize);

    final sign = dimOffset >= 0 ? 1.0 : -1.0;
    _drawExtensionLines(canvas, p1, p2, dp1, dp2, nx, ny, sign, dimColor, style);
    _drawValueText(canvas, dp1, dp2, value, dx, dy, nx, ny, sign, dimColor, style, false);
    _drawEndMarker(canvas, p1, dimColor);
    _drawEndMarker(canvas, p2, dimColor);
  }

  // ─────────────────────────────────────────────────────
  // 수평 치수
  // ─────────────────────────────────────────────────────

  void _drawHorizontalDimension(Canvas canvas, DimensionResult dim, bool isSelected) {
    final style = dim.style;
    _drawHorizontal(canvas, dim.x1, dim.y1, dim.x2, dim.y2, dim.value,
        dim.offsetX, dim.offsetY, style, isSelected, false);
  }

  void _drawHorizontalPreview(Canvas canvas) {
    final p = pending!;
    _drawHorizontal(canvas, p.x1, p.y1, p.x2, p.y2, p.value,
        placementDxf!.dx, placementDxf!.dy, defaultStyle, false, true);
  }

  void _drawHorizontal(
    Canvas canvas,
    double x1, double y1, double x2, double y2,
    double value, double offsetX, double offsetY,
    DimensionStyle style, bool isSelected, bool isPreview,
  ) {
    final p1 = transformPoint!(x1, y1);
    final p2 = transformPoint!(x2, y2);

    // 치수선 양 끝점: X는 원래 점, Y는 배치 위치
    final dp1 = transformPoint!(x1, offsetY);
    final dp2 = transformPoint!(x2, offsetY);

    final alpha = isPreview ? 0.6 : 1.0;
    final dimColor = isSelected
        ? Colors.cyanAccent.withValues(alpha: alpha)
        : style.color.withValues(alpha: alpha);

    // 치수선 방향 (항상 수평)
    final hDx = dp2.dx - dp1.dx;
    final hLen = hDx.abs();
    if (hLen < 1.0) return;
    final ux = hDx > 0 ? 1.0 : -1.0;

    _drawDimLine(canvas, dp1, dp2, dimColor, style);
    _drawArrowhead(canvas, dp1, ux, 0, dimColor, style.arrowStyle, style.arrowSize);
    _drawArrowhead(canvas, dp2, -ux, 0, dimColor, style.arrowStyle, style.arrowSize);

    // 보조선: 원래 점에서 치수선까지 (수직 방향)
    final extColor = dimColor.withValues(alpha: (isPreview ? 0.6 : 1.0) * 0.5);
    final extPaint = Paint()
      ..color = extColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final sign1 = dp1.dy < p1.dy ? -1.0 : 1.0;
    canvas.drawLine(
      Offset(p1.dx, p1.dy - style.extensionGap * sign1),
      Offset(dp1.dx, dp1.dy + style.extensionOvershoot * sign1),
      extPaint,
    );
    final sign2 = dp2.dy < p2.dy ? -1.0 : 1.0;
    canvas.drawLine(
      Offset(p2.dx, p2.dy - style.extensionGap * sign2),
      Offset(dp2.dx, dp2.dy + style.extensionOvershoot * sign2),
      extPaint,
    );

    // 텍스트
    _drawValueText(canvas, dp1, dp2, value, hDx, 0, 0, -1, 1, dimColor, style, false);
    _drawEndMarker(canvas, p1, dimColor);
    _drawEndMarker(canvas, p2, dimColor);
  }

  // ─────────────────────────────────────────────────────
  // 수직 치수
  // ─────────────────────────────────────────────────────

  void _drawVerticalDimension(Canvas canvas, DimensionResult dim, bool isSelected) {
    final style = dim.style;
    _drawVertical(canvas, dim.x1, dim.y1, dim.x2, dim.y2, dim.value,
        dim.offsetX, dim.offsetY, style, isSelected, false);
  }

  void _drawVerticalPreview(Canvas canvas) {
    final p = pending!;
    _drawVertical(canvas, p.x1, p.y1, p.x2, p.y2, p.value,
        placementDxf!.dx, placementDxf!.dy, defaultStyle, false, true);
  }

  void _drawVertical(
    Canvas canvas,
    double x1, double y1, double x2, double y2,
    double value, double offsetX, double offsetY,
    DimensionStyle style, bool isSelected, bool isPreview,
  ) {
    final p1 = transformPoint!(x1, y1);
    final p2 = transformPoint!(x2, y2);

    // 치수선 양 끝점: Y는 원래 점, X는 배치 위치
    final dp1 = transformPoint!(offsetX, y1);
    final dp2 = transformPoint!(offsetX, y2);

    final alpha = isPreview ? 0.6 : 1.0;
    final dimColor = isSelected
        ? Colors.cyanAccent.withValues(alpha: alpha)
        : style.color.withValues(alpha: alpha);

    final vDy = dp2.dy - dp1.dy;
    final vLen = vDy.abs();
    if (vLen < 1.0) return;
    final uy = vDy > 0 ? 1.0 : -1.0;

    _drawDimLine(canvas, dp1, dp2, dimColor, style);
    _drawArrowhead(canvas, dp1, 0, uy, dimColor, style.arrowStyle, style.arrowSize);
    _drawArrowhead(canvas, dp2, 0, -uy, dimColor, style.arrowStyle, style.arrowSize);

    // 보조선: 원래 점에서 치수선까지 (수평 방향)
    final extColor = dimColor.withValues(alpha: (isPreview ? 0.6 : 1.0) * 0.5);
    final extPaint = Paint()
      ..color = extColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final sign1 = dp1.dx < p1.dx ? -1.0 : 1.0;
    canvas.drawLine(
      Offset(p1.dx - style.extensionGap * sign1, p1.dy),
      Offset(dp1.dx + style.extensionOvershoot * sign1, dp1.dy),
      extPaint,
    );
    final sign2 = dp2.dx < p2.dx ? -1.0 : 1.0;
    canvas.drawLine(
      Offset(p2.dx - style.extensionGap * sign2, p2.dy),
      Offset(dp2.dx + style.extensionOvershoot * sign2, dp2.dy),
      extPaint,
    );

    // 텍스트 (수직이므로 90도 회전)
    _drawValueText(canvas, dp1, dp2, value, 0, vDy, -1, 0, 1, dimColor, style, false);
    _drawEndMarker(canvas, p1, dimColor);
    _drawEndMarker(canvas, p2, dimColor);
  }

  // ─────────────────────────────────────────────────────
  // 각도 치수
  // ─────────────────────────────────────────────────────

  void _drawAngularDimension(Canvas canvas, DimensionResult dim, bool isSelected) {
    if (dim.x3 == null || dim.y3 == null) return;
    final style = dim.style;
    _drawAngular(canvas, dim.x1, dim.y1, dim.x2, dim.y2, dim.x3!, dim.y3!,
        dim.value, dim.offsetX, dim.offsetY, style, isSelected, false);
  }

  void _drawAngularPreview(Canvas canvas) {
    final p = pending!;
    if (p.x3 == null || p.y3 == null) return;
    _drawAngular(canvas, p.x1, p.y1, p.x2, p.y2, p.x3!, p.y3!,
        p.value, placementDxf!.dx, placementDxf!.dy, defaultStyle, false, true);
  }

  void _drawAngular(
    Canvas canvas,
    double x1, double y1, // 방향점1
    double x2, double y2, // 방향점2
    double x3, double y3, // 꼭짓점
    double angleDeg,
    double offsetX, double offsetY,
    DimensionStyle style, bool isSelected, bool isPreview,
  ) {
    final vertex = transformPoint!(x3, y3);
    final dir1 = transformPoint!(x1, y1);
    final dir2 = transformPoint!(x2, y2);
    final offsetScreen = transformPoint!(offsetX, offsetY);

    // 호 반지름: 꼭짓점에서 배치 위치까지 거리
    final radius = (offsetScreen - vertex).distance;
    if (radius < 5.0) return;

    // 화면 좌표 기준 각도 계산
    final angle1 = atan2(dir1.dy - vertex.dy, dir1.dx - vertex.dx);
    final angle2 = atan2(dir2.dy - vertex.dy, dir2.dx - vertex.dx);

    // 시작/종료 각도 정렬 (CCW 방향)
    double startAngle = angle1;
    double sweepAngle = angle2 - angle1;
    // 항상 짧은 호 선택
    if (sweepAngle > pi) sweepAngle -= 2 * pi;
    if (sweepAngle < -pi) sweepAngle += 2 * pi;

    final alpha = isPreview ? 0.6 : 1.0;
    final dimColor = isSelected
        ? Colors.cyanAccent.withValues(alpha: alpha)
        : style.color.withValues(alpha: alpha);

    final arcPaint = Paint()
      ..color = dimColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // 호 그리기
    final rect = Rect.fromCircle(center: vertex, radius: radius);
    canvas.drawArc(rect, startAngle, sweepAngle, false, arcPaint);

    // 화살촉 (호의 양 끝에)
    final ep1 = Offset(
      vertex.dx + radius * cos(startAngle),
      vertex.dy + radius * sin(startAngle),
    );
    final ep2 = Offset(
      vertex.dx + radius * cos(startAngle + sweepAngle),
      vertex.dy + radius * sin(startAngle + sweepAngle),
    );

    // 호 접선 방향 화살촉
    final tangent1x = -sin(startAngle);
    final tangent1y = cos(startAngle);
    if (sweepAngle >= 0) {
      _drawArrowhead(canvas, ep1, -tangent1x, -tangent1y, dimColor, style.arrowStyle, style.arrowSize);
    } else {
      _drawArrowhead(canvas, ep1, tangent1x, tangent1y, dimColor, style.arrowStyle, style.arrowSize);
    }
    final endTanAngle = startAngle + sweepAngle;
    final tangent2x = -sin(endTanAngle);
    final tangent2y = cos(endTanAngle);
    if (sweepAngle >= 0) {
      _drawArrowhead(canvas, ep2, tangent2x, tangent2y, dimColor, style.arrowStyle, style.arrowSize);
    } else {
      _drawArrowhead(canvas, ep2, -tangent2x, -tangent2y, dimColor, style.arrowStyle, style.arrowSize);
    }

    // 보조선 (꼭짓점에서 호 끝점 방향으로)
    final extColor = dimColor.withValues(alpha: alpha * 0.5);
    final extPaint = Paint()
      ..color = extColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final ext1Dir = Offset(cos(startAngle), sin(startAngle));
    canvas.drawLine(
      vertex + ext1Dir * style.extensionGap,
      ep1 + ext1Dir * style.extensionOvershoot,
      extPaint,
    );
    final ext2Dir = Offset(cos(startAngle + sweepAngle), sin(startAngle + sweepAngle));
    canvas.drawLine(
      vertex + ext2Dir * style.extensionGap,
      ep2 + ext2Dir * style.extensionOvershoot,
      extPaint,
    );

    // 각도 텍스트 (호 중간 지점)
    final midAngle = startAngle + sweepAngle / 2;
    final textPos = Offset(
      vertex.dx + radius * cos(midAngle),
      vertex.dy + radius * sin(midAngle),
    );

    final distText = '${angleDeg.toStringAsFixed(style.decimalPlaces)}\u00B0';
    final textSpan = TextSpan(
      text: distText,
      style: TextStyle(
        color: dimColor,
        fontSize: style.fontSize,
        fontWeight: FontWeight.bold,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    // 텍스트를 호 바깥쪽으로 약간 이동
    final textOffsetDist = textPainter.height / 2 + 3;
    final outDir = Offset(cos(midAngle), sin(midAngle));
    final textCenter = textPos + outDir * textOffsetDist;

    canvas.save();
    canvas.translate(textCenter.dx, textCenter.dy);

    // 텍스트 각도 (호 접선 방향)
    double textAngle = midAngle + pi / 2;
    if (textAngle > pi / 2 || textAngle < -pi / 2) {
      textAngle += pi;
    }
    canvas.rotate(textAngle);

    final bgRect = Rect.fromCenter(
      center: Offset.zero,
      width: textPainter.width + 8,
      height: textPainter.height + 4,
    );
    canvas.drawRect(bgRect, Paint()..color = Colors.black.withValues(alpha: 0.7));
    textPainter.paint(
      canvas,
      Offset(-textPainter.width / 2, -textPainter.height / 2),
    );
    canvas.restore();

    // 꼭짓점 마커
    _drawEndMarker(canvas, vertex, dimColor);
    _drawEndMarker(canvas, dir1, dimColor);
    _drawEndMarker(canvas, dir2, dimColor);
  }

  // ─────────────────────────────────────────────────────
  // 공통 유틸리티
  // ─────────────────────────────────────────────────────

  void _drawDimLine(Canvas canvas, Offset dp1, Offset dp2, Color color, DimensionStyle style) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(dp1, dp2, paint);
  }

  void _drawExtensionLines(
    Canvas canvas, Offset p1, Offset p2, Offset dp1, Offset dp2,
    double nx, double ny, double sign, Color color, DimensionStyle style,
  ) {
    final extColor = color.withValues(alpha: color.a * 0.5);
    final extPaint = Paint()
      ..color = extColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      Offset(p1.dx + nx * style.extensionGap * sign, p1.dy + ny * style.extensionGap * sign),
      Offset(dp1.dx + nx * style.extensionOvershoot * sign, dp1.dy + ny * style.extensionOvershoot * sign),
      extPaint,
    );
    canvas.drawLine(
      Offset(p2.dx + nx * style.extensionGap * sign, p2.dy + ny * style.extensionGap * sign),
      Offset(dp2.dx + nx * style.extensionOvershoot * sign, dp2.dy + ny * style.extensionOvershoot * sign),
      extPaint,
    );
  }

  void _drawValueText(
    Canvas canvas, Offset dp1, Offset dp2,
    double value, double dx, double dy, double nx, double ny, double sign,
    Color color, DimensionStyle style, bool isAngular,
  ) {
    final midX = (dp1.dx + dp2.dx) / 2;
    final midY = (dp1.dy + dp2.dy) / 2;
    final distText = isAngular
        ? '${value.toStringAsFixed(style.decimalPlaces)}\u00B0'
        : value.toStringAsFixed(style.decimalPlaces);

    final textSpan = TextSpan(
      text: distText,
      style: TextStyle(
        color: color,
        fontSize: style.fontSize,
        fontWeight: FontWeight.bold,
      ),
    );
    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();

    double angle = atan2(dy, dx);
    if (angle > pi / 2 || angle < -pi / 2) {
      angle += pi;
    }

    final textOffsetDist = textPainter.height / 2 + 3;
    final textCenterX = midX + nx * textOffsetDist * sign;
    final textCenterY = midY + ny * textOffsetDist * sign;

    canvas.save();
    canvas.translate(textCenterX, textCenterY);
    canvas.rotate(angle);

    final bgRect = Rect.fromCenter(
      center: Offset.zero,
      width: textPainter.width + 8,
      height: textPainter.height + 4,
    );
    canvas.drawRect(bgRect, Paint()..color = Colors.black.withValues(alpha: 0.7));
    textPainter.paint(canvas, Offset(-textPainter.width / 2, -textPainter.height / 2));
    canvas.restore();
  }

  void _drawArrowhead(Canvas canvas, Offset tip, double ux, double uy,
      Color color, ArrowStyle arrowStyle, double arrowSize) {
    switch (arrowStyle) {
      case ArrowStyle.filled:
        _drawFilledArrow(canvas, tip, ux, uy, color, arrowSize);
        break;
      case ArrowStyle.open:
        _drawOpenArrow(canvas, tip, ux, uy, color, arrowSize);
        break;
      case ArrowStyle.tick:
        _drawTickArrow(canvas, tip, ux, uy, color, arrowSize);
        break;
      case ArrowStyle.dot:
        _drawDotArrow(canvas, tip, color, arrowSize);
        break;
      case ArrowStyle.none:
        break;
    }
  }

  void _drawFilledArrow(Canvas canvas, Offset tip, double ux, double uy, Color color, double size) {
    const spread = 20.0 * pi / 180.0;
    final baseAngle = atan2(uy, ux);
    final a1 = Offset(
      tip.dx - size * cos(baseAngle - spread),
      tip.dy - size * sin(baseAngle - spread),
    );
    final a2 = Offset(
      tip.dx - size * cos(baseAngle + spread),
      tip.dy - size * sin(baseAngle + spread),
    );

    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(a1.dx, a1.dy)
      ..lineTo(a2.dx, a2.dy)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  void _drawOpenArrow(Canvas canvas, Offset tip, double ux, double uy, Color color, double size) {
    const spread = 20.0 * pi / 180.0;
    final baseAngle = atan2(uy, ux);
    final a1 = Offset(
      tip.dx - size * cos(baseAngle - spread),
      tip.dy - size * sin(baseAngle - spread),
    );
    final a2 = Offset(
      tip.dx - size * cos(baseAngle + spread),
      tip.dy - size * sin(baseAngle + spread),
    );

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(tip, a1, paint);
    canvas.drawLine(tip, a2, paint);
  }

  void _drawTickArrow(Canvas canvas, Offset tip, double ux, double uy, Color color, double size) {
    // 45도 빗금
    final halfSize = size * 0.7;
    final baseAngle = atan2(uy, ux);
    final tickAngle = baseAngle + pi / 4;
    final p1 = Offset(
      tip.dx - halfSize * cos(tickAngle),
      tip.dy - halfSize * sin(tickAngle),
    );
    final p2 = Offset(
      tip.dx + halfSize * cos(tickAngle),
      tip.dy + halfSize * sin(tickAngle),
    );
    final tickPaint = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(p1, p2, tickPaint);
  }

  void _drawDotArrow(Canvas canvas, Offset tip, Color color, double size) {
    canvas.drawCircle(
      tip,
      size * 0.3,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  void _drawEndMarker(Canvas canvas, Offset pos, Color color) {
    canvas.drawCircle(
      pos,
      4.0,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    canvas.drawCircle(
      pos,
      2.0,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  void _drawPointMarker(Canvas canvas, Offset pos, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    canvas.drawCircle(pos, 10.0, paint);
    canvas.drawLine(Offset(pos.dx - 7, pos.dy), Offset(pos.dx + 7, pos.dy), paint);
    canvas.drawLine(Offset(pos.dx, pos.dy - 7), Offset(pos.dx, pos.dy + 7), paint);

    canvas.drawCircle(
      pos,
      3.0,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant DimensionPainter oldDelegate) {
    return oldDelegate.results.length != results.length ||
        oldDelegate.firstPoint != firstPoint ||
        oldDelegate.secondPoint != secondPoint ||
        oldDelegate.pending != pending ||
        oldDelegate.placementDxf != placementDxf ||
        oldDelegate.transformPoint != transformPoint ||
        oldDelegate.selectedDimIndex != selectedDimIndex;
  }
}
