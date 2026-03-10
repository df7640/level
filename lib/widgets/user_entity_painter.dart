import 'dart:math';
import 'package:flutter/material.dart';

/// 사용자가 추가한 엔티티 (LINE, LEADER, TEXT) 렌더링
class UserEntityPainter extends CustomPainter {
  final List<Map<String, dynamic>> userEntities;
  final Offset Function(double, double) transformPoint;

  UserEntityPainter({
    required this.userEntities,
    required this.transformPoint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final entity in userEntities) {
      final type = entity['type'] as String;
      final color = Color(entity['color'] as int? ?? 0xFFFFFF00);
      final lw = (entity['lw'] as double?) ?? 1.0;

      switch (type) {
        case 'POINT':
          _drawPoint(canvas, entity, color, lw);
          break;
        case 'LINE':
          _drawLine(canvas, entity, color, lw);
          break;
        case 'LEADER':
          _drawLeader(canvas, entity, color, lw);
          break;
        case 'TEXT':
          _drawText(canvas, entity, color);
          break;
      }
    }
  }

  void _drawPoint(Canvas canvas, Map<String, dynamic> e, Color color, double lw) {
    final pos = transformPoint(e['x'] as double, e['y'] as double);
    final pdmode = (e['pdmode'] as int?) ?? 0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = lw
      ..style = PaintingStyle.stroke;
    const r = 6.0; // 화면 기준 반지름
    const s = r * 0.7;
    final cx = pos.dx;
    final cy = pos.dy;

    final base = pdmode & 7;
    final shape = pdmode & ~7;

    // 외형
    if (shape & 32 != 0) {
      canvas.drawCircle(pos, r, paint);
    }
    if (shape & 64 != 0) {
      canvas.drawRect(Rect.fromCenter(center: pos, width: r * 2, height: r * 2), paint);
    }

    // 기본 형상
    switch (base) {
      case 0:
      case 1:
        canvas.drawCircle(pos, 2, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
        break;
      case 2: // +
        canvas.drawLine(Offset(cx - s, cy), Offset(cx + s, cy), paint);
        canvas.drawLine(Offset(cx, cy - s), Offset(cx, cy + s), paint);
        break;
      case 3: // X
        canvas.drawLine(Offset(cx - s, cy - s), Offset(cx + s, cy + s), paint);
        canvas.drawLine(Offset(cx - s, cy + s), Offset(cx + s, cy - s), paint);
        break;
      case 4: // |
        canvas.drawLine(Offset(cx, cy), Offset(cx, cy - s), paint);
        break;
    }
  }

  void _drawLine(Canvas canvas, Map<String, dynamic> e, Color color, double lw) {
    final p1 = transformPoint(e['x1'] as double, e['y1'] as double);
    final p2 = transformPoint(e['x2'] as double, e['y2'] as double);
    canvas.drawLine(p1, p2, Paint()
      ..color = color
      ..strokeWidth = lw
      ..style = PaintingStyle.stroke);
  }

  void _drawLeader(Canvas canvas, Map<String, dynamic> e, Color color, double lw) {
    final points = e['points'] as List<Map<String, double>>;
    if (points.length < 2) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = lw
      ..style = PaintingStyle.stroke;

    // 지시선 라인
    final screenPoints = points.map((p) => transformPoint(p['x']!, p['y']!)).toList();
    for (int i = 0; i < screenPoints.length - 1; i++) {
      canvas.drawLine(screenPoints[i], screenPoints[i + 1], paint);
    }

    // 화살촉 (첫 번째 점에)
    if (screenPoints.length >= 2) {
      final tip = screenPoints[0];
      final from = screenPoints[1];
      final angle = atan2(tip.dy - from.dy, tip.dx - from.dx);
      const arrowLen = 12.0;
      const arrowAngle = 0.4; // ~23도
      final a1 = Offset(
        tip.dx - arrowLen * cos(angle - arrowAngle),
        tip.dy - arrowLen * sin(angle - arrowAngle),
      );
      final a2 = Offset(
        tip.dx - arrowLen * cos(angle + arrowAngle),
        tip.dy - arrowLen * sin(angle + arrowAngle),
      );
      canvas.drawLine(tip, a1, paint);
      canvas.drawLine(tip, a2, paint);
    }

    // 텍스트 (있으면 마지막 점 옆에)
    final text = e['text'] as String?;
    if (text != null && text.isNotEmpty) {
      final lastPt = screenPoints.last;
      final tp = TextPainter(
        text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 14)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, lastPt + const Offset(4, -8));
    }
  }

