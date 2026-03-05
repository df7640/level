import 'dart:math';
import 'package:flutter/material.dart';

/// DXF 도면을 렌더링하는 CustomPainter (순수 벡터 렌더링)
class DxfPainter extends CustomPainter {
  final List<dynamic> entities;
  final Map<String, dynamic> bounds;
  final double zoom;
  final Offset offset;
  final Set<String> hiddenLayers;

  /// TextPainter 캐시: 키 = "text|fontSize" → TextPainter (layout 완료 상태)
  static final Map<String, TextPainter> _textCache = {};
  static const int _textCacheMaxSize = 500;

  DxfPainter({
    required this.entities,
    required this.bounds,
    this.zoom = 1.0,
    this.offset = Offset.zero,
    this.hiddenLayers = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (entities.isEmpty) return;

    // 배경
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.grey[900]!,
    );

    _paintEntities(canvas, size);
  }

  void _paintEntities(Canvas canvas, Size size) {
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;

    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;
    if (dxfWidth <= 0 || dxfHeight <= 0) return;

    final scaleX = size.width * 0.9 / dxfWidth;
    final scaleY = size.height * 0.9 / dxfHeight;
    final baseScale = scaleX < scaleY ? scaleX : scaleY;
    final scale = baseScale * zoom;

    final centerOffsetX = (size.width - dxfWidth * scale) / 2;
    final centerOffsetY = (size.height - dxfHeight * scale) / 2;

    // 뷰포트 컬링 범위
    final viewMinX = (-centerOffsetX - offset.dx) / scale + minX;
    final viewMaxX = (size.width - centerOffsetX - offset.dx) / scale + minX;
    final viewMaxY = (size.height - centerOffsetY - offset.dy) / scale + minY;
    final viewMinY = (-centerOffsetY - offset.dy) / scale + minY;
    final margin = (viewMaxX - viewMinX) * 0.05;
    final cullMinX = viewMinX - margin;
    final cullMaxX = viewMaxX + margin;
    final cullMinY = viewMinY - margin;
    final cullMaxY = viewMaxY + margin;

    // 좌표 변환 함수
    Offset tx(double x, double y) {
      return Offset(
        (x - minX) * scale + centerOffsetX + offset.dx,
        size.height - ((y - minY) * scale + centerOffsetY + offset.dy),
      );
    }

    // === 색상+선두께별 배치 수집 ===
    // Key: (colorARGB, strokeWidthCategory) → Path
    final Map<(int, int), Path> strokePaths = {};
    final Map<int, double> swLookup = {}; // swCategory → actual strokeWidth
    final Map<int, Path> fillPaths = {};
    final List<(Map<String, dynamic>, int)> textEntities = [];
    final List<(Map<String, dynamic>, int)> hatchEntities = [];

    for (final entity in entities) {
      final type = entity['type'] as String;
      final layer = entity['layer'] as String?;
      if (layer != null && hiddenLayers.contains(layer)) continue;

      // 뷰포트 컬링
      final aabb = entity['aabb'] as List?;
      if (aabb != null) {
        if (aabb[2] < cullMinX || aabb[0] > cullMaxX ||
            aabb[3] < cullMinY || aabb[1] > cullMaxY) continue;
      }

      // 사전 resolve된 색상 사용 (ARGB int)
      final ck = (entity['resolvedColor'] as int?) ?? 0xFFFFFFFF;

      // 엔티티별 선 두께 resolve
      double entityLw = (entity['lw'] as double?) ?? 0.5;
      // 음수 = DXF 단위 폭 (LWPOLYLINE constantWidth) → scale 곱하기
      if (entityLw < 0) {
        entityLw = (-entityLw * scale).clamp(0.5, 20.0);
      }
      final swCat = (entityLw * 10).round(); // 카테고리화

      switch (type) {
        case 'LINE':
          final key = (ck, swCat);
          final path = strokePaths.putIfAbsent(key, () => Path());
          swLookup.putIfAbsent(swCat, () => entityLw);
          final p1 = tx(entity['x1'] as double, entity['y1'] as double);
          final p2 = tx(entity['x2'] as double, entity['y2'] as double);
          path.moveTo(p1.dx, p1.dy);
          path.lineTo(p2.dx, p2.dy);
          break;

        case 'LWPOLYLINE':
          final key = (ck, swCat);
          final path = strokePaths.putIfAbsent(key, () => Path());
          swLookup.putIfAbsent(swCat, () => entityLw);
          _addPolylineToPath(path, entity, tx);
          break;

        case 'CIRCLE':
          final key = (ck, swCat);
          final path = strokePaths.putIfAbsent(key, () => Path());
          swLookup.putIfAbsent(swCat, () => entityLw);
          final center = tx(entity['cx'] as double, entity['cy'] as double);
          path.addOval(Rect.fromCircle(
            center: center,
            radius: (entity['radius'] as double) * scale,
          ));
          break;

        case 'ARC':
          final key = (ck, swCat);
          final path = strokePaths.putIfAbsent(key, () => Path());
          swLookup.putIfAbsent(swCat, () => entityLw);
          _addArcToPath(path, entity, tx, scale);
          break;

        case 'POINT':
          final path = fillPaths.putIfAbsent(ck, () => Path());
          final pos = tx(entity['x'] as double, entity['y'] as double);
          path.addOval(Rect.fromCircle(center: pos, radius: 2.0));
          break;

        case 'TEXT':
          textEntities.add((entity, ck));
          break;

        case 'HATCH':
          hatchEntities.add((entity, ck));
          break;
      }
    }

    // === 렌더링: HATCH(배경) → 배치 지오메트리 → TEXT(전경) ===

    // HATCH: 경계 Path 빌드 → SOLID이면 fill, 패턴이면 clipPath + 패턴라인
    for (final (entity, ck) in hatchEntities) {
      final boundaries = entity['boundaries'] as List?;
      if (boundaries == null || boundaries.isEmpty) continue;

      final isSolid = entity['solid'] as bool? ?? false;
      final patternLines = entity['patternLines'] as List? ?? [];

      // 모든 경계를 하나의 Path로 합치기
      Path? combinedPath;
      for (final boundary in boundaries) {
        final segs = boundary as List;
        if (segs.isEmpty) continue;
        final path = _buildHatchPath(segs, tx, scale);
        if (path == null) continue;
        final pb = path.getBounds();
        if (pb.width > 10000 || pb.height > 10000) continue;
        if (combinedPath == null) {
          combinedPath = path;
        } else {
          combinedPath.addPath(path, Offset.zero);
        }
      }
      if (combinedPath == null) continue;

      final color = Color(ck);
      const hatchLw = 0.5;

      if (isSolid || patternLines.isEmpty) {
        canvas.drawPath(combinedPath, Paint()
          ..color = color.withValues(alpha: isSolid ? 0.35 : 0.15)
          ..style = PaintingStyle.fill);
        canvas.drawPath(combinedPath, Paint()
          ..color = color.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = hatchLw * 0.5);
      } else {
        canvas.drawPath(combinedPath, Paint()
          ..color = color.withValues(alpha: 0.08)
          ..style = PaintingStyle.fill);
        canvas.drawPath(combinedPath, Paint()
          ..color = color.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = hatchLw * 0.4);
        _drawHatchPattern(canvas, combinedPath, entity, tx, scale, color, hatchLw);
      }
    }

    // 배치 stroke (색상+선두께별)
    final batchPaint = Paint()
      ..style = PaintingStyle.stroke;
    for (final entry in strokePaths.entries) {
      final (colorKey, swCat) = entry.key;
      batchPaint.color = Color(colorKey);
      batchPaint.strokeWidth = swLookup[swCat] ?? 0.5;
      canvas.drawPath(entry.value, batchPaint);
    }

    // 배치 fill
    final fillPaint = Paint()..style = PaintingStyle.fill;
    for (final entry in fillPaths.entries) {
      fillPaint.color = Color(entry.key);
      canvas.drawPath(entry.value, fillPaint);
    }

    // TEXT
    for (final (entity, ck) in textEntities) {
      _drawText(canvas, entity, tx, Color(ck), scale);
    }
  }

