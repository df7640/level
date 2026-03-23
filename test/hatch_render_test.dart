// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'package:longitudinal_viewer_mobile/services/dxf_service.dart';

void main() {
  final file = File('assets/sample_data/거정천.dxf');
  final content = file.readAsStringSync();
  final result = DxfService.parseDxfEntities(content);

  final bounds = result['bounds'] as Map<String, dynamic>;
  final entities = result['entities'] as List;

  final bMinXG = bounds['minX'] as double;
  final bMinYG = bounds['minY'] as double;
  final bMaxXG = bounds['maxX'] as double;
  final bMaxYG = bounds['maxY'] as double;
  final dxfW = bMaxXG - bMinXG;
  final dxfH = bMaxYG - bMinYG;

  // simulate screen 400x800
  const sw = 400.0, sh = 800.0;
  final scaleX = sw * 0.9 / dxfW;
  final scaleY = sh * 0.9 / dxfH;
  final baseScale = min(scaleX, scaleY);
  final drawScale = baseScale; // zoom=1

  print('bounds: X=[$bMinXG ~ $bMaxXG], Y=[$bMinYG ~ $bMaxYG]');
  print('dxfSize: ${dxfW.toStringAsFixed(1)} x ${dxfH.toStringAsFixed(1)}');
  print('drawScale: $drawScale');
  print('');

  int idx = 0;
  for (final e in entities) {
    if (e['type'] != 'HATCH') continue;
    idx++;
    final isSolid = e['solid'] as bool? ?? false;
    if (isSolid) continue;

    final patternLines = e['patternLines'] as List? ?? [];
    if (patternLines.isEmpty) continue;

    final patternScale = (e['patternScale'] as double?) ?? 1.0;
    final patternAngle = (e['patternAngle'] as double?) ?? 0.0;
    final boundaries = e['boundaries'] as List? ?? [];

    // compute boundary bbox
    double bMinX = double.infinity, bMinY = double.infinity;
    double bMaxX = double.negativeInfinity, bMaxY = double.negativeInfinity;
    for (final boundary in boundaries) {
      for (final seg in boundary as List) {
        final edge = seg['edge'] as String;
        if (edge == 'line' || edge == 'bulge') {
          for (final k in ['x1', 'x2']) {
            final v = (seg[k] as double?) ?? 0;
            if (v < bMinX) bMinX = v;
            if (v > bMaxX) bMaxX = v;
          }
          for (final k in ['y1', 'y2']) {
            final v = (seg[k] as double?) ?? 0;
            if (v < bMinY) bMinY = v;
            if (v > bMaxY) bMaxY = v;
          }
        } else if (edge == 'arc') {
          final cx = (seg['cx'] as double?) ?? 0;
          final cy = (seg['cy'] as double?) ?? 0;
          final r = (seg['radius'] as double?) ?? 0;
          if (cx - r < bMinX) bMinX = cx - r;
          if (cx + r > bMaxX) bMaxX = cx + r;
          if (cy - r < bMinY) bMinY = cy - r;
          if (cy + r > bMaxY) bMaxY = cy + r;
        }
      }
    }
    if (bMinX >= bMaxX || bMinY >= bMaxY) continue;

    final bboxDiag = sqrt((bMaxX - bMinX) * (bMaxX - bMinX) + (bMaxY - bMinY) * (bMaxY - bMinY));

    print('HATCH #$idx: ${e['patternName']}, pScale=$patternScale, bbox=${(bMaxX-bMinX).toStringAsFixed(1)}x${(bMaxY-bMinY).toStringAsFixed(1)}, diag=${bboxDiag.toStringAsFixed(1)}');

    for (int li = 0; li < patternLines.length; li++) {
      final pl = patternLines[li];
      final baseAngle = ((pl['angle'] as double?) ?? 0) + patternAngle;
      final angleRad = baseAngle * pi / 180.0;
      final ox = ((pl['ox'] as double?) ?? 0) * patternScale;
      final oy = ((pl['oy'] as double?) ?? 0) * patternScale;
      final dx = ((pl['dx'] as double?) ?? 0) * patternScale;
      final dy = ((pl['dy'] as double?) ?? 0) * patternScale;

      if (dy.abs() < 1e-10) { print('  line[$li]: SKIP dy=0'); continue; }
      final baseSpacing = dy.abs();

      final screenSpacing = baseSpacing * drawScale;
      int skipFactor = 1;
      if (screenSpacing < 1.0) {
        skipFactor = (1.0 / screenSpacing).ceil();
      }
      // 경계 안에 최소 3개 라인이 나오도록 skipFactor 제한
      final maxSpacing = bboxDiag / 3.0;
      if (baseSpacing * skipFactor > maxSpacing && maxSpacing > baseSpacing) {
        skipFactor = (maxSpacing / baseSpacing).floor().clamp(1, skipFactor);
      }
      final spacing = baseSpacing * skipFactor;

      final perpX = -sin(angleRad);
      final perpY = cos(angleRad);
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

      print('  line[$li]: angle=${baseAngle.toStringAsFixed(1)}, dy=${dy.toStringAsFixed(4)}, baseSpacing=${baseSpacing.toStringAsFixed(4)}, screenSpacing=${screenSpacing.toStringAsFixed(4)}, skipFactor=$skipFactor, spacing=${spacing.toStringAsFixed(4)}, nMin=$nMin, nMax=$nMax, lineCount=${nMax-nMin}');
    }
    print('');
  }
}