  void _drawText(Canvas canvas, Map<String, dynamic> e, Color color) {
    final pos = transformPoint(e['x'] as double, e['y'] as double);
    final text = e['text'] as String? ?? '';
    final double fontSize = (e['fontSize'] as double?) ?? 14.0;
    final tp = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: fontSize)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos + Offset(0, -tp.height));
  }

  @override
  bool shouldRepaint(covariant UserEntityPainter old) =>
      old.userEntities != userEntities;
}

/// 선택된 엔티티 하이라이트 렌더링
class SelectionHighlightPainter extends CustomPainter {
  final List<Map<String, dynamic>> selectedEntities;
  final Offset Function(double, double) transformPoint;
  final double scale;

  SelectionHighlightPainter({
    required this.selectedEntities,
    required this.transformPoint,
    required this.scale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (selectedEntities.isEmpty) return;

    final paint = Paint()
      ..color = Colors.cyan.withValues(alpha: 0.8)
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke;

    final dotPaint = Paint()
      ..color = Colors.cyan
      ..style = PaintingStyle.fill;

    for (final entity in selectedEntities) {
      final type = entity['type'] as String;
      switch (type) {
        case 'LINE':
          final p1 = transformPoint(entity['x1'] as double, entity['y1'] as double);
          final p2 = transformPoint(entity['x2'] as double, entity['y2'] as double);
          canvas.drawLine(p1, p2, paint);
          canvas.drawCircle(p1, 4, dotPaint);
          canvas.drawCircle(p2, 4, dotPaint);
          break;
        case 'LWPOLYLINE':
          final points = entity['points'] as List;
          final screenPts = <Offset>[];
          for (final pt in points) {
            screenPts.add(transformPoint(
              (pt as Map<String, dynamic>)['x'] as double,
              pt['y'] as double,
            ));
          }
          for (int i = 0; i < screenPts.length - 1; i++) {
            canvas.drawLine(screenPts[i], screenPts[i + 1], paint);
          }
          if (entity['closed'] == true && screenPts.length > 2) {
            canvas.drawLine(screenPts.last, screenPts.first, paint);
          }
          for (final pt in screenPts) {
            canvas.drawCircle(pt, 4, dotPaint);
          }
          break;
        case 'CIRCLE':
          final center = transformPoint(entity['cx'] as double, entity['cy'] as double);
          final r = (entity['radius'] as double) * scale;
          canvas.drawCircle(center, r, paint);
          canvas.drawCircle(center, 4, dotPaint);
          break;
        case 'ARC':
          final center = transformPoint(entity['cx'] as double, entity['cy'] as double);
          final r = (entity['radius'] as double) * scale;
          final startAngle = (entity['startAngle'] as double) * pi / 180;
          final endAngle = (entity['endAngle'] as double) * pi / 180;
          double sweep = endAngle - startAngle;
          if (sweep <= 0) sweep += 2 * pi;
          canvas.drawArc(
            Rect.fromCircle(center: center, radius: r),
            -startAngle, -sweep, false, paint,
          );
          canvas.drawCircle(center, 4, dotPaint);
          break;
        case 'TEXT':
          final pos = transformPoint(entity['x'] as double, entity['y'] as double);
          final text = entity['text'] as String? ?? '';
          // DXF TEXT는 height, 사용자 TEXT는 fontSize
          final height = (entity['height'] as double?) ?? 1.0;
          final fontSize = entity['fontSize'] as double?;
          final sh = fontSize ?? height * scale;
          canvas.drawRect(
            Rect.fromLTWH(pos.dx - 2, pos.dy - sh - 2, text.length * sh * 0.6 + 4, sh + 4),
            paint,
          );
          break;
        case 'LEADER':
          final pts = entity['points'] as List<Map<String, double>>;
          final screenPts = pts.map((p) => transformPoint(p['x']!, p['y']!)).toList();
          for (int i = 0; i < screenPts.length - 1; i++) {
            canvas.drawLine(screenPts[i], screenPts[i + 1], paint);
          }
          for (final pt in screenPts) {
            canvas.drawCircle(pt, 4, dotPaint);
          }
          break;
        case 'POINT':
          final pos = transformPoint(entity['x'] as double, entity['y'] as double);
          canvas.drawCircle(pos, 6, paint);
          canvas.drawCircle(pos, 4, dotPaint);
          break;
      }
    }
  }

  @override
  bool shouldRepaint(covariant SelectionHighlightPainter old) =>
      old.selectedEntities != selectedEntities;
}
