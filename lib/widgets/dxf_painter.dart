import 'dart:math';
import 'package:flutter/material.dart';

/// DXF 도면을 렌더링하는 CustomPainter
class DxfPainter extends CustomPainter {
  final List<dynamic> entities;
  final Map<String, dynamic> bounds;
  final double zoom;
  final Offset offset;
  final Set<String> hiddenLayers;

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

    // DXF 좌표계를 화면 좌표계로 변환
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;

    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;

    if (dxfWidth <= 0 || dxfHeight <= 0) return;

    // 화면에 맞게 스케일 계산 (여백 10% 추가)
    final scaleX = size.width * 0.9 / dxfWidth;
    final scaleY = size.height * 0.9 / dxfHeight;
    final baseScale = scaleX < scaleY ? scaleX : scaleY;
    final scale = baseScale * zoom;

    // 중앙 정렬을 위한 오프셋
    final centerOffsetX = (size.width - dxfWidth * scale) / 2;
    final centerOffsetY = (size.height - dxfHeight * scale) / 2;

    // 좌표 변환 함수
    Offset transformPoint(double x, double y) {
      final screenX = (x - minX) * scale + centerOffsetX + offset.dx;
      // Y축 반전 (DXF는 위가 +, Flutter는 아래가 +)
      final screenY =
          size.height - ((y - minY) * scale + centerOffsetY + offset.dy);
      return Offset(screenX, screenY);
    }

    // 엔티티 그리기
    final strokeWidth = baseScale < 0.01 ? 3.0 : (baseScale < 0.1 ? 2.0 : 1.0);

