// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:math';
import 'package:longitudinal_viewer_mobile/services/dxf_service.dart';

void main() {
  final file = File('assets/sample_data/거정천.dxf');
  if (!file.existsSync()) {
    print('ERROR: file not found');
    return;
  }

  final content = file.readAsStringSync();
  final result = DxfService.parseDxfEntities(content);

  final bounds = result['bounds'] as Map<String, dynamic>;
  final entities = result['entities'] as List;

  print('=== BOUNDS ===');
  print('minX=${bounds['minX']}, minY=${bounds['minY']}');
  print('maxX=${bounds['maxX']}, maxY=${bounds['maxY']}');
  final dxfW = (bounds['maxX'] as double) - (bounds['minX'] as double);
  final dxfH = (bounds['maxY'] as double) - (bounds['minY'] as double);
  print('width=$dxfW, height=$dxfH');

  // simulate screen 400x800
  final scaleX = 400 * 0.9 / dxfW;
  final scaleY = 800 * 0.9 / dxfH;
  final baseScale = min(scaleX, scaleY);
  print('scaleX=$scaleX, scaleY=$scaleY, baseScale=$baseScale');

  print('\n=== HATCH ENTITIES ===');
  int hatchCount = 0;
  for (final e in entities) {
    if (e['type'] != 'HATCH') continue;
    hatchCount++;
    final patternLines = e['patternLines'] as List? ?? [];
    final isSolid = e['solid'] as bool? ?? false;
    final patternScale = e['patternScale'] as double? ?? 1.0;
    final boundaries = e['boundaries'] as List? ?? [];

    print('HATCH #$hatchCount: pattern=${e['patternName']}, solid=$isSolid, patternScale=$patternScale, boundaries=${boundaries.length}, patternLines=${patternLines.length}');

    if (patternLines.isNotEmpty && !isSolid) {
      for (int i = 0; i < patternLines.length; i++) {
        final pl = patternLines[i];
        final dy = ((pl['dy'] as double?) ?? 0) * patternScale;
        final baseSpacing = dy.abs();
        final screenSpacing = baseSpacing * baseScale;
        int skipFactor = 1;
        if (screenSpacing < 2.0) {
          skipFactor = (4.0 / screenSpacing).ceil();
        }
        print('  line[$i]: angle=${pl['angle']}, dx=${pl['dx']}, dy=${pl['dy']}, dashes=${pl['dashes']}');
        print('    dy*scale=$dy, baseSpacing=$baseSpacing, screenSpacing=$screenSpacing, skipFactor=$skipFactor');
      }

      // compute bbox of first boundary
      if (boundaries.isNotEmpty) {
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
            }
          }
        }
        print('  boundary bbox: ${(bMaxX-bMinX).toStringAsFixed(1)}x${(bMaxY-bMinY).toStringAsFixed(1)}');
      }
    }
  }
  print('\nTotal HATCH entities: $hatchCount');
}