  // ===== 배치 Path 빌더 =====

  void _addPolylineToPath(
    Path path,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
  ) {
    final points = entity['points'] as List;
    if (points.length < 2) return;

    final firstPoint = points[0] as Map<String, dynamic>;
    final start = transform(firstPoint['x'], firstPoint['y']);
    path.moveTo(start.dx, start.dy);

    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i] as Map<String, dynamic>;
      final p2 = points[i + 1] as Map<String, dynamic>;
      final bulge = p1['bulge'] as double? ?? 0.0;

      if (bulge.abs() > 1e-10) {
        _drawBulgeSegment(path, p1['x'], p1['y'], p2['x'], p2['y'], bulge, transform);
      } else {
        final end = transform(p2['x'], p2['y']);
        path.lineTo(end.dx, end.dy);
      }
    }

    final closed = entity['closed'] as bool? ?? false;
    if (closed && points.isNotEmpty) {
      final lastPoint = points.last as Map<String, dynamic>;
      final fp = points.first as Map<String, dynamic>;
      final bulge = lastPoint['bulge'] as double? ?? 0.0;

      if (bulge.abs() > 1e-10) {
        _drawBulgeSegment(path, lastPoint['x'], lastPoint['y'], fp['x'], fp['y'], bulge, transform);
      } else {
        path.close();
      }
    }
  }

  void _addArcToPath(
    Path path,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
    double scale,
  ) {
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
    final sx = center.dx + scaledRadius * cos(startRad);
    final sy = center.dy + scaledRadius * sin(startRad);
    path.moveTo(sx, sy);
    path.arcTo(rect, startRad, sweepRad, false);
  }

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

  // ===== 개별 렌더링 (TEXT, HATCH) =====

  void _drawText(
    Canvas canvas,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
    Color color,
    double scale,
  ) {
    final x = entity['x'] as double;
    final y = entity['y'] as double;
    final text = entity['text'] as String;
    final height = entity['height'] as double;

    final position = transform(x, y);
    final scaledHeight = height * scale;
    if (scaledHeight < 4.0) return; // 4px 미만은 스킵 (기존 3.0 → 강화)

    final fontSize = scaledHeight.clamp(8.0, 100.0);
    final cacheKey = '$text|${fontSize.toStringAsFixed(1)}|${color.toARGB32()}';

    var tp = _textCache[cacheKey];
    if (tp == null) {
      tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: color,
            fontSize: fontSize,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();

      // 캐시 크기 제한
      if (_textCache.length >= _textCacheMaxSize) {
        _textCache.clear();
      }
      _textCache[cacheKey] = tp;
    }

    tp.paint(canvas, position);
  }

  Path? _buildHatchPath(
    List segs,
    Offset Function(double, double) transform,
    double scale,
  ) {
    if (segs.isEmpty) return null;
    final path = Path();
    bool first = true;

    for (final seg in segs) {
      final edge = seg['edge'] as String;

      if (edge == 'line') {
        final x1 = (seg['x1'] as double?) ?? 0;
        final y1 = (seg['y1'] as double?) ?? 0;
        final x2 = (seg['x2'] as double?) ?? 0;
        final y2 = (seg['y2'] as double?) ?? 0;
        final p1 = transform(x1, y1);
        final p2 = transform(x2, y2);
        if (first) { path.moveTo(p1.dx, p1.dy); first = false; }
        path.lineTo(p2.dx, p2.dy);
      } else if (edge == 'bulge') {
        final x1 = (seg['x1'] as double?) ?? 0;
        final y1 = (seg['y1'] as double?) ?? 0;
        final x2 = (seg['x2'] as double?) ?? 0;
        final y2 = (seg['y2'] as double?) ?? 0;
        final bulge = (seg['bulge'] as double?) ?? 0;
        final p1 = transform(x1, y1);
        if (first) { path.moveTo(p1.dx, p1.dy); first = false; }
        _drawBulgeSegment(path, x1, y1, x2, y2, bulge, transform);
      } else if (edge == 'arc') {
        final cx = (seg['cx'] as double?) ?? 0;
        final cy = (seg['cy'] as double?) ?? 0;
        final radius = (seg['radius'] as double?) ?? 0;
        final sa = (seg['startAngle'] as double?) ?? 0;
        final ea = (seg['endAngle'] as double?) ?? 0;
        final ccw = (seg['ccw'] as bool?) ?? true;

        final scaledR = radius * scale;
        final center = transform(cx, cy);

        final saRad = -sa * pi / 180.0;
        final startPt = Offset(center.dx + scaledR * cos(saRad), center.dy + scaledR * sin(saRad));
        if (first) { path.moveTo(startPt.dx, startPt.dy); first = false; }
        else { path.lineTo(startPt.dx, startPt.dy); }

        double includedDeg = ccw ? (ea - sa) : (sa - ea);
        if (includedDeg <= 0) includedDeg += 360.0;
        final sweepRad = ccw ? -(includedDeg * pi / 180.0) : (includedDeg * pi / 180.0);

        final rect = Rect.fromCircle(center: center, radius: scaledR);
        path.arcTo(rect, saRad, sweepRad, false);
      }
    }

    path.close();
    return path;
  }

  /// 해치 패턴 라인 렌더링: 경계 clipPath 내에 패턴 정의에 따른 평행선 그리기
  void _drawHatchPattern(
    Canvas canvas,
    Path clipPath,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
    double drawScale,
    Color color,
    double lineWidth,
  ) {
    final patternLines = entity['patternLines'] as List? ?? [];
    if (patternLines.isEmpty) return;

    final patternScale = (entity['patternScale'] as double?) ?? 1.0;
    final patternAngle = (entity['patternAngle'] as double?) ?? 0.0;

    // 경계의 DXF 좌표 바운딩 박스 계산
    final boundaries = entity['boundaries'] as List;
    double bMinX = double.infinity, bMinY = double.infinity;
    double bMaxX = double.negativeInfinity, bMaxY = double.negativeInfinity;
    for (final boundary in boundaries) {
      for (final seg in boundary as List) {
        final edge = seg['edge'] as String;
        if (edge == 'line' || edge == 'bulge') {
          final x1 = (seg['x1'] as double?) ?? 0;
          final y1 = (seg['y1'] as double?) ?? 0;
          final x2 = (seg['x2'] as double?) ?? 0;
          final y2 = (seg['y2'] as double?) ?? 0;
          if (x1 < bMinX) bMinX = x1; if (x1 > bMaxX) bMaxX = x1;
          if (y1 < bMinY) bMinY = y1; if (y1 > bMaxY) bMaxY = y1;
          if (x2 < bMinX) bMinX = x2; if (x2 > bMaxX) bMaxX = x2;
          if (y2 < bMinY) bMinY = y2; if (y2 > bMaxY) bMaxY = y2;
        } else if (edge == 'arc') {
          final cx = (seg['cx'] as double?) ?? 0;
          final cy = (seg['cy'] as double?) ?? 0;
          final r = (seg['radius'] as double?) ?? 0;
          if (cx - r < bMinX) bMinX = cx - r; if (cx + r > bMaxX) bMaxX = cx + r;
          if (cy - r < bMinY) bMinY = cy - r; if (cy + r > bMaxY) bMaxY = cy + r;
        }
      }
    }
    if (bMinX >= bMaxX || bMinY >= bMaxY) return;

    final bboxDiag = sqrt((bMaxX - bMinX) * (bMaxX - bMinX) + (bMaxY - bMinY) * (bMaxY - bMinY));

    canvas.save();
    canvas.clipPath(clipPath);

    final linePath = Path();
    final patternPaint = Paint()
      ..color = color.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth * 0.6;

    int totalSegments = 0;
    const maxTotalSegments = 50000; // 전체 세그먼트 수 제한

    for (final pl in patternLines) {
      if (totalSegments >= maxTotalSegments) break;

      final baseAngle = ((pl['angle'] as double?) ?? 0) + patternAngle;
      final angleRad = baseAngle * pi / 180.0;
      final ox = ((pl['ox'] as double?) ?? 0) * patternScale;
      final oy = ((pl['oy'] as double?) ?? 0) * patternScale;
      final dx = ((pl['dx'] as double?) ?? 0) * patternScale;
      final dy = ((pl['dy'] as double?) ?? 0) * patternScale;
      final dashes = (pl['dashes'] as List?)?.cast<double>() ?? <double>[];

      if (dy.abs() < 1e-10) continue;
      final spacing = dy.abs();

      // 화면에서 라인 간격이 1.5px 미만이면 너무 촘촘 → 반투명 fill로 대체
      final screenSpacing = spacing * drawScale;
      if (screenSpacing < 1.5) continue;

      // 라인 방향
      final dirX = cos(angleRad);
      final dirY = sin(angleRad);
      // 수직 방향 (다음 라인으로의 오프셋)
      final perpX = -sin(angleRad);
      final perpY = cos(angleRad);

      // bbox 코너를 수직 축에 투영 → 라인 인덱스 범위
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

      // 과도한 라인 수 방지
      if (nMax - nMin > 500) continue;

      // 대시 패턴 총 길이 (루프 전에 1회만 계산)
      final totalDashLen = dashes.isEmpty
          ? 0.0
          : dashes.fold(0.0, (double s, double d) => s + d.abs()) * patternScale;

      for (int n = nMin; n <= nMax; n++) {
        if (totalSegments >= maxTotalSegments) break;

        // 라인 n의 원점 (DXF 좌표)
        final lineOX = ox + n * perpX * spacing;
        final lineOY = oy + n * perpY * spacing;

        if (dashes.isEmpty) {
          // 연속선: bbox 대각선 길이만큼 양방향 확장
          final x1 = lineOX - dirX * bboxDiag;
          final y1 = lineOY - dirY * bboxDiag;
          final x2 = lineOX + dirX * bboxDiag;
          final y2 = lineOY + dirY * bboxDiag;
          final p1 = transform(x1, y1);
          final p2 = transform(x2, y2);
          linePath.moveTo(p1.dx, p1.dy);
          linePath.lineTo(p2.dx, p2.dy);
          totalSegments++;
        } else {
          if (totalDashLen < 1e-10) continue;

          // 스태거(dx) 위상 보정
          final dashPhase = (dx.abs() > 1e-10)
              ? (n * dx * patternScale) % totalDashLen
              : 0.0;
          double t = -bboxDiag - dashPhase;
          final tEnd = bboxDiag;
          int dashIter = 0;
          const maxDashIter = 10000; // 라인당 대시 반복 제한

          while (t < tEnd && dashIter < maxDashIter) {
            for (final dash in dashes) {
              if (t >= tEnd || dashIter >= maxDashIter) break;
              dashIter++;

              final len = dash.abs() * patternScale;
              if (len < 1e-10) {
                // 점 (dash == 0): 최소 진행량 확보 (무한루프 방지)
                final px = lineOX + dirX * t;
                final py = lineOY + dirY * t;
                final p = transform(px, py);
                linePath.addOval(Rect.fromCircle(center: p, radius: 0.5));
                totalSegments++;
                t += spacing * 0.01; // 점이라도 약간 전진
                continue;
              }
              if (dash > 0) {
                // 그리기 구간
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

    canvas.drawPath(linePath, patternPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DxfPainter oldDelegate) {
    return oldDelegate.entities != entities ||
        oldDelegate.bounds != bounds ||
        oldDelegate.zoom != zoom ||
        oldDelegate.offset != offset ||
        oldDelegate.hiddenLayers != hiddenLayers;
  }
}