    for (final entity in entities) {
      final type = entity['type'] as String;
      final colorCode = entity['color'] as int?;
      final layer = entity['layer'] as String?;

      if (layer != null && hiddenLayers.contains(layer)) continue;

      final color = _getEntityColor(colorCode, layer);

      final paint = Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke;

      switch (type) {
        case 'LINE':
          _drawLine(canvas, entity, transformPoint, paint);
          break;
        case 'LWPOLYLINE':
          _drawPolyline(canvas, entity, transformPoint, paint);
          break;
        case 'CIRCLE':
          _drawCircle(canvas, entity, transformPoint, paint, scale);
          break;
        case 'ARC':
          _drawArc(canvas, entity, transformPoint, paint, scale);
          break;
        case 'TEXT':
          _drawText(canvas, entity, transformPoint, color, scale);
          break;
        case 'POINT':
          _drawPoint(canvas, entity, transformPoint, paint);
          break;
        case 'HATCH':
          _drawHatch(canvas, entity, transformPoint, paint, scale);
          break;
      }
    }
  }

  /// DXF 색상 코드를 Flutter Color로 변환
  Color _getEntityColor(int? colorCode, String? layer) {
    if (colorCode == null || colorCode == 0) {
      return _getLayerColor(layer ?? '0');
    }

    final absColorCode = colorCode.abs();

    switch (absColorCode) {
      case 1:
        return const Color(0xFFFF0000);
      case 2:
        return const Color(0xFFFFFF00);
      case 3:
        return const Color(0xFF00FF00);
      case 4:
        return const Color(0xFF00FFFF);
      case 5:
        return const Color(0xFF0000FF);
      case 6:
        return const Color(0xFFFF00FF);
      case 7:
        return const Color(0xFFFFFFFF);
      case 8:
        return const Color(0xFF414141);
      case 9:
        return const Color(0xFF808080);
      case 10:
        return const Color(0xFFFF0000);
      case 11:
        return const Color(0xFFFFAAAA);
      case 12:
        return const Color(0xFFBD0000);
      case 13:
        return const Color(0xFFBD7E7E);
      case 14:
        return const Color(0xFF810000);
      case 20:
        return const Color(0xFFFF7F00);
      case 30:
        return const Color(0xFFFF7F7F);
      case 40:
        return const Color(0xFFFF3F3F);
      case 50:
        return const Color(0xFF7F3F00);
      case 60:
        return const Color(0xFFFF7F3F);
      case 70:
        return const Color(0xFFBD7E00);
      case 80:
        return const Color(0xFF7F7F00);
      case 90:
        return const Color(0xFFBDBD00);
      case 91:
        return const Color(0xFF7FFF7F);
      case 92:
        return const Color(0xFF00BD00);
      case 93:
        return const Color(0xFF007F00);
      case 94:
        return const Color(0xFF3FFF3F);
      case 95:
        return const Color(0xFF00FF7F);
      case 100:
        return const Color(0xFF00BDBD);
      case 110:
        return const Color(0xFF7FFFFF);
      case 120:
        return const Color(0xFF007FBD);
      case 130:
        return const Color(0xFF0000BD);
      case 140:
        return const Color(0xFF3F3FFF);
      case 150:
        return const Color(0xFF00007F);
      case 160:
        return const Color(0xFF7F7FFF);
      case 170:
        return const Color(0xFF3F00BD);
      case 180:
        return const Color(0xFF7F00FF);
      case 190:
        return const Color(0xFFBD007F);
      case 200:
        return const Color(0xFFFF00FF);
      case 210:
        return const Color(0xFFFF7FFF);
      case 220:
        return const Color(0xFFFF3FBD);
      case 230:
        return const Color(0xFFBDBDBD);
      case 240:
        return const Color(0xFF7F7F7F);
      case 250:
        return const Color(0xFF3F3F3F);
      case 251:
        return const Color(0xFFC0C0C0);
      case 252:
        return const Color(0xFF989898);
      case 253:
        return const Color(0xFF707070);
      case 254:
        return const Color(0xFF484848);
      case 255:
        return const Color(0xFF000000);
      default:
        return const Color(0xFFFFFFFF);
    }
  }

  Color _getLayerColor(String layer) {
    final layerUpper = layer.toUpperCase();

    if (layerUpper.contains('측점') ||
        layerUpper.contains('NO') ||
        layerUpper.contains('STA')) {
      return Colors.cyan;
    } else if (layerUpper.contains('계획') ||
        layerUpper.contains('PLAN') ||
        layerUpper.contains('DESIGN')) {
      return Colors.red;
    } else if (layerUpper.contains('현황') || layerUpper.contains('EXIST')) {
      return Colors.green;
    } else if (layerUpper.contains('제방') ||
        layerUpper.contains('BANK') ||
        layerUpper.contains('LEVEE')) {
      return Colors.yellow;
    } else if (layerUpper.contains('홍수위') ||
        layerUpper.contains('FLOOD') ||
        layerUpper.contains('WATER')) {
      return Colors.blue;
    } else if (layerUpper.contains('문자') ||
        layerUpper.contains('TEXT') ||
        layerUpper.contains('DIM')) {
      return Colors.white70;
    } else if (layerUpper.contains('포장') ||
        layerUpper.contains('PAVEMENT') ||
        layerUpper.contains('PAVE')) {
      return Colors.grey[400]!;
    } else if (layerUpper.contains('중심') ||
        layerUpper.contains('CENTER') ||
        layerUpper.contains('CL')) {
      return Colors.orange;
    } else if (layerUpper.contains('경계') ||
        layerUpper.contains('BOUNDARY') ||
        layerUpper.contains('BORDER')) {
      return Colors.purple;
    } else {
      return Colors.white;
    }
  }

  void _drawLine(
    Canvas canvas,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
    Paint paint,
  ) {
    final x1 = entity['x1'] as double;
    final y1 = entity['y1'] as double;
    final x2 = entity['x2'] as double;
    final y2 = entity['y2'] as double;

    canvas.drawLine(transform(x1, y1), transform(x2, y2), paint);
  }

  void _drawPolyline(
    Canvas canvas,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
    Paint paint,
  ) {
    final points = entity['points'] as List;
    if (points.length < 2) return;

    final path = Path();
    final firstPoint = points[0] as Map<String, dynamic>;
    final start = transform(firstPoint['x'], firstPoint['y']);
    path.moveTo(start.dx, start.dy);

    for (int i = 0; i < points.length - 1; i++) {
      final p1 = points[i] as Map<String, dynamic>;
      final p2 = points[i + 1] as Map<String, dynamic>;
      final bulge = p1['bulge'] as double? ?? 0.0;

      if (bulge.abs() > 1e-10) {
        _drawBulgeSegment(
          path,
          p1['x'], p1['y'],
          p2['x'], p2['y'],
          bulge,
          transform,
        );
      } else {
        final end = transform(p2['x'], p2['y']);
        path.lineTo(end.dx, end.dy);
      }
    }

    final closed = entity['closed'] as bool? ?? false;
    if (closed && points.isNotEmpty) {
      final lastPoint = points.last as Map<String, dynamic>;
      final firstPoint = points.first as Map<String, dynamic>;
      final bulge = lastPoint['bulge'] as double? ?? 0.0;

      if (bulge.abs() > 1e-10) {
        _drawBulgeSegment(
          path,
          lastPoint['x'], lastPoint['y'],
          firstPoint['x'], firstPoint['y'],
          bulge,
          transform,
        );
      } else {
        path.close();
      }
    }

    canvas.drawPath(path, paint);
  }

  /// Bulge → arc 변환 (Lee Mac 공식)
  ///
  /// DXF bulge 정의:
  ///   bulge = tan(포함각/4)
  ///   양수 = CCW (Y-up 기준), 음수 = CW
  ///
  /// Y축 반전(transform)에 의해 화면에서 방향이 뒤집히므로:
  ///   DXF 양수 bulge(CCW) → 화면 CW → clockwise: true
  ///   DXF 음수 bulge(CW)  → 화면 CCW → clockwise: false
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

    // radius = chord × (1 + bulge²) / (4 × |bulge|)
    final absB = bulge.abs();
    final radius = (chord * (1 + absB * absB)) / (4 * absB);

    // DXF: 양수 bulge = CCW, 음수 bulge = CW
    // Flutter arcToPoint clockwise 기본값 = true
    // Y축 반전 후에도 arcToPoint가 화면 좌표 기준으로 자체 판단하므로
    // 원본 bulge 부호를 그대로 사용: 양수 = CCW → clockwise: false
    path.arcToPoint(
      p2Screen,
      radius: Radius.circular(radius),
      clockwise: bulge < 0,
      largeArc: absB > 1.0,
    );
  }

  void _drawCircle(
    Canvas canvas,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
    Paint paint,
    double scale,
  ) {
    final cx = entity['cx'] as double;
    final cy = entity['cy'] as double;
    final radius = entity['radius'] as double;

    final center = transform(cx, cy);
    canvas.drawCircle(center, radius * scale, paint);
  }

  /// ★ ARC 엔티티: Y축 반전에 따른 각도 보정 추가
  void _drawArc(
    Canvas canvas,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
    Paint paint,
    double scale,
  ) {
    final cx = entity['cx'] as double;
    final cy = entity['cy'] as double;
    final radius = entity['radius'] as double;
    final startAngle = entity['startAngle'] as double;
    final endAngle = entity['endAngle'] as double;

    final center = transform(cx, cy);
    final scaledRadius = radius * scale;

    // DXF: degree, CCW, Y-up → Flutter: radian, Y-down
    // Y축 반전으로 각도 부호 반전
    final startRad = -startAngle * pi / 180.0;

    // DXF arc 포함각 (항상 CCW: endAngle - startAngle)
    double includedDeg = endAngle - startAngle;
    if (includedDeg <= 0) includedDeg += 360.0;

    // Y축 반전 후 CW가 되므로 sweep은 음수
    final sweepRad = -includedDeg * pi / 180.0;

    final rect = Rect.fromCircle(center: center, radius: scaledRadius);
    canvas.drawArc(rect, startRad, sweepRad, false, paint);
  }

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

    if (scaledHeight < 2.0) return;

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

  void _drawPoint(
    Canvas canvas,
    Map<String, dynamic> entity,
    Offset Function(double, double) transform,
    Paint paint,
  ) {
    final x = entity['x'] as double;
    final y = entity['y'] as double;

    final position = transform(x, y);
    canvas.drawCircle(position, 2.0, paint..style = PaintingStyle.fill);
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

    final strokePaint = Paint()
      ..color = paint.color.withValues(alpha: 0.5)
      ..strokeWidth = 0.5
      ..style = PaintingStyle.stroke;

    // 모든 경계를 하나의 combinedPath에 합침
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
      // 솔리드 해치: 채우기 + 경계선
      final fillPaint = Paint()
        ..color = paint.color.withValues(alpha: 0.3)
        ..style = PaintingStyle.fill;
      canvas.drawPath(combinedPath, fillPaint);
      canvas.drawPath(combinedPath, strokePaint);
    } else {
      // 패턴 해치: 반투명 배경 + 패턴 라인
      final bgPaint = Paint()
        ..color = paint.color.withValues(alpha: 0.1)
        ..style = PaintingStyle.fill;
      canvas.drawPath(combinedPath, bgPaint);

      canvas.save();
      canvas.clipPath(combinedPath);

      final patternPaint = Paint()
        ..color = paint.color.withValues(alpha: 0.7)
        ..strokeWidth = 0.5
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
      // 경계선
      canvas.drawPath(combinedPath, strokePaint);
    }
  }

  /// 해치 패턴 라인 한 세트를 그리기
  /// angle: 라인 방향(도), ox/oy: 원점(DXF), dx/dy: 반복 오프셋(DXF), dashes: 대시 패턴(DXF 단위)
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
    // DXF 단위의 반복 간격 (dy가 라인 간 수직 간격)
    final spacing = dy.abs() * patternScale;
    if (spacing < 1e-6) return;

    // 화면 좌표 기준 간격
    final screenSpacing = spacing * scale;
    // 간격이 너무 작으면 그리지 않음 (2px 미만이면 의미없음)
    if (screenSpacing < 2.0) return;

    // 클립 영역의 화면 크기
    final clipW = clipBounds.width;
    final clipH = clipBounds.height;
    final diagScreen = sqrt(clipW * clipW + clipH * clipH);

    // 필요한 라인 수 계산 — 제한 초과 시 간격 늘려서 그리기
    var actualSpacing = screenSpacing;
    var lineCount = (diagScreen / actualSpacing).ceil() + 2;
    // 라인이 너무 많으면 간격을 늘려서 최대 150개로 제한
    if (lineCount > 150) {
      actualSpacing = diagScreen / 150.0;
      lineCount = 150;
    }

    // 화면 좌표에서 직접 라인 그리기 (Y축 반전 고려)
    final angleRad = angle * pi / 180.0;
    final screenAngleRad = -angleRad;
    final sDirX = cos(screenAngleRad);
    final sDirY = sin(screenAngleRad);
    final sPerpX = -sDirY;
    final sPerpY = sDirX;

    final centerX = clipBounds.center.dx;
    final centerY = clipBounds.center.dy;
    final halfLineLen = diagScreen;

    // 대시는 간격이 충분할 때만
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

  /// 대시 패턴 라인 그리기 (양수=그리기, 음수=빈칸, 0=점)
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
        // 점 (dot)
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

        // 호 시작점으로 이동
        final saRad = -sa * pi / 180.0;
        final startPt = Offset(center.dx + scaledR * cos(saRad), center.dy + scaledR * sin(saRad));
        if (first) { path.moveTo(startPt.dx, startPt.dy); first = false; }
        else { path.lineTo(startPt.dx, startPt.dy); }

        // sweep 계산
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
        oldDelegate.hiddenLayers != hiddenLayers;
  }
}
