import 'dart:math';
import 'package:flutter/material.dart';

/// 해치 패턴 렌더러 — DXF 해치 패턴을 지정된 영역에 그리는 독립 모듈
///
/// DXF HATCH 패턴 데이터 구조 (코드 참조):
///   53: 라인 각도 (도) — patternAngle이 이미 적용됨
///   43, 44: base point (ox, oy) — scale + patternAngle 회전 적용됨
///   45, 46: offset vector — scale 적용 + (lineAngle + patternAngle) 회전 적용됨
///           → 절대 좌표계의 벡터. 라인 방향 성분 = stagger, 수직 성분 = spacing
///   49: dash lengths — scale 적용됨
///   41: pattern scale (참조용, 이미 위 값에 적용됨)
///   52: pattern angle (참조용, 이미 53과 43-46에 적용됨)
class HatchPatternRenderer {
  const HatchPatternRenderer._();

  /// 해치 패턴을 clipPath 영역 안에 렌더링
  static void render({
    required Canvas canvas,
    required Path clipPath,
    required List<dynamic> patternLines,
    required double patternAngle,
    required Map<String, double> boundaryBBox,
    required Offset Function(double x, double y) transform,
    required double drawScale,
    required Color color,
    double lineWidth = 0.5,
    double alpha = 0.8,
  }) {
    if (patternLines.isEmpty) return;

    final bMinX = boundaryBBox['minX']!;
    final bMinY = boundaryBBox['minY']!;
    final bMaxX = boundaryBBox['maxX']!;
    final bMaxY = boundaryBBox['maxY']!;
    if (bMinX >= bMaxX || bMinY >= bMaxY) return;

    final bboxW = bMaxX - bMinX;
    final bboxH = bMaxY - bMinY;
    final bboxDiag = sqrt(bboxW * bboxW + bboxH * bboxH);
    final bboxCX = (bMinX + bMaxX) / 2;
    final bboxCY = (bMinY + bMaxY) / 2;

    canvas.save();
    canvas.clipPath(clipPath);

    final linePath = Path();
    final paint = Paint()
      ..color = color.withValues(alpha: alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth;

    int totalSegments = 0;
    const maxTotalSegments = 50000;

    for (final pl in patternLines) {
      if (totalSegments >= maxTotalSegments) break;

      // DXF 코드 53: 라인 각도 — patternAngle(코드 52)이 이미 적용되어 있음
      final angle = (pl['angle'] as double?) ?? 0;
      final angleRad = angle * pi / 180.0;

      // DXF 코드 43, 44: base point (이미 scale+rotation 적용됨)
      final ox = (pl['ox'] as double?) ?? 0.0;
      final oy = (pl['oy'] as double?) ?? 0.0;

      // DXF 코드 45, 46: offset vector (절대 좌표계)
      final offsetX = (pl['dx'] as double?) ?? 0.0;
      final offsetY = (pl['dy'] as double?) ?? 0.0;

      // DXF 코드 49: dash lengths (이미 scale 적용됨)
      final dashes = (pl['dashes'] as List?)?.cast<double>() ?? <double>[];

      // 라인 방향 벡터
      final dirX = cos(angleRad);
      final dirY = sin(angleRad);
      // 라인 수직 벡터 (반시계 90°)
      final perpX = -dirY;
      final perpY = dirX;

      // offset 벡터를 라인 좌표계로 분해
      final stagger = offsetX * dirX + offsetY * dirY;
      final spacing = offsetX * perpX + offsetY * perpY;

      if (spacing.abs() < 1e-10) continue;
      final absSpacing = spacing.abs();

      // === 핵심: ox,oy 기준 격자에 정렬 ===
      // bbox 코너들을 ox,oy 기준 수직 방향으로 투영하여 n 범위 결정
      final corners = [
        (bMinX - ox) * perpX + (bMinY - oy) * perpY,
        (bMaxX - ox) * perpX + (bMinY - oy) * perpY,
        (bMinX - ox) * perpX + (bMaxY - oy) * perpY,
        (bMaxX - ox) * perpX + (bMaxY - oy) * perpY,
      ];
      final minPerp = corners.reduce((a, b) => a < b ? a : b);
      final maxPerp = corners.reduce((a, b) => a > b ? a : b);

      final nMin = (minPerp / spacing).floor() - 1;
      final nMax = (maxPerp / spacing).ceil() + 1;

      if (nMax - nMin > 3000) continue;

      // 대시 패턴 총 길이
      final totalDashLen = dashes.isEmpty
          ? 0.0
          : dashes.fold(0.0, (double s, double d) => s + d.abs());

      // bbox 중심의 라인 방향 투영 (대시 위상 기준점)
      final bboxDirDist = (bboxCX - ox) * dirX + (bboxCY - oy) * dirY;

      for (int n = nMin; n <= nMax; n++) {
        if (totalSegments >= maxTotalSegments) break;

        // 라인 n의 원점: ox,oy에서 n * spacing만큼 수직 방향 이동
        final lineOX = ox + n * perpX * spacing;
        final lineOY = oy + n * perpY * spacing;

        if (dashes.isEmpty) {
          // 연속선
          final x1 = lineOX + dirX * (bboxDirDist - bboxDiag);
          final y1 = lineOY + dirY * (bboxDirDist - bboxDiag);
          final x2 = lineOX + dirX * (bboxDirDist + bboxDiag);
          final y2 = lineOY + dirY * (bboxDirDist + bboxDiag);
          final p1 = transform(x1, y1);
          final p2 = transform(x2, y2);
          linePath.moveTo(p1.dx, p1.dy);
          linePath.lineTo(p2.dx, p2.dy);
          totalSegments++;
        } else {
          if (totalDashLen < 1e-10) continue;

          // 대시 위상: stagger * n (각 라인마다 대시 패턴이 이동)
          final staggerShift = stagger.abs() > 1e-10 ? n * stagger : 0.0;
          // 시작점을 bbox 왼쪽 끝으로 맞추되, stagger + 패턴 원점 기준 정렬
          final startT = bboxDirDist - bboxDiag;
          // startT를 totalDashLen 주기로 정렬 (stagger 고려)
          final rawPhase = (startT - staggerShift) % totalDashLen;
          final alignedStart = startT - rawPhase;

          double t = alignedStart;
          final tEnd = bboxDirDist + bboxDiag;
          int dashIter = 0;
          const maxDashIter = 10000;

          while (t < tEnd && dashIter < maxDashIter) {
            for (final dash in dashes) {
              if (t >= tEnd || dashIter >= maxDashIter) break;
              dashIter++;

              final len = dash.abs();
              if (len < 1e-10) {
                // 점
                final px = lineOX + dirX * t;
                final py = lineOY + dirY * t;
                final p = transform(px, py);
                linePath.addOval(Rect.fromCircle(center: p, radius: 0.5));
                totalSegments++;
                t += absSpacing * 0.01;
                continue;
              }
              if (dash > 0) {
                // 선 그리기
                final sx = lineOX + dirX * t;
                final sy = lineOY + dirY * t;
                final ex = lineOX + dirX * (t + len);
                final ey = lineOY + dirY * (t + len);
                final p1 = transform(sx, sy);
                final p2 = transform(ex, ey);
                linePath.moveTo(p1.dx, p1.dy);
                linePath.lineTo(p2.dx, p2.dy);
                totalSegments++;
              }
              t += len;
            }
          }
        }
      }
    }

    canvas.drawPath(linePath, paint);
    canvas.restore();
  }

  /// 경계 세그먼트 리스트로부터 DXF 좌표 바운딩 박스 계산
  static Map<String, double> computeBoundaryBBox(List<dynamic> boundaries) {
    double minX = double.infinity, minY = double.infinity;
    double maxX = double.negativeInfinity, maxY = double.negativeInfinity;

    for (final boundary in boundaries) {
      for (final seg in boundary as List) {
        final edge = seg['edge'] as String;
        if (edge == 'line' || edge == 'bulge') {
          for (final k in ['x1', 'x2']) {
            final v = (seg[k] as double?) ?? 0;
            if (v < minX) minX = v;
            if (v > maxX) maxX = v;
          }
          for (final k in ['y1', 'y2']) {
            final v = (seg[k] as double?) ?? 0;
            if (v < minY) minY = v;
            if (v > maxY) maxY = v;
          }
        } else if (edge == 'arc') {
          final cx = (seg['cx'] as double?) ?? 0;
          final cy = (seg['cy'] as double?) ?? 0;
          final r = (seg['radius'] as double?) ?? 0;
          if (cx - r < minX) minX = cx - r;
          if (cx + r > maxX) maxX = cx + r;
          if (cy - r < minY) minY = cy - r;
          if (cy + r > maxY) maxY = cy + r;
        }
      }
    }

    return {'minX': minX, 'minY': minY, 'maxX': maxX, 'maxY': maxY};
  }
}
