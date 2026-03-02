import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// DXF 도면을 렌더링하는 CustomPainter
/// Picture 캐싱: 줌/레이어 변경 시 ui.Picture로 녹화, 패닝 시 translate+drawPicture로 재생
class DxfPainter extends CustomPainter {
  final List<dynamic> entities;
  final Map<String, dynamic> bounds;
  final double zoom;
  final Offset offset;
  final Set<String> hiddenLayers;

  /// 캐시된 Picture (offset=0으로 녹화됨, 패닝/줌 시 transform+drawPicture로 재생)
  final ui.Picture? cachedPicture;
  /// 캐시 녹화 시의 줌 레벨 (줌 변경 시 스케일 보정용)
  final double cacheZoom;

  DxfPainter({
    required this.entities,
    required this.bounds,
    this.zoom = 1.0,
    this.offset = Offset.zero,
    this.hiddenLayers = const {},
    this.cachedPicture,
    this.cacheZoom = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (entities.isEmpty) return;

    // 배경
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.grey[900]!,
    );

    if (cachedPicture != null) {
      // 고속 경로: 캐시된 Picture를 transform하여 재생
      // Picture는 offset=0, zoom=cacheZoom으로 녹화됨
      canvas.save();
      final r = zoom / cacheZoom; // 스케일 비율
      // 캔버스 중앙 기준 스케일 + 오프셋 적용
      // 수학: desired(x) = r*(cached(x) - W/2) + W/2 + offset.dx
      //       desired(y) = r*(cached(y) - H/2) + H/2 - offset.dy
      canvas.translate(size.width / 2 + offset.dx, size.height / 2 - offset.dy);
      canvas.scale(r, r);
      canvas.translate(-size.width / 2, -size.height / 2);
      canvas.drawPicture(cachedPicture!);
      canvas.restore();
    } else {
      // 폴백: 직접 렌더링 (캐시 없을 때)
      paintEntities(canvas, size);
    }
  }

