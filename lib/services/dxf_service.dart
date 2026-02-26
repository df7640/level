import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// DXF 파일 처리 서비스
class DxfService {
  /// DXF 파일 선택
  static Future<String?> pickDxfFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any, // DXF 파일 선택 허용
        allowMultiple: false,
      );

      if (result != null && result.files.isNotEmpty) {
        final path = result.files.first.path;
        // DXF 파일인지 확인
        if (path != null && path.toLowerCase().endsWith('.dxf')) {
          return path;
        } else {
          debugPrint('DXF 파일이 아닙니다');
          return null;
        }
      }
      return null;
    } catch (e) {
      debugPrint('DXF 파일 선택 오류: $e');
      return null;
    }
  }

  /// Assets에서 DXF 파일 읽기
  static Future<Map<String, dynamic>?> loadDxfFromAssets(
      String assetPath) async {
    try {
      final content = await rootBundle.loadString(assetPath);
      return parseDxfContent(content);
    } catch (e) {
      debugPrint('DXF 파일 로드 오류 (assets): $e');
      return null;
    }
  }

  /// DXF 파일 읽기 (파일 시스템)
  static Future<Map<String, dynamic>?> loadDxfFile(String filePath) async {
    try {
      final file = File(filePath);
      final content = await file.readAsString();
      return parseDxfContent(content);
    } catch (e) {
      debugPrint('DXF 파일 로드 오류: $e');
      return null;
    }
  }

  /// DXF 내용 파싱
  static Map<String, dynamic>? parseDxfContent(String content) {
    try {
      return parseDxfEntities(content);
    } catch (e) {
      debugPrint('DXF 파싱 오류: $e');
      return null;
    }
  }

  /// BLOCKS 섹션에서 블록 정의를 파싱
  /// 반환: { 블록이름: [엔티티 목록] }
  static Map<String, List<Map<String, dynamic>>> _parseBlocks(List<String> lines) {
    final blocks = <String, List<Map<String, dynamic>>>{};

    // BLOCKS 섹션 찾기
    int blocksStart = -1;
    int blocksEnd = lines.length;
    for (int i = 0; i < lines.length - 1; i += 2) {
      final code = lines[i].trim();
      final value = lines[i + 1].trim();
      if (code == '2' && value == 'BLOCKS') {
        blocksStart = i + 2;
      }
      if (blocksStart > 0 && code == '0' && value == 'ENDSEC') {
        blocksEnd = i;
        break;
      }
    }

    if (blocksStart < 0) return blocks;

    String? currentBlockName;
    List<Map<String, dynamic>>? currentBlockEntities;
    Map<String, dynamic>? currentEntity;
    List<Map<String, dynamic>>? currentPolylinePoints;
    bool inBlock = false;
    final supportedTypes = {'LWPOLYLINE', 'LINE', 'CIRCLE', 'ARC', 'TEXT', 'POINT'};

    void saveCurrentEntity() {
      if (currentEntity == null || currentBlockEntities == null) return;
      final e = currentEntity;
      final type = e['type'] as String?;
      if (type == 'LWPOLYLINE' && currentPolylinePoints != null) {
        e['points'] = currentPolylinePoints;
        currentBlockEntities.add(e);
      } else if (type == 'LINE' &&
          e.containsKey('x1') && e.containsKey('y1') &&
          e.containsKey('x2') && e.containsKey('y2')) {
        currentBlockEntities.add(e);
      } else if (type == 'CIRCLE' &&
          e.containsKey('cx') && e.containsKey('radius')) {
        currentBlockEntities.add(e);
      } else if (type == 'ARC' &&
          e.containsKey('cx') && e.containsKey('radius')) {
        currentBlockEntities.add(e);
      } else if (type == 'TEXT' && e.containsKey('text')) {
        currentBlockEntities.add(e);
      } else if (type == 'POINT' && e.containsKey('x')) {
        currentBlockEntities.add(e);
      }
    }

    for (int i = blocksStart; i < blocksEnd - 1; i += 2) {
      final code = int.tryParse(lines[i].trim());
      if (code == null) {
        i--;
        continue;
      }
      final value = lines[i + 1].trim();

      if (code == 0) {
        if (value == 'BLOCK') {
          inBlock = true;
          currentBlockName = null;
          currentBlockEntities = [];
          currentEntity = null;
          currentPolylinePoints = null;
          continue;
        }
        if (value == 'ENDBLK') {
          saveCurrentEntity();
          if (currentBlockName != null &&
              currentBlockEntities != null &&
              currentBlockEntities.isNotEmpty &&
              !currentBlockName.startsWith('*')) {
            blocks[currentBlockName] = currentBlockEntities;
          }
          inBlock = false;
          currentBlockName = null;
          currentBlockEntities = null;
          currentEntity = null;
          currentPolylinePoints = null;
          continue;
        }

        if (inBlock) {
          saveCurrentEntity();
          currentEntity = null;
          currentPolylinePoints = null;

          if (supportedTypes.contains(value)) {
            currentEntity = {'type': value};
            if (value == 'LWPOLYLINE') {
              currentPolylinePoints = [];
            }
          }
        }
        continue;
      }

      // BLOCK 헤더에서 블록 이름 읽기 (코드 2)
      if (inBlock && currentBlockEntities != null && currentBlockName == null && code == 2) {
        currentBlockName = value;
        continue;
      }

      if (!inBlock || currentEntity == null) continue;
      final type = currentEntity['type'] as String;

      // 공통 그룹 코드
      if (code == 8) {
        currentEntity['layer'] = value;
      } else if (code == 62) {
        currentEntity['color'] = int.tryParse(value);
      }
      // 엔티티별 처리 (ENTITIES 섹션과 동일)
      else if (type == 'LWPOLYLINE' && currentPolylinePoints != null) {
        if (code == 10) {
          currentPolylinePoints.add({'x': double.tryParse(value) ?? 0.0, 'y': 0.0, 'bulge': 0.0});
        } else if (code == 20 && currentPolylinePoints.isNotEmpty) {
          currentPolylinePoints.last['y'] = double.tryParse(value) ?? 0.0;
        } else if (code == 42 && currentPolylinePoints.isNotEmpty) {
          currentPolylinePoints.last['bulge'] = double.tryParse(value) ?? 0.0;
        } else if (code == 70) {
          currentEntity['closed'] = ((int.tryParse(value) ?? 0) & 1) != 0;
        }
      } else if (type == 'LINE') {
        if (code == 10) currentEntity['x1'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['y1'] = double.tryParse(value) ?? 0.0;
        else if (code == 11) currentEntity['x2'] = double.tryParse(value) ?? 0.0;
        else if (code == 21) currentEntity['y2'] = double.tryParse(value) ?? 0.0;
      } else if (type == 'CIRCLE') {
        if (code == 10) currentEntity['cx'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['cy'] = double.tryParse(value) ?? 0.0;
        else if (code == 40) currentEntity['radius'] = double.tryParse(value) ?? 0.0;
      } else if (type == 'ARC') {
        if (code == 10) currentEntity['cx'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['cy'] = double.tryParse(value) ?? 0.0;
        else if (code == 40) currentEntity['radius'] = double.tryParse(value) ?? 0.0;
        else if (code == 50) currentEntity['startAngle'] = double.tryParse(value) ?? 0.0;
        else if (code == 51) currentEntity['endAngle'] = double.tryParse(value) ?? 0.0;
      } else if (type == 'TEXT') {
        if (code == 10) currentEntity['x'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['y'] = double.tryParse(value) ?? 0.0;
        else if (code == 1) currentEntity['text'] = value;
        else if (code == 40) currentEntity['height'] = double.tryParse(value) ?? 2.5;
      } else if (type == 'POINT') {
        if (code == 10) currentEntity['x'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['y'] = double.tryParse(value) ?? 0.0;
      }
    }

    debugPrint('[DXF Parser] 블록 파싱: ${blocks.length}개 블록 (${blocks.keys.join(', ')})');
    return blocks;
  }

  /// HATCH 엔티티 파싱: 경계 경로를 포함한 HATCH 엔티티 반환
  static List<Map<String, dynamic>> _parseHatchBoundary(
    List<String> lines, int hatchStart, int sectionEnd, String? layer, int? color,
  ) {
    final hatchLayer = layer ?? '0';

    // HATCH 엔티티의 끝 찾기 (다음 코드 0)
    int hatchEnd = sectionEnd;
    for (int i = hatchStart + 2; i < sectionEnd - 1; i += 2) {
      final code = int.tryParse(lines[i].trim());
      if (code == null) { i--; continue; }
      if (code == 0) {
        hatchEnd = i;
        break;
      }
    }

    // 해치 패턴 이름 읽기 (코드 2), 솔리드 여부 (코드 70), 경계 수 (코드 91)
    String patternName = '';
    int solidFlag = 0;
    int boundaryCount = 0;
    for (int i = hatchStart; i < hatchEnd - 1; i += 2) {
      final c = int.tryParse(lines[i].trim());
      if (c == null) { i--; continue; }
      final v = lines[i + 1].trim();
      if (c == 2) patternName = v;
      else if (c == 70) solidFlag = int.tryParse(v) ?? 0;
      else if (c == 91) { boundaryCount = int.tryParse(v) ?? 0; break; }
    }

    final isSolid = solidFlag == 1 || patternName.toUpperCase() == 'SOLID';

    // 경계 경로 파싱: 코드 92로 각 경계 경로 시작
    final boundaries = <List<Map<String, dynamic>>>[]; // 각 경계 = 세그먼트 리스트
    int i = hatchStart;
    int boundariesParsed = 0;
    while (i < hatchEnd - 1) {
      final code = int.tryParse(lines[i].trim());
      if (code == null) { i++; continue; }
      final value = lines[i + 1].trim();
      i += 2;

      if (code != 92) {
        // 경계를 모두 파싱했으면 루프 탈출 (읽은 코드 되감기)
        if (boundaryCount > 0 && boundariesParsed >= boundaryCount) {
          i -= 2;
          break;
        }
        continue;
      }

      final pathType = int.tryParse(value) ?? 0;
      final isPolyline = (pathType & 2) != 0;

      if (isPolyline) {
        bool hasBulge = false;
        int vertexCount = 0;
        final points = <Map<String, dynamic>>[];

        while (i < hatchEnd - 1) {
          final c = int.tryParse(lines[i].trim());
          if (c == null) { i++; continue; }
          final v = lines[i + 1].trim();
          i += 2;

          if (c == 72) { hasBulge = (int.tryParse(v) ?? 0) != 0; }
          else if (c == 73) { /* closed flag */ }
          else if (c == 93) { vertexCount = int.tryParse(v) ?? 0; }
          else if (c == 10) {
            points.add({'x': double.tryParse(v) ?? 0.0, 'y': 0.0, 'bulge': 0.0});
          } else if (c == 20 && points.isNotEmpty) {
            points.last['y'] = double.tryParse(v) ?? 0.0;
            // y좌표까지 읽은 뒤 개수 체크
            if (points.length >= vertexCount && vertexCount > 0) break;
          } else if (c == 42 && hasBulge && points.isNotEmpty) {
            points.last['bulge'] = double.tryParse(v) ?? 0.0;
          }
        }

        if (points.length >= 2) {
          // 폴리라인 경계 → 세그먼트 리스트로 변환
          final segs = <Map<String, dynamic>>[];
          for (int k = 0; k < points.length; k++) {
            final p1 = points[k];
            final p2 = points[(k + 1) % points.length];
            final bulge = (p1['bulge'] as double?) ?? 0.0;
            if (bulge.abs() > 1e-10) {
              segs.add({'edge': 'bulge', 'x1': p1['x'], 'y1': p1['y'], 'x2': p2['x'], 'y2': p2['y'], 'bulge': bulge});
            } else {
              segs.add({'edge': 'line', 'x1': p1['x'], 'y1': p1['y'], 'x2': p2['x'], 'y2': p2['y']});
            }
          }
          boundaries.add(segs);
          boundariesParsed++;
        }
      } else {
        // 에지 경계
        int edgeCount = 0;
        while (i < hatchEnd - 1) {
          final c = int.tryParse(lines[i].trim());
          if (c == null) { i++; continue; }
          final v = lines[i + 1].trim();
          if (c == 93) {
            edgeCount = int.tryParse(v) ?? 0;
            i += 2;
            break;
          }
          i += 2;
        }

        final segs = <Map<String, dynamic>>[];
        for (int e = 0; e < edgeCount && i < hatchEnd - 1; e++) {
          int edgeType = 0;
          while (i < hatchEnd - 1) {
            final c = int.tryParse(lines[i].trim());
            if (c == null) { i++; continue; }
            final v = lines[i + 1].trim();
            i += 2;
            if (c == 72) {
              edgeType = int.tryParse(v) ?? 0;
              break;
            }
          }

          if (edgeType == 1) {
            // LINE: 10,20 시작점, 11,21 끝점
            double x1 = 0, y1 = 0, x2 = 0, y2 = 0;
            int found = 0;
            while (found < 4 && i < hatchEnd - 1) {
              final c = int.tryParse(lines[i].trim());
              if (c == null) { i++; continue; }
              // 다음 에지(72) 또는 다음 경계(92)를 만나면 중단
              if (c == 72 || c == 92) break;
              final v = lines[i + 1].trim();
              i += 2;
              if (c == 10) { x1 = double.tryParse(v) ?? 0; found++; }
              else if (c == 20) { y1 = double.tryParse(v) ?? 0; found++; }
              else if (c == 11) { x2 = double.tryParse(v) ?? 0; found++; }
              else if (c == 21) { y2 = double.tryParse(v) ?? 0; found++; }
            }
            if (found >= 4) {
              segs.add({'edge': 'line', 'x1': x1, 'y1': y1, 'x2': x2, 'y2': y2});
            }
          } else if (edgeType == 2) {
            // ARC: 10,20=center, 40=radius, 50=start, 51=end, 73=ccw
            double cx = 0, cy = 0, radius = 0, sa = 0, ea = 0;
            bool ccw = true;
            int found = 0;
            while (found < 6 && i < hatchEnd - 1) {
              final c = int.tryParse(lines[i].trim());
              if (c == null) { i++; continue; }
              if (c == 72 || c == 92) break;
              final v = lines[i + 1].trim();
              i += 2;
              if (c == 10) { cx = double.tryParse(v) ?? 0; found++; }
              else if (c == 20) { cy = double.tryParse(v) ?? 0; found++; }
              else if (c == 40) { radius = double.tryParse(v) ?? 0; found++; }
              else if (c == 50) { sa = double.tryParse(v) ?? 0; found++; }
              else if (c == 51) { ea = double.tryParse(v) ?? 0; found++; }
              else if (c == 73) { ccw = (int.tryParse(v) ?? 1) != 0; found++; }
            }
            if (found >= 5) {
              segs.add({'edge': 'arc', 'cx': cx, 'cy': cy, 'radius': radius, 'startAngle': sa, 'endAngle': ea, 'ccw': ccw});
            }
          } else {
            // 미지원 에지 타입 (ELLIPSE ARC, SPLINE 등) — 이 에지의 데이터를 건너뛰기
            while (i < hatchEnd - 1) {
              final c = int.tryParse(lines[i].trim());
              if (c == null) { i++; continue; }
              if (c == 72 || c == 92) break;
              i += 2;
            }
          }
        }
        if (segs.isNotEmpty) {
          boundaries.add(segs);
          boundariesParsed++;
        }
      }
    }

    if (boundaries.isEmpty) return [];

    // 패턴 데이터 파싱: 코드 78=패턴 라인 수, 각 라인=53/43/44/45/46/79/49
    double patternScale = 1.0;
    final patternLines = <Map<String, dynamic>>[];
    // 경계 뒤부터 패턴 데이터 탐색
    int pi = i;
    while (pi < hatchEnd - 1) {
      final c = int.tryParse(lines[pi].trim());
      if (c == null) { pi++; continue; }
      final v = lines[pi + 1].trim();
      pi += 2;
      if (c == 41) { patternScale = double.tryParse(v) ?? 1.0; }
      else if (c == 78) {
        final lineCount = int.tryParse(v) ?? 0;
        for (int li = 0; li < lineCount && pi < hatchEnd - 1; li++) {
          double angle = 0, ox = 0, oy = 0, dx = 0, dy = 0;
          final dashes = <double>[];
          while (pi < hatchEnd - 1) {
            final lc = int.tryParse(lines[pi].trim());
            if (lc == null) { pi++; continue; }
            final lv = lines[pi + 1].trim();
            pi += 2;
            if (lc == 53) { angle = double.tryParse(lv) ?? 0; }
            else if (lc == 43) { ox = double.tryParse(lv) ?? 0; }
            else if (lc == 44) { oy = double.tryParse(lv) ?? 0; }
            else if (lc == 45) { dx = double.tryParse(lv) ?? 0; }
            else if (lc == 46) { dy = double.tryParse(lv) ?? 0; }
            else if (lc == 79) {
              final dashCount = int.tryParse(lv) ?? 0;
              for (int di = 0; di < dashCount && pi < hatchEnd - 1; di++) {
                final dc = int.tryParse(lines[pi].trim());
                if (dc == null) { pi++; di--; continue; }
                final dv = lines[pi + 1].trim();
                pi += 2;
                if (dc == 49) { dashes.add(double.tryParse(dv) ?? 0); }
              }
              patternLines.add({
                'angle': angle, 'ox': ox, 'oy': oy,
                'dx': dx, 'dy': dy, 'dashes': dashes,
              });
              break;
            }
          }
        }
        break;
      }
    }

    if (patternLines.isNotEmpty) {
      debugPrint('[HATCH] pattern=$patternName, scale=$patternScale, lines=${patternLines.length}');
      for (final pl in patternLines) {
        debugPrint('[HATCH]   angle=${pl['angle']}, dy=${pl['dy']}, dashes=${pl['dashes']}');
      }
    }

    return [{
      'type': 'HATCH',
      'layer': hatchLayer,
      'color': color,
      'solid': isSolid,
      'patternName': patternName,
      'boundaries': boundaries,
      'patternScale': patternScale,
      'patternLines': patternLines,
    }];
  }

  /// INSERT를 블록 정의의 엔티티로 전개 (이동 + 스케일 + 회전 적용)
  static List<Map<String, dynamic>> _expandInsert(
    Map<String, dynamic> insert,
    Map<String, List<Map<String, dynamic>>> blocks,
  ) {
    final blockName = insert['blockName'] as String;
    final blockEntities = blocks[blockName];
    if (blockEntities == null || blockEntities.isEmpty) return [];

    final ix = (insert['x'] as double?) ?? 0.0;
    final iy = (insert['y'] as double?) ?? 0.0;
    final sx = (insert['scaleX'] as double?) ?? 1.0;
    final sy = (insert['scaleY'] as double?) ?? 1.0;
    final rotDeg = (insert['rotation'] as double?) ?? 0.0;
    final insertLayer = insert['layer'] as String?;
    final insertColor = insert['color'] as int?;
    final cosR = cos(rotDeg * pi / 180.0);
    final sinR = sin(rotDeg * pi / 180.0);

    // 점 변환: 스케일 → 회전 → 이동
    double tx(double x, double y) => x * sx * cosR - y * sy * sinR + ix;
    double ty(double x, double y) => x * sx * sinR + y * sy * cosR + iy;

    final result = <Map<String, dynamic>>[];

    for (final be in blockEntities) {
      final type = be['type'] as String;
      final layer = (be['layer'] as String?) ?? insertLayer ?? '0';
      final color = be['color'] as int? ?? insertColor;

      switch (type) {
        case 'LINE':
          final x1 = (be['x1'] as double?) ?? 0;
          final y1 = (be['y1'] as double?) ?? 0;
          final x2 = (be['x2'] as double?) ?? 0;
          final y2 = (be['y2'] as double?) ?? 0;
          result.add({
            'type': 'LINE', 'layer': layer, 'color': color,
            'x1': tx(x1, y1), 'y1': ty(x1, y1),
            'x2': tx(x2, y2), 'y2': ty(x2, y2),
          });
          break;
        case 'LWPOLYLINE':
          final points = be['points'] as List?;
          if (points == null || points.length < 2) break;
          final newPoints = points.map((p) {
            final px = (p['x'] as double?) ?? 0;
            final py = (p['y'] as double?) ?? 0;
            return {
              'x': tx(px, py),
              'y': ty(px, py),
              'bulge': (p['bulge'] as double?) ?? 0.0,
            };
          }).toList();
          result.add({
            'type': 'LWPOLYLINE', 'layer': layer, 'color': color,
            'points': newPoints, 'closed': be['closed'] ?? false,
          });
          break;
        case 'CIRCLE':
          final cx = (be['cx'] as double?) ?? 0;
          final cy = (be['cy'] as double?) ?? 0;
          final r = (be['radius'] as double?) ?? 0;
          result.add({
            'type': 'CIRCLE', 'layer': layer, 'color': color,
            'cx': tx(cx, cy), 'cy': ty(cx, cy),
            'radius': r * ((sx.abs() + sy.abs()) / 2), // 평균 스케일
          });
          break;
        case 'ARC':
          final cx = (be['cx'] as double?) ?? 0;
          final cy = (be['cy'] as double?) ?? 0;
          final r = (be['radius'] as double?) ?? 0;
          final sa = (be['startAngle'] as double?) ?? 0;
          final ea = (be['endAngle'] as double?) ?? 0;
          result.add({
            'type': 'ARC', 'layer': layer, 'color': color,
            'cx': tx(cx, cy), 'cy': ty(cx, cy),
            'radius': r * ((sx.abs() + sy.abs()) / 2),
            'startAngle': sa + rotDeg, 'endAngle': ea + rotDeg,
          });
          break;
        case 'TEXT':
          final x = (be['x'] as double?) ?? 0;
          final y = (be['y'] as double?) ?? 0;
          result.add({
            'type': 'TEXT', 'layer': layer, 'color': color,
            'x': tx(x, y), 'y': ty(x, y),
            'text': be['text'] ?? '', 'height': ((be['height'] as double?) ?? 2.5) * sy.abs(),
          });
          break;
        case 'POINT':
          final x = (be['x'] as double?) ?? 0;
          final y = (be['y'] as double?) ?? 0;
          result.add({
            'type': 'POINT', 'layer': layer, 'color': color,
            'x': tx(x, y), 'y': ty(x, y),
          });
          break;
      }
    }

    return result;
  }

  /// DXF 원본에서 엔티티 정보 추출 (bulge, 색상, 블록 전개 포함)
  /// 그룹코드-값 쌍 단위(i += 2)로 올바르게 파싱
  static List<Map<String, dynamic>> _parseRawDxfEntities(String dxfContent) {
    final rawEntities = <Map<String, dynamic>>[];
    final lines = dxfContent.split('\n');

    // 1) BLOCKS 섹션 파싱
    final blocks = _parseBlocks(lines);

    // 2) ENTITIES 섹션 찾기
    int entitiesStart = -1;
    int entitiesEnd = lines.length;
    for (int i = 0; i < lines.length - 1; i += 2) {
      final code = lines[i].trim();
      final value = lines[i + 1].trim();
      if (code == '2' && value == 'ENTITIES') {
        entitiesStart = i + 2;
      }
      if (code == '0' && value == 'ENDSEC' && entitiesStart > 0) {
        entitiesEnd = i;
        break;
      }
    }

    if (entitiesStart < 0) {
      entitiesStart = 0;
    }

    // INSERT, HATCH 엔티티도 수집
    final inserts = <Map<String, dynamic>>[];
    final hatchRanges = <({int start, String? layer, int? color})>[]; // HATCH 라인 범위
    Map<String, dynamic>? currentEntity;
    List<Map<String, dynamic>>? currentPolylinePoints;
    int currentEntityStart = -1;
    final supportedTypes = {'LWPOLYLINE', 'LINE', 'CIRCLE', 'ARC', 'TEXT', 'POINT', 'INSERT', 'HATCH'};

    void saveCurrentEntity(int endIndex) {
      if (currentEntity == null) return;
      final e = currentEntity;
      final type = e['type'] as String?;
      if (type == 'INSERT' && e.containsKey('blockName')) {
        inserts.add(e);
      } else if (type == 'HATCH') {
        hatchRanges.add((start: currentEntityStart, layer: e['layer'] as String?, color: e['color'] as int?));
      } else if (type == 'LWPOLYLINE' && currentPolylinePoints != null) {
        e['points'] = currentPolylinePoints;
        rawEntities.add(e);
      } else if (type == 'LINE' &&
          e.containsKey('x1') && e.containsKey('y1') &&
          e.containsKey('x2') && e.containsKey('y2')) {
        rawEntities.add(e);
      } else if (type == 'CIRCLE' &&
          e.containsKey('cx') && e.containsKey('radius')) {
        rawEntities.add(e);
      } else if (type == 'ARC' &&
          e.containsKey('cx') && e.containsKey('radius')) {
        rawEntities.add(e);
      } else if (type == 'TEXT' && e.containsKey('text')) {
        rawEntities.add(e);
      } else if (type == 'POINT' && e.containsKey('x')) {
        rawEntities.add(e);
      }
    }

    for (int i = entitiesStart; i < entitiesEnd - 1; i += 2) {
      final code = int.tryParse(lines[i].trim());
      if (code == null) {
        i--;
        continue;
      }
      final value = lines[i + 1].trim();

      if (code == 0) {
        saveCurrentEntity(i);
        currentEntity = null;
        currentPolylinePoints = null;

        if (supportedTypes.contains(value)) {
          currentEntity = {'type': value};
          currentEntityStart = i;
          if (value == 'LWPOLYLINE') {
            currentPolylinePoints = [];
          }
        }
        continue;
      }

      if (currentEntity == null) continue;
      final type = currentEntity['type'] as String;

      // 공통 그룹 코드
      if (code == 8) {
        currentEntity['layer'] = value;
      } else if (code == 62) {
        currentEntity['color'] = int.tryParse(value);
      }
      // INSERT 처리
      else if (type == 'INSERT') {
        if (code == 2) currentEntity['blockName'] = value;
        else if (code == 10) currentEntity['x'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['y'] = double.tryParse(value) ?? 0.0;
        else if (code == 41) currentEntity['scaleX'] = double.tryParse(value) ?? 1.0;
        else if (code == 42) currentEntity['scaleY'] = double.tryParse(value) ?? 1.0;
        else if (code == 50) currentEntity['rotation'] = double.tryParse(value) ?? 0.0;
      }
      // LWPOLYLINE 처리
      else if (type == 'LWPOLYLINE' && currentPolylinePoints != null) {
        if (code == 10) {
          currentPolylinePoints.add({
            'x': double.tryParse(value) ?? 0.0,
            'y': 0.0,
            'bulge': 0.0,
          });
        } else if (code == 20 && currentPolylinePoints.isNotEmpty) {
          currentPolylinePoints.last['y'] = double.tryParse(value) ?? 0.0;
        } else if (code == 42 && currentPolylinePoints.isNotEmpty) {
          currentPolylinePoints.last['bulge'] = double.tryParse(value) ?? 0.0;
        } else if (code == 70) {
          final flag = int.tryParse(value) ?? 0;
          currentEntity['closed'] = (flag & 1) != 0;
        }
      }
      // LINE 처리
      else if (type == 'LINE') {
        if (code == 10) currentEntity['x1'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['y1'] = double.tryParse(value) ?? 0.0;
        else if (code == 11) currentEntity['x2'] = double.tryParse(value) ?? 0.0;
        else if (code == 21) currentEntity['y2'] = double.tryParse(value) ?? 0.0;
      }
      // CIRCLE 처리
      else if (type == 'CIRCLE') {
        if (code == 10) currentEntity['cx'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['cy'] = double.tryParse(value) ?? 0.0;
        else if (code == 40) currentEntity['radius'] = double.tryParse(value) ?? 0.0;
      }
      // ARC 처리
      else if (type == 'ARC') {
        if (code == 10) currentEntity['cx'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['cy'] = double.tryParse(value) ?? 0.0;
        else if (code == 40) currentEntity['radius'] = double.tryParse(value) ?? 0.0;
        else if (code == 50) currentEntity['startAngle'] = double.tryParse(value) ?? 0.0;
        else if (code == 51) currentEntity['endAngle'] = double.tryParse(value) ?? 0.0;
      }
      // TEXT 처리
      else if (type == 'TEXT') {
        if (code == 10) currentEntity['x'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['y'] = double.tryParse(value) ?? 0.0;
        else if (code == 1) currentEntity['text'] = value;
        else if (code == 40) currentEntity['height'] = double.tryParse(value) ?? 2.5;
      }
      // POINT 처리
      else if (type == 'POINT') {
        if (code == 10) currentEntity['x'] = double.tryParse(value) ?? 0.0;
        else if (code == 20) currentEntity['y'] = double.tryParse(value) ?? 0.0;
      }
    }

    // 마지막 엔티티 저장
    saveCurrentEntity(entitiesEnd);

    // 3) INSERT 전개: 블록 엔티티를 변환하여 추가
    int expandedCount = 0;
    for (final insert in inserts) {
      final expanded = _expandInsert(insert, blocks);
      rawEntities.addAll(expanded);
      expandedCount += expanded.length;
    }

    // 4) HATCH 경계 경로 파싱
    int hatchEntityCount = 0;
    for (final h in hatchRanges) {
      final hatchEntities = _parseHatchBoundary(lines, h.start, entitiesEnd, h.layer, h.color);
      rawEntities.addAll(hatchEntities);
      hatchEntityCount += hatchEntities.length;
    }

    debugPrint('[DXF Parser] 원본 파싱 완료: ${rawEntities.length}개 엔티티 (INSERT ${inserts.length}개 → $expandedCount개 전개, HATCH ${hatchRanges.length}개 → $hatchEntityCount개 경계)');

    // bulge 값이 있는 폴리라인 확인
    int bulgeCount = 0;
    for (final entity in rawEntities) {
      if (entity['type'] == 'LWPOLYLINE' && entity['points'] != null) {
        final points = entity['points'] as List;
        for (final point in points) {
          final bulge = (point['bulge'] as double?) ?? 0.0;
          if (bulge.abs() > 0.0001) {
            bulgeCount++;
            if (bulgeCount <= 3) {
              debugPrint('[DXF Parser] Bulge 발견: layer=${entity['layer']}, bulge=$bulge, x=${point['x']}, y=${point['y']}');
            }
          }
        }
      }
    }
    debugPrint('[DXF Parser] Bulge가 있는 점: $bulgeCount개');

    return rawEntities;
  }

  /// DXF 레이어 테이블에서 색상 정보 추출
  static Map<String, int> _parseLayerColors(String dxfContent) {
    final layerColors = <String, int>{};
    final lines = dxfContent.split('\n');
    String? currentLayerName;
    bool inLayerRecord = false;

    for (int i = 0; i < lines.length - 1; i += 2) {
      final code = int.tryParse(lines[i].trim());
      if (code == null) {
        i--;
        continue;
      }
      final value = lines[i + 1].trim();

      // AcDbLayerTableRecord 서브클래스 마커 (코드 100)
      if (code == 100 && value == 'AcDbLayerTableRecord') {
        inLayerRecord = true;
        continue;
      }

      if (inLayerRecord) {
        if (code == 2) {
          currentLayerName = value;
        } else if (code == 62 && currentLayerName != null) {
          final color = int.tryParse(value);
          if (color != null) {
            layerColors[currentLayerName] = color;
          }
        } else if (code == 0) {
          // 새 테이블 엔트리 시작 → 현재 레이어 종료
          inLayerRecord = false;
          currentLayerName = null;
        }
      }
    }

    debugPrint('[DXF Parser] 레이어 색상 맵: ${layerColors.length}개');
    return layerColors;
  }

  /// DXF 엔티티 파싱 — raw 파서를 단일 소스로 사용
  static Map<String, dynamic> parseDxfEntities(String dxfContent) {
    final entities = <Map<String, dynamic>>[];
    final layers = <String>{};

    // 1) 레이어 색상 추출
    final layerColors = _parseLayerColors(dxfContent);

    // 2) raw 파서로 모든 엔티티 추출 (bulge 포함)
    final rawEntities = _parseRawDxfEntities(dxfContent);

    // 3) 엔티티 밀집 영역 탐색 — IQR 기반 outlier 제거
    //    블록 정의(원점 근처)와 실제 도면(중부원점 등)이 섞여 있을 때
    //    밀집 영역만 유효 범위로 사용
    final allXCoords = <double>[];
    final allYCoords = <double>[];

    for (final raw in rawEntities) {
      final type = raw['type'] as String;
      if (type == 'LINE') {
        allXCoords.add((raw['x1'] as double?) ?? 0);
        allYCoords.add((raw['y1'] as double?) ?? 0);
        allXCoords.add((raw['x2'] as double?) ?? 0);
        allYCoords.add((raw['y2'] as double?) ?? 0);
      } else if (type == 'LWPOLYLINE') {
        final points = raw['points'] as List?;
        if (points != null) {
          for (final p in points) {
            allXCoords.add((p['x'] as double?) ?? 0);
            allYCoords.add((p['y'] as double?) ?? 0);
          }
        }
      } else if (type == 'CIRCLE' || type == 'ARC') {
        allXCoords.add((raw['cx'] as double?) ?? 0);
        allYCoords.add((raw['cy'] as double?) ?? 0);
      } else if (type == 'TEXT' || type == 'POINT') {
        allXCoords.add((raw['x'] as double?) ?? 0);
        allYCoords.add((raw['y'] as double?) ?? 0);
      }
    }

    // IQR(사분위범위) 기반으로 유효 범위 계산
    final validRange = _computeValidRange(allXCoords, allYCoords);
    final validMinX = validRange[0];
    final validMinY = validRange[1];
    final validMaxX = validRange[2];
    final validMaxY = validRange[3];

    debugPrint('[DXF Parser] 좌표 수: ${allXCoords.length}개');
    debugPrint('[DXF Parser] 유효 범위: X=[$validMinX ~ $validMaxX], Y=[$validMinY ~ $validMaxY]');

    // 4) 유효 범위 필터링 후 엔티티 등록
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;

    for (final raw in rawEntities) {
      final type = raw['type'] as String;
      final layer = (raw['layer'] as String?) ?? '0';
      int? colorCode = raw['color'] as int?;
      if (colorCode == null || colorCode == 0) {
        colorCode = layerColors[layer];
      }

      final isSpecialLayer = layer.contains('측점') ||
          layer.startsWith('#') ||
          layer.startsWith('_');

      bool isInRange(double x, double y) {
        return isSpecialLayer ||
            (x >= validMinX && x <= validMaxX &&
             y >= validMinY && y <= validMaxY);
      }

      if (type == 'LINE') {
        final x1 = (raw['x1'] as double?) ?? 0;
        final y1 = (raw['y1'] as double?) ?? 0;
        final x2 = (raw['x2'] as double?) ?? 0;
        final y2 = (raw['y2'] as double?) ?? 0;
        if (!isInRange(x1, y1) || !isInRange(x2, y2)) continue;

        entities.add({
          'type': 'LINE',
          'layer': layer,
          'color': colorCode,
          'x1': x1, 'y1': y1,
          'x2': x2, 'y2': y2,
        });
        layers.add(layer);
        if (!isSpecialLayer) {
          _updateBounds(x1, y1, () => minX, (v) => minX = v, () => minY, (v) => minY = v,
              () => maxX, (v) => maxX = v, () => maxY, (v) => maxY = v);
          _updateBounds(x2, y2, () => minX, (v) => minX = v, () => minY, (v) => minY = v,
              () => maxX, (v) => maxX = v, () => maxY, (v) => maxY = v);
        }
      } else if (type == 'LWPOLYLINE') {
        final points = raw['points'] as List?;
        if (points == null || points.length < 2) continue;

        final allValid = isSpecialLayer || points.every((p) {
          return isInRange((p['x'] as double?) ?? 0, (p['y'] as double?) ?? 0);
        });
        if (!allValid) continue;

        // points를 그대로 사용 — bulge 정보가 이미 포함
        entities.add({
          'type': 'LWPOLYLINE',
          'layer': layer,
          'color': colorCode,
          'points': points,
          'closed': raw['closed'] ?? false,
        });
        layers.add(layer);
        if (!isSpecialLayer) {
          for (final p in points) {
            final x = (p['x'] as double?) ?? 0;
            final y = (p['y'] as double?) ?? 0;
            _updateBounds(x, y, () => minX, (v) => minX = v, () => minY, (v) => minY = v,
                () => maxX, (v) => maxX = v, () => maxY, (v) => maxY = v);
          }
        }
      } else if (type == 'CIRCLE') {
        final cx = (raw['cx'] as double?) ?? 0;
        final cy = (raw['cy'] as double?) ?? 0;
        final radius = (raw['radius'] as double?) ?? 0;
        if (!isInRange(cx, cy)) continue;

        entities.add({
          'type': 'CIRCLE',
          'layer': layer,
          'color': colorCode,
          'cx': cx, 'cy': cy, 'radius': radius,
        });
        layers.add(layer);
        if (!isSpecialLayer) {
          minX = cx - radius < minX ? cx - radius : minX;
          minY = cy - radius < minY ? cy - radius : minY;
          maxX = cx + radius > maxX ? cx + radius : maxX;
          maxY = cy + radius > maxY ? cy + radius : maxY;
        }
      } else if (type == 'ARC') {
        final cx = (raw['cx'] as double?) ?? 0;
        final cy = (raw['cy'] as double?) ?? 0;
        final radius = (raw['radius'] as double?) ?? 0;
        final startAngle = (raw['startAngle'] as double?) ?? 0;
        final endAngle = (raw['endAngle'] as double?) ?? 0;
        if (!isInRange(cx, cy)) continue;

        entities.add({
          'type': 'ARC',
          'layer': layer,
          'color': colorCode,
          'cx': cx, 'cy': cy, 'radius': radius,
          'startAngle': startAngle, 'endAngle': endAngle,
        });
        layers.add(layer);
        if (!isSpecialLayer) {
          minX = cx - radius < minX ? cx - radius : minX;
          minY = cy - radius < minY ? cy - radius : minY;
          maxX = cx + radius > maxX ? cx + radius : maxX;
          maxY = cy + radius > maxY ? cy + radius : maxY;
        }
      } else if (type == 'TEXT') {
        final x = (raw['x'] as double?) ?? 0;
        final y = (raw['y'] as double?) ?? 0;
        final text = (raw['text'] as String?) ?? '';
        final height = (raw['height'] as double?) ?? 2.5;
        if (!isInRange(x, y)) continue;

        entities.add({
          'type': 'TEXT',
          'layer': layer,
          'color': colorCode,
          'x': x, 'y': y,
          'text': text, 'height': height,
        });
        layers.add(layer);
        if (!isSpecialLayer) {
          _updateBounds(x, y, () => minX, (v) => minX = v, () => minY, (v) => minY = v,
              () => maxX, (v) => maxX = v, () => maxY, (v) => maxY = v);
        }
      } else if (type == 'POINT') {
        final x = (raw['x'] as double?) ?? 0;
        final y = (raw['y'] as double?) ?? 0;
        if (!isInRange(x, y)) continue;

        entities.add({
          'type': 'POINT',
          'layer': layer,
          'color': colorCode,
          'x': x, 'y': y,
        });
        layers.add(layer);
        if (!isSpecialLayer) {
          _updateBounds(x, y, () => minX, (v) => minX = v, () => minY, (v) => minY = v,
              () => maxX, (v) => maxX = v, () => maxY, (v) => maxY = v);
        }
      } else if (type == 'HATCH') {
        final boundaries = raw['boundaries'] as List?;
        if (boundaries == null || boundaries.isEmpty) continue;

        entities.add({
          'type': 'HATCH',
          'layer': layer,
          'color': colorCode,
          'solid': raw['solid'] ?? false,
          'patternName': raw['patternName'] ?? '',
          'boundaries': boundaries,
          'patternScale': raw['patternScale'] ?? 1.0,
          'patternLines': raw['patternLines'] ?? [],
        });
        layers.add(layer);
      }
    }

    debugPrint('[DXF Parser] 파싱 완료: ${entities.length}개 엔티티, ${layers.length}개 레이어');
    debugPrint('[DXF Parser] 경계: minX=$minX, minY=$minY, maxX=$maxX, maxY=$maxY');

    if (minX.isInfinite || minY.isInfinite) {
      minX = 0; minY = 0; maxX = 100; maxY = 100;
    }

    return {
      'entities': entities,
      'layers': layers.toList(),
      'layerColors': layerColors,
      'bounds': {
        'minX': minX, 'minY': minY,
        'maxX': maxX, 'maxY': maxY,
      },
    };
  }

  /// IQR(사분위범위) 기반 유효 좌표 범위 계산
  /// 블록 정의(원점 근처) 등 outlier를 제거하고 엔티티 밀집 영역만 반환
  /// 반환: [validMinX, validMinY, validMaxX, validMaxY]
  static List<double> _computeValidRange(List<double> xs, List<double> ys) {
    if (xs.isEmpty || ys.isEmpty) {
      return [0, 0, 100, 100];
    }

    final sortedX = List<double>.from(xs)..sort();
    final sortedY = List<double>.from(ys)..sort();

    double percentile(List<double> sorted, double p) {
      final idx = (sorted.length - 1) * p;
      final lo = idx.floor();
      final hi = idx.ceil();
      if (lo == hi) return sorted[lo];
      return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
    }

    final q1x = percentile(sortedX, 0.25);
    final q3x = percentile(sortedX, 0.75);
    final iqrX = q3x - q1x;

    final q1y = percentile(sortedY, 0.25);
    final q3y = percentile(sortedY, 0.75);
    final iqrY = q3y - q1y;

    // IQR이 극히 작으면 (모든 좌표가 거의 같은 값) 절대 마진 사용
    final marginX = max(iqrX * 3.0, 100.0);
    final marginY = max(iqrY * 3.0, 100.0);

    return [
      q1x - marginX,
      q1y - marginY,
      q3x + marginX,
      q3y + marginY,
    ];
  }

  static void _updateBounds(double x, double y,
      double Function() getMinX, void Function(double) setMinX,
      double Function() getMinY, void Function(double) setMinY,
      double Function() getMaxX, void Function(double) setMaxX,
      double Function() getMaxY, void Function(double) setMaxY) {
    if (x < getMinX()) setMinX(x);
    if (y < getMinY()) setMinY(y);
    if (x > getMaxX()) setMaxX(x);
    if (y > getMaxY()) setMaxY(y);
  }
}
