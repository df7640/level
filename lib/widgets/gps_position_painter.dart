import 'package:flutter/material.dart';

/// GPS 위치 마커를 DXF 도면 위에 렌더링하는 CustomPainter
class GpsPositionPainter extends CustomPainter {
  final double tmX; // EPSG:5186 Easting (= DXF X)
  final double tmY; // EPSG:5186 Northing (= DXF Y)
  final int fixQuality; // 0=무효, 1=GPS, 2=DGPS, 4=RTK, 5=Float
  final Offset Function(double, double) transformPoint;

  GpsPositionPainter({
    required this.tmX,
    required this.tmY,
    required this.fixQuality,
    required this.transformPoint,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final screenPos = transformPoint(tmX, tmY);

    // 화면 밖이면 그리지 않음
    if (screenPos.dx < -50 || screenPos.dx > size.width + 50 ||
        screenPos.dy < -50 || screenPos.dy > size.height + 50) return;

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
        oldDelegate.fixQuality != fixQuality;
  }
}