  /// 엔티티 배치 렌더링 (뷰포트 컬링 + 색상별 Path 배치)
  /// [enableCulling]: false면 뷰포트 컬링 스킵 (Picture 캐시 빌드 시)
  void paintEntities(Canvas canvas, Size size, {bool enableCulling = true}) {
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
    double cullMinX = -1e18, cullMaxX = 1e18, cullMinY = -1e18, cullMaxY = 1e18;
    if (enableCulling) {
      final viewMinX = (-centerOffsetX - offset.dx) / scale + minX;
      final viewMaxX = (size.width - centerOffsetX - offset.dx) / scale + minX;
      final viewMaxY = (size.height - centerOffsetY - offset.dy) / scale + minY;
      final viewMinY = (-centerOffsetY - offset.dy) / scale + minY;
      final margin = (viewMaxX - viewMinX) * 0.05;
      cullMinX = viewMinX - margin;
      cullMaxX = viewMaxX + margin;
      cullMinY = viewMinY - margin;
      cullMaxY = viewMaxY + margin;
    }

    // 좌표 변환 함수
    Offset tx(double x, double y) {
      return Offset(
        (x - minX) * scale + centerOffsetX + offset.dx,
        size.height - ((y - minY) * scale + centerOffsetY + offset.dy),
      );
    }

    // sqrt(zoom) 비례 선 두께: 캐시 스케일링↔재빌드 간 팝 최소화 + 고줌에서 과도한 굵기 방지
    // 팝 비율 = sqrt(줌변화비), 예) 2배 줌 시 1.41배 차이 (거의 안 보임)
    final baseStroke = baseScale < 0.01 ? 1.2 : (baseScale < 0.1 ? 0.9 : 0.6);
    final strokeWidth = baseStroke * sqrt(zoom);

    // === 색상별 배치 수집 ===
    final Map<int, Path> strokePaths = {};
    final Map<int, Path> fillPaths = {};
    final Map<int, Color> colorLookup = {};
    final List<(Map<String, dynamic>, Color)> textEntities = [];
    final List<(Map<String, dynamic>, Color)> hatchEntities = [];

    for (final entity in entities) {
      final type = entity['type'] as String;
      final layer = entity['layer'] as String?;
      if (layer != null && hiddenLayers.contains(layer)) continue;

      // 뷰포트 컬링
      if (enableCulling) {
        final aabb = entity['aabb'] as List?;
        if (aabb != null) {
          if (aabb[2] < cullMinX || aabb[0] > cullMaxX ||
              aabb[3] < cullMinY || aabb[1] > cullMaxY) continue;
        }
      }

      final colorCode = entity['color'] as int?;
      final color = _getEntityColor(colorCode, layer);
      final ck = color.toARGB32();

      switch (type) {
        case 'LINE':
          colorLookup.putIfAbsent(ck, () => color);
          final path = strokePaths.putIfAbsent(ck, () => Path());
          final p1 = tx(entity['x1'] as double, entity['y1'] as double);
          final p2 = tx(entity['x2'] as double, entity['y2'] as double);
          path.moveTo(p1.dx, p1.dy);
          path.lineTo(p2.dx, p2.dy);
          break;

        case 'LWPOLYLINE':
          colorLookup.putIfAbsent(ck, () => color);
          final path = strokePaths.putIfAbsent(ck, () => Path());
          _addPolylineToPath(path, entity, tx);
          break;

        case 'CIRCLE':
          colorLookup.putIfAbsent(ck, () => color);
          final path = strokePaths.putIfAbsent(ck, () => Path());
          final center = tx(entity['cx'] as double, entity['cy'] as double);
          path.addOval(Rect.fromCircle(
            center: center,
            radius: (entity['radius'] as double) * scale,
          ));
          break;

        case 'ARC':
          colorLookup.putIfAbsent(ck, () => color);
          final path = strokePaths.putIfAbsent(ck, () => Path());
          _addArcToPath(path, entity, tx, scale);
          break;

        case 'POINT':
          colorLookup.putIfAbsent(ck, () => color);
          final path = fillPaths.putIfAbsent(ck, () => Path());
          final pos = tx(entity['x'] as double, entity['y'] as double);
          path.addOval(Rect.fromCircle(center: pos, radius: 2.0));
          break;

        case 'TEXT':
          textEntities.add((entity, color));
          break;

        case 'HATCH':
          hatchEntities.add((entity, color));
          break;
      }
    }

    // === 렌더링: HATCH(배경) → 배치 지오메트리 → TEXT(전경) ===

    final hatchPaint = Paint()..strokeWidth = strokeWidth..style = PaintingStyle.stroke;
    for (final (entity, color) in hatchEntities) {
      hatchPaint.color = color;
      _drawHatch(canvas, entity, tx, hatchPaint, scale);
    }

    final batchPaint = Paint()
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    for (final entry in strokePaths.entries) {
      batchPaint.color = colorLookup[entry.key]!;
      canvas.drawPath(entry.value, batchPaint);
    }

    final fillPaint = Paint()..style = PaintingStyle.fill;
    for (final entry in fillPaths.entries) {
      fillPaint.color = colorLookup[entry.key]!;
      canvas.drawPath(entry.value, fillPaint);
    }

    for (final (entity, color) in textEntities) {
      _drawText(canvas, entity, tx, color, scale);
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

  // ===== 색상 매핑 =====

  Color _getEntityColor(int? colorCode, String? layer) {
    if (colorCode == null || colorCode == 0) {
      return _getLayerColor(layer ?? '0');
    }

    final absColorCode = colorCode.abs();

    switch (absColorCode) {
      case 1: return const Color(0xFFFF0000);
      case 2: return const Color(0xFFFFFF00);
      case 3: return const Color(0xFF00FF00);
      case 4: return const Color(0xFF00FFFF);
      case 5: return const Color(0xFF0000FF);
      case 6: return const Color(0xFFFF00FF);
      case 7: return const Color(0xFFFFFFFF);
      case 8: return const Color(0xFF414141);
      case 9: return const Color(0xFF808080);
      case 10: return const Color(0xFFFF0000);
      case 11: return const Color(0xFFFFAAAA);
      case 12: return const Color(0xFFBD0000);
      case 13: return const Color(0xFFBD7E7E);
      case 14: return const Color(0xFF810000);
      case 20: return const Color(0xFFFF7F00);
      case 30: return const Color(0xFFFF7F7F);
      case 40: return const Color(0xFFFF3F3F);
      case 50: return const Color(0xFF7F3F00);
      case 60: return const Color(0xFFFF7F3F);
      case 70: return const Color(0xFFBD7E00);
      case 80: return const Color(0xFF7F7F00);
      case 90: return const Color(0xFFBDBD00);
      case 91: return const Color(0xFF7FFF7F);
      case 92: return const Color(0xFF00BD00);
      case 93: return const Color(0xFF007F00);
      case 94: return const Color(0xFF3FFF3F);
      case 95: return const Color(0xFF00FF7F);
      case 100: return const Color(0xFF00BDBD);
      case 110: return const Color(0xFF7FFFFF);
      case 120: return const Color(0xFF007FBD);
      case 130: return const Color(0xFF0000BD);
      case 140: return const Color(0xFF3F3FFF);
      case 150: return const Color(0xFF00007F);
      case 160: return const Color(0xFF7F7FFF);
      case 170: return const Color(0xFF3F00BD);
      case 180: return const Color(0xFF7F00FF);
      case 190: return const Color(0xFFBD007F);
      case 200: return const Color(0xFFFF00FF);
      case 210: return const Color(0xFFFF7FFF);
      case 220: return const Color(0xFFFF3FBD);
      case 230: return const Color(0xFFBDBDBD);
      case 240: return const Color(0xFF7F7F7F);
      case 250: return const Color(0xFF3F3F3F);
      case 251: return const Color(0xFFC0C0C0);
      case 252: return const Color(0xFF989898);
      case 253: return const Color(0xFF707070);
      case 254: return const Color(0xFF484848);
      case 255: return const Color(0xFF000000);
      default: return const Color(0xFFFFFFFF);
    }
  }

  Color _getLayerColor(String layer) {
    final layerUpper = layer.toUpperCase();
    if (layerUpper.contains('측점') || layerUpper.contains('NO') || layerUpper.contains('STA')) {
      return Colors.cyan;
    } else if (layerUpper.contains('계획') || layerUpper.contains('PLAN') || layerUpper.contains('DESIGN')) {
      return Colors.red;
    } else if (layerUpper.contains('현황') || layerUpper.contains('EXIST')) {
      return Colors.green;
    } else if (layerUpper.contains('제방') || layerUpper.contains('BANK') || layerUpper.contains('LEVEE')) {
      return Colors.yellow;
    } else if (layerUpper.contains('홍수위') || layerUpper.contains('FLOOD') || layerUpper.contains('WATER')) {
      return Colors.blue;
    } else if (layerUpper.contains('문자') || layerUpper.contains('TEXT') || layerUpper.contains('DIM')) {
      return Colors.white70;
    } else if (layerUpper.contains('포장') || layerUpper.contains('PAVEMENT') || layerUpper.contains('PAVE')) {
      return Colors.grey[400]!;
    } else if (layerUpper.contains('중심') || layerUpper.contains('CENTER') || layerUpper.contains('CL')) {
      return Colors.orange;
    } else if (layerUpper.contains('경계') || layerUpper.contains('BOUNDARY') || layerUpper.contains('BORDER')) {
      return Colors.purple;
    } else {
      return Colors.white;
    }
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
    if (scaledHeight < 3.0) return;

    final textSpan = TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: scaledHeight.clamp(8.0, 100.0),
        fontFamily: 'monospace',
      ),
    );

    final textPainter = TextPainter(
      text: textSpan,
      textDirection: TextDirection.ltr,
    );

    textPainter.layout();
    textPainter.paint(canvas, position);
  }

