import 'dart:math';
import 'package:flutter/material.dart';

/// GPS 위치 마커를 DXF 도면 위에 렌더링하는 CustomPainter
class GpsPositionPainter extends CustomPainter {
  final double tmX; // EPSG:5186 Easting (= DXF X)
  final double tmY; // EPSG:5186 Northing (= DXF Y)
  final int fixQuality; // 0=무효, 1=GPS, 2=DGPS, 4=RTK, 5=Float
  final Offset Function(double, double) transformPoint;
  final double? targetDxfX; // 측설 대상 X
  final double? targetDxfY; // 측설 대상 Y

  GpsPositionPainter({
    required this.tmX,
    required this.tmY,
    required this.fixQuality,
    required this.transformPoint,
    this.targetDxfX,
    this.targetDxfY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final screenPos = transformPoint(tmX, tmY);

    // 화면 밖이면 그리지 않음 (마커 부분만 — 측설 라인은 그릴 수 있음)
    final gpsOnScreen = screenPos.dx > -50 && screenPos.dx < size.width + 50 &&
        screenPos.dy > -50 && screenPos.dy < size.height + 50;

    // 측설 타겟 렌더링
    if (targetDxfX != null && targetDxfY != null) {
      final targetScreen = transformPoint(targetDxfX!, targetDxfY!);
      _drawStakeoutTarget(canvas, screenPos, targetScreen);
    }

    if (!gpsOnScreen) return;

    final color = _getFixColor();

    // 외곽 반투명 원 (정확도 표시)
    canvas.drawCircle(
      screenPos,
      20.0,
      Paint()..color = color.withValues(alpha: 0.2),
    );

    // 외곽 테두리
    canvas.drawCircle(
      screenPos,
      20.0,
      Paint()
        ..color = color.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 내부 채움 원
    canvas.drawCircle(
      screenPos,
      8.0,
      Paint()..color = color,
    );

    // 내부 흰색 점
    canvas.drawCircle(
      screenPos,
      3.0,
      Paint()..color = Colors.white,
    );

    // Fix 품질 라벨
    final label = _getFixLabel();
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
          shadows: const [
            Shadow(color: Colors.black, blurRadius: 3),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(screenPos.dx - tp.width / 2, screenPos.dy + 24));
  }

  /// 측설 타겟: 십자 마커 + GPS→타겟 연결선
  void _drawStakeoutTarget(Canvas canvas, Offset gpsScreen, Offset targetScreen) {
    // GPS → 타겟 연결선 (점선)
    final linePaint = Paint()
      ..color = Colors.yellowAccent.withValues(alpha: 0.8)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    // 점선 그리기
    final dx = targetScreen.dx - gpsScreen.dx;
    final dy = targetScreen.dy - gpsScreen.dy;
    final length = sqrt(dx * dx + dy * dy);
    if (length > 1) {
      const dashLen = 8.0;
      const gapLen = 5.0;
      final ux = dx / length;
      final uy = dy / length;
      double t = 0;
      final path = Path();
      while (t < length) {
        final end = (t + dashLen).clamp(0.0, length);
        path.moveTo(gpsScreen.dx + ux * t, gpsScreen.dy + uy * t);
        path.lineTo(gpsScreen.dx + ux * end, gpsScreen.dy + uy * end);
        t = end + gapLen;
      }
      canvas.drawPath(path, linePaint);
    }

    // 타겟 십자 마커
    const crossSize = 16.0;
    final crossPaint = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke;

    // 십자
    canvas.drawLine(
      Offset(targetScreen.dx - crossSize, targetScreen.dy),
      Offset(targetScreen.dx + crossSize, targetScreen.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(targetScreen.dx, targetScreen.dy - crossSize),
      Offset(targetScreen.dx, targetScreen.dy + crossSize),
      crossPaint,
    );

    // 타겟 원 (반투명 빨강)
    canvas.drawCircle(
      targetScreen,
      crossSize,
      Paint()
        ..color = Colors.red.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      targetScreen,
      crossSize,
      Paint()
        ..color = Colors.redAccent.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // 타겟 중심 점
    canvas.drawCircle(
      targetScreen,
      3.0,
      Paint()..color = Colors.red,
    );

    // 타겟 좌표 표시 (2줄)
    final coordLine1 = 'N ${targetDxfY!.toStringAsFixed(4)}';
    final coordLine2 = 'E ${targetDxfX!.toStringAsFixed(4)}';

    final bgPaint = Paint()..color = Colors.white.withValues(alpha: 0.85);
    const coordStyle = TextStyle(
      fontSize: 11,
      color: Colors.black,
      fontWeight: FontWeight.bold,
    );

    final tp1 = TextPainter(
      text: TextSpan(text: coordLine1, style: coordStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final tp2 = TextPainter(
      text: TextSpan(text: coordLine2, style: coordStyle),
      textDirection: TextDirection.ltr,
    )..layout();

    final textW = tp1.width > tp2.width ? tp1.width : tp2.width;
    final textH = tp1.height + tp2.height + 4;
    final textX = targetScreen.dx + crossSize + 4;
    final textY = targetScreen.dy - textH / 2;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(textX - 3, textY - 2, textW + 6, textH + 4),
        const Radius.circular(4),
      ),
      bgPaint,
    );
    tp1.paint(canvas, Offset(textX, textY));
    tp2.paint(canvas, Offset(textX, textY + tp1.height + 2));
  }

  Color _getFixColor() {
    switch (fixQuality) {
      case 4: return Colors.green;       // RTK Fixed
      case 5: return Colors.yellow;      // RTK Float
      case 2: return Colors.orange;      // DGPS
      case 1: return Colors.orange;      // GPS
      default: return Colors.red;        // No fix
    }
  }

  String _getFixLabel() {
    switch (fixQuality) {
      case 4: return 'RTK';
      case 5: return 'Float';
      case 2: return 'DGPS';
      case 1: return 'GPS';
      default: return 'N/A';
    }
  }

  @override
  bool shouldRepaint(covariant GpsPositionPainter oldDelegate) {
    return oldDelegate.tmX != tmX ||
        oldDelegate.tmY != tmY ||
        oldDelegate.fixQuality != fixQuality ||
        oldDelegate.targetDxfX != targetDxfX ||
        oldDelegate.targetDxfY != targetDxfY;
  }
}
