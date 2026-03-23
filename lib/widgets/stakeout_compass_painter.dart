import 'dart:math';
import 'package:flutter/material.dart';

/// 측설 나침반 CustomPainter
/// - 외부 원: 방위각 눈금 (N/E/S/W + 30도 단위)
/// - 내부: 목표 방향 화살표 + 거리 텍스트
/// - 이동방향 표시 삼각형
class StakeoutCompassPainter extends CustomPainter {
  /// 목표점까지의 방위각 (라디안, 북=0 시계방향)
  final double azimuthToTarget;

  /// 이동방향 방위각 (라디안, 북=0 시계방향). null이면 미표시
  final double? movingAzimuth;

  /// 목표점까지 거리 (m)
  final double distance;

  /// 허용 오차 (m)
  final double tolerance;

  /// FBLR 분해값
  final double? forward;
  final double? right;

  /// 목표점 이름
  final String targetName;

  /// 거리가 허용 오차 이내인지
  bool get isWithinTolerance => distance <= tolerance;

  StakeoutCompassPainter({
    required this.azimuthToTarget,
    this.movingAzimuth,
    required this.distance,
    required this.tolerance,
    this.forward,
    this.right,
    required this.targetName,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - 4;

    // 회전각: 이동방향이 있으면 이동방향을 위로, 없으면 북을 위로
    final rotation = movingAzimuth ?? 0.0;

    _drawOuterRing(canvas, center, radius, rotation);
    _drawTargetArrow(canvas, center, radius, rotation);
    _drawCenterInfo(canvas, center, radius);
    if (movingAzimuth != null) {
      _drawMovingDirectionMarker(canvas, center, radius);
    }
  }

  /// 외부 링: 방위 눈금 + NESW
  void _drawOuterRing(Canvas canvas, Offset center, double radius, double rotation) {
    final ringPaint = Paint()
      ..color = Colors.grey[700]!
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // 외곽 원
    canvas.drawCircle(center, radius, ringPaint);
    // 내곽 원
    canvas.drawCircle(center, radius * 0.85, ringPaint..strokeWidth = 0.5);

    // 눈금 (10도 단위)
    for (int deg = 0; deg < 360; deg += 10) {
      final angle = (deg * pi / 180) - rotation;
      final isMajor = deg % 30 == 0;
      final isCardinal = deg % 90 == 0;

      final outerR = radius;
      final innerR = isCardinal ? radius * 0.82 : isMajor ? radius * 0.87 : radius * 0.92;

      final p1 = Offset(
        center.dx + outerR * sin(angle),
        center.dy - outerR * cos(angle),
      );
      final p2 = Offset(
        center.dx + innerR * sin(angle),
        center.dy - innerR * cos(angle),
      );

      final tickPaint = Paint()
        ..color = isCardinal ? Colors.white : Colors.grey[400]!
        ..strokeWidth = isCardinal ? 2.0 : isMajor ? 1.5 : 0.8;

      canvas.drawLine(p1, p2, tickPaint);
    }

    // NESW 라벨
    const cardinals = ['N', 'E', 'S', 'W'];
    const cardinalColors = [Colors.red, Colors.white, Colors.white, Colors.white];
    for (int i = 0; i < 4; i++) {
      final angle = (i * 90 * pi / 180) - rotation;
      final labelR = radius * 0.75;
      final pos = Offset(
        center.dx + labelR * sin(angle),
        center.dy - labelR * cos(angle),
      );

      final tp = TextPainter(
        text: TextSpan(
          text: cardinals[i],
          style: TextStyle(
            color: cardinalColors[i],
            fontSize: radius * 0.14,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
    }

    // 30도 단위 숫자 (NESW 제외)
    for (int deg = 30; deg < 360; deg += 30) {
      if (deg % 90 == 0) continue;
      final angle = (deg * pi / 180) - rotation;
      final labelR = radius * 0.75;
      final pos = Offset(
        center.dx + labelR * sin(angle),
        center.dy - labelR * cos(angle),
      );

      final tp = TextPainter(
        text: TextSpan(
          text: '$deg',
          style: TextStyle(
            color: Colors.grey[400],
            fontSize: radius * 0.09,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
    }
  }

  /// 목표 방향 화살표
  void _drawTargetArrow(Canvas canvas, Offset center, double radius, double rotation) {
    final angle = azimuthToTarget - rotation;

    // 화살표 색: 허용 범위 이내면 녹색, 아니면 빨간색
    final arrowColor = isWithinTolerance ? Colors.greenAccent : Colors.orangeAccent;

    // 화살표 끝 (외곽 쪽)
    final tipR = radius * 0.62;
    final tip = Offset(
      center.dx + tipR * sin(angle),
      center.dy - tipR * cos(angle),
    );

    // 화살표 몸체 (중앙에서 시작)
    final bodyR = radius * 0.15;
    final bodyStart = Offset(
      center.dx + bodyR * sin(angle),
      center.dy - bodyR * cos(angle),
    );

    // 화살표 라인
    final arrowPaint = Paint()
      ..color = arrowColor
      ..strokeWidth = 3.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(bodyStart, tip, arrowPaint);

    // 화살표 머리
    final headSize = radius * 0.1;
    final headAngle1 = angle - pi + pi / 6;
    final headAngle2 = angle - pi - pi / 6;

    final head1 = Offset(
      tip.dx + headSize * sin(headAngle1),
      tip.dy - headSize * cos(headAngle1),
    );
    final head2 = Offset(
      tip.dx + headSize * sin(headAngle2),
      tip.dy - headSize * cos(headAngle2),
    );

    final headPath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(head1.dx, head1.dy)
      ..lineTo(head2.dx, head2.dy)
      ..close();

    canvas.drawPath(headPath, Paint()
      ..color = arrowColor
      ..style = PaintingStyle.fill);

    // 반대쪽 꼬리 (짧은 라인)
    final tailR = radius * 0.15;
    final tailEnd = Offset(
      center.dx - tailR * sin(angle),
      center.dy + tailR * cos(angle),
    );
    canvas.drawLine(center, tailEnd, Paint()
      ..color = arrowColor.withValues(alpha: 0.4)
      ..strokeWidth = 1.5);

    // 목표점 위치에 동심원 표시
    final targetDotR = radius * 0.04;
    canvas.drawCircle(tip, targetDotR, Paint()
      ..color = arrowColor
      ..style = PaintingStyle.fill);
  }

  /// 중앙 정보: 거리 + 목표명
  void _drawCenterInfo(Canvas canvas, Offset center, double radius) {
    // 중앙 원 배경
    final bgPaint = Paint()
      ..color = isWithinTolerance
          ? Colors.green.withValues(alpha: 0.3)
          : Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius * 0.28, bgPaint);

    // 거리 텍스트
    final distStr = distance < 1.0
        ? '${(distance * 100).toStringAsFixed(1)}cm'
        : '${distance.toStringAsFixed(3)}m';

    final distTp = TextPainter(
      text: TextSpan(
        text: distStr,
        style: TextStyle(
          color: isWithinTolerance ? Colors.greenAccent : Colors.white,
          fontSize: radius * 0.14,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    distTp.paint(canvas, Offset(center.dx - distTp.width / 2, center.dy - distTp.height / 2 - radius * 0.04));

    // 포인트명
    final nameTp = TextPainter(
      text: TextSpan(
        text: targetName,
        style: TextStyle(
          color: Colors.grey[300],
          fontSize: radius * 0.09,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    nameTp.paint(canvas, Offset(center.dx - nameTp.width / 2, center.dy + radius * 0.06));
  }

  /// 이동 방향 마커 (화면 상단 삼각형)
  void _drawMovingDirectionMarker(Canvas canvas, Offset center, double radius) {
    // 화면 상단(=이동방향)에 삼각 마커
    final markerSize = radius * 0.08;
    final markerY = center.dy - radius - 2;

    final path = Path()
      ..moveTo(center.dx, markerY + markerSize * 2)
      ..lineTo(center.dx - markerSize, markerY + markerSize * 3.5)
      ..lineTo(center.dx + markerSize, markerY + markerSize * 3.5)
      ..close();

    canvas.drawPath(path, Paint()
      ..color = Colors.cyan
      ..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant StakeoutCompassPainter old) {
    return old.azimuthToTarget != azimuthToTarget ||
        old.movingAzimuth != movingAzimuth ||
        old.distance != distance ||
        old.tolerance != tolerance ||
        old.targetName != targetName;
  }
}