  void _drawHatch(
    Canvas canvas,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
    Paint paint,
    double scale,
  ) {
    final boundaries = entity['boundaries'] as List?;
    if (boundaries == null || boundaries.isEmpty) return;

    final isSolid = entity['solid'] as bool? ?? false;
    final patternLines = entity['patternLines'] as List? ?? [];
    final patternScale = (entity['patternScale'] as double?) ?? 1.0;

    final hatchStroke = 0.3 * sqrt(zoom);
    final strokePaint = Paint()
      ..color = paint.color.withValues(alpha: 0.5)
      ..strokeWidth = hatchStroke
      ..style = PaintingStyle.stroke;

    Path? combinedPath;
    for (final boundary in boundaries) {
      final segs = boundary as List;
      if (segs.isEmpty) continue;

      final path = _buildHatchPath(segs, transform, scale);
      if (path == null) continue;

      final pathBounds = path.getBounds();
      if (pathBounds.width > 10000 || pathBounds.height > 10000) continue;

      if (combinedPath == null) {
        combinedPath = path;
      } else {
        combinedPath.addPath(path, Offset.zero);
      }
    }

    if (combinedPath == null) return;

    if (isSolid || patternLines.isEmpty) {
      final fillPaint = Paint()
        ..color = paint.color.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;
      canvas.drawPath(combinedPath, fillPaint);
      canvas.drawPath(combinedPath, strokePaint);
    } else {
      final bgPaint = Paint()
        ..color = paint.color.withValues(alpha: 0.1)
        ..style = PaintingStyle.fill;
      canvas.drawPath(combinedPath, bgPaint);

      canvas.save();
      canvas.clipPath(combinedPath);

      final patternPaint = Paint()
        ..color = paint.color.withValues(alpha: 0.7)
        ..strokeWidth = hatchStroke
        ..style = PaintingStyle.stroke;

      final clipBounds = combinedPath.getBounds();

      for (final pl in patternLines) {
        final angle = (pl['angle'] as double?) ?? 0;
        final ox = (pl['ox'] as double?) ?? 0;
        final oy = (pl['oy'] as double?) ?? 0;
        final dx = (pl['dx'] as double?) ?? 0;
        final dy = (pl['dy'] as double?) ?? 0;
        final dashes = (pl['dashes'] as List?)?.cast<double>() ?? [];

        _drawHatchPatternLine(
          canvas, transform, scale, patternPaint,
          clipBounds, angle, ox, oy, dx, dy, dashes, patternScale,
        );
      }

      canvas.restore();
      canvas.drawPath(combinedPath, strokePaint);
    }
  }

