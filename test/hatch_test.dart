import 'dart:io';
import '../lib/services/dxf_service.dart';

void main() {
  final content = File('assets/sample_data/거정천.dxf').readAsStringSync();
  final result = DxfService.parseDxfEntities(content);
  final entities = result['entities'] as List;
  
  int hatchCount = 0;
  for (final e in entities) {
    if (e['type'] == 'HATCH') {
      hatchCount++;
      final pl = e['patternLines'] as List;
      final boundaries = e['boundaries'] as List;
      int totalSegs = 0;
      for (final b in boundaries) totalSegs += (b as List).length;
      print('HATCH #$hatchCount: layer=${e['layer']}, pattern=${e['patternName']}, solid=${e['solid']}, '
            'boundaries=${boundaries.length}, segs=$totalSegs, patternLines=${pl.length}, '
            'scale=${e['patternScale']}, angle=${e['patternAngle']}');
      if (pl.isNotEmpty) {
        for (int i = 0; i < pl.length; i++) {
          print('  line[$i]: angle=${pl[i]['angle']}, dy=${pl[i]['dy']}, dx=${pl[i]['dx']}, dashes=${pl[i]['dashes']}');
        }
      } else {
        print('  ** NO PATTERN LINES **');
      }
    }
  }
  print('\nTotal HATCH entities: $hatchCount');
}