  void _drawHatchPatternLine(
    Canvas canvas,
    Offset Function(double, double) transform,
    double scale,
    Paint paint,
    Rect clipBounds,
    double angle,
    double ox, double oy,
    double dx, double dy,
    List<double> dashes,
    double patternScale,
  ) {
    final spacing = dy.abs() * patternScale;
    if (spacing < 1e-6) return;

    final screenSpacing = spacing * scale;
    if (screenSpacing < 2.0) return;

    final clipW = clipBounds.width;
    final clipH = clipBounds.height;
    final diagScreen = sqrt(clipW * clipW + clipH * clipH);

    var actualSpacing = screenSpacing;
    var lineCount = (diagScreen / actualSpacing).ceil() + 2;
    if (lineCount > 150) {
      actualSpacing = diagScreen / 150.0;
      lineCount = 150;
    }

    final angleRad = angle * pi / 180.0;
    final screenAngleRad = -angleRad;
    final sDirX = cos(screenAngleRad);
    final sDirY = sin(screenAngleRad);
    final sPerpX = -sDirY;
    final sPerpY = sDirX;

    final centerX = clipBounds.center.dx;
    final centerY = clipBounds.center.dy;
    final halfLineLen = diagScreen;

    final screenDashes = dashes.map((d) => d * patternScale * scale).toList();
    final hasDash = screenDashes.isNotEmpty
        && screenDashes.any((d) => d.abs() > 0.5)
        && lineCount <= 100;

    for (int n = -lineCount; n <= lineCount; n++) {
      final cx = centerX + sPerpX * actualSpacing * n;
      final cy = centerY + sPerpY * actualSpacing * n;

      final p1 = Offset(cx - sDirX * halfLineLen, cy - sDirY * halfLineLen);
      final p2 = Offset(cx + sDirX * halfLineLen, cy + sDirY * halfLineLen);

      if (hasDash) {
        _drawDashedLine(canvas, p1, p2, screenDashes, paint);
      } else {
        canvas.drawLine(p1, p2, paint);
      }
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, List<double> dashes, Paint paint) {
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final totalLen = sqrt(dx * dx + dy * dy);
    if (totalLen < 1.0) return;

    final ux = dx / totalLen;
    final uy = dy / totalLen;

    double t = 0;
    int dashIdx = 0;
    while (t < totalLen) {
      final dashLen = dashes[dashIdx % dashes.length].abs();
      final isDraw = dashes[dashIdx % dashes.length] >= 0;
      final segEnd = (t + dashLen).clamp(0.0, totalLen);

      if (dashLen < 0.01) {
        final px = p1.dx + ux * t;
        final py = p1.dy + uy * t;
        canvas.drawCircle(Offset(px, py), 0.5, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
      } else if (isDraw) {
        final sx = p1.dx + ux * t;
        final sy = p1.dy + uy * t;
        final ex = p1.dx + ux * segEnd;
        final ey = p1.dy + uy * segEnd;
        canvas.drawLine(Offset(sx, sy), Offset(ex, ey), paint);
      }

      t = segEnd;
      dashIdx++;
    }
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

  @override
  bool shouldRepaint(covariant DxfPainter oldDelegate) {
    return oldDelegate.entities != entities ||
        oldDelegate.bounds != bounds ||
        oldDelegate.zoom != zoom ||
        oldDelegate.offset != offset ||
        oldDelegate.hiddenLayers != hiddenLayers ||
        oldDelegate.cachedPicture != cachedPicture ||
        oldDelegate.cacheZoom != cacheZoom;
  }
}
