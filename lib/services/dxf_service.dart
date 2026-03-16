import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'cp949_decoder.dart';

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

  /// DXF 바이트에서 코드페이지를 감지하여 올바른 문자열로 디코딩
  /// AutoCAD는 ANSI_949로 표기하지만 실제 UTF-8인 경우가 많으므로
  /// UTF-8을 먼저 시도하고 실패 시 CP949로 폴백합니다.
  static String decodeDxfBytes(List<int> bytes) {
    final header = latin1.decode(bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes);
    final isAnsi949 = header.contains('ANSI_949');

    // UTF-8 먼저 시도 (ANSI_949 표기여도 실제 UTF-8인 경우 다수)
    try {
      final result = utf8.decode(bytes);
      debugPrint('[DXF Decode] UTF-8 디코딩 성공 (codepage=${isAnsi949 ? "ANSI_949" : "other"})');
      return result;
    } catch (_) {}

    // UTF-8 실패 시 CP949 시도
    if (isAnsi949) {
      debugPrint('[DXF Decode] UTF-8 실패 → CP949 디코딩');
      return decodeCP949(bytes);
    }

    // 그 외 latin1 폴백
    debugPrint('[DXF Decode] latin1 폴백');
    return latin1.decode(bytes);
  }

  /// DXF 바이트의 인코딩이 CP949인지 확인
  /// 헤더의 ANSI_949 표기만으로는 불충분 — 실제 UTF-8 디코딩 가능 여부로 판단
  static bool isCP949(List<int> bytes) {
    final header = latin1.decode(bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes);
    if (!header.contains('ANSI_949')) return false;
    // 실제 UTF-8로 디코딩 가능하면 UTF-8 파일 (ANSI_949 표기지만)
    try {
      utf8.decode(bytes);
      return false; // UTF-8 성공 → CP949 아님
    } catch (_) {
      return true; // UTF-8 실패 → 진짜 CP949
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
      } else if (code == 370) {
        currentEntity['lineweight'] = int.tryParse(value);
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
        } else if (code == 43) {
          currentEntity['constantWidth'] = double.tryParse(value) ?? 0.0;
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

    // 패턴 데이터 파싱: 코드 41=축척, 52=패턴각도, 78=패턴 라인 수
    double patternScale = 1.0;
    double patternAngle = 0.0; // 코드 52: 해치 패턴 전체 회전 각도
    final patternLines = <Map<String, dynamic>>[];
    // 경계 뒤부터 패턴 데이터 탐색
    int pi = i;
    while (pi < hatchEnd - 1) {
      final c = int.tryParse(lines[pi].trim());
      if (c == null) { pi++; continue; }
      final v = lines[pi + 1].trim();
      pi += 2;
      if (c == 41) { patternScale = double.tryParse(v) ?? 1.0; }
      else if (c == 52) { patternAngle = double.tryParse(v) ?? 0.0; }
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
      'patternAngle': patternAngle,
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
    final insertLw = insert['lineweight'] as int?;
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
      final lw = be['lineweight'] as int? ?? insertLw;

      switch (type) {
        case 'LINE':
          final x1 = (be['x1'] as double?) ?? 0;
          final y1 = (be['y1'] as double?) ?? 0;
          final x2 = (be['x2'] as double?) ?? 0;
          final y2 = (be['y2'] as double?) ?? 0;
          result.add({
            'type': 'LINE', 'layer': layer, 'color': color, 'lineweight': lw,
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
            'type': 'LWPOLYLINE', 'layer': layer, 'color': color, 'lineweight': lw,
            'points': newPoints, 'closed': be['closed'] ?? false,
            'constantWidth': be['constantWidth'],
          });
          break;
        case 'CIRCLE':
          final cx = (be['cx'] as double?) ?? 0;
          final cy = (be['cy'] as double?) ?? 0;
          final r = (be['radius'] as double?) ?? 0;
          result.add({
            'type': 'CIRCLE', 'layer': layer, 'color': color, 'lineweight': lw,
            'cx': tx(cx, cy), 'cy': ty(cx, cy),
            'radius': r * ((sx.abs() + sy.abs()) / 2),
          });
          break;
        case 'ARC':
          final cx = (be['cx'] as double?) ?? 0;
          final cy = (be['cy'] as double?) ?? 0;
          final r = (be['radius'] as double?) ?? 0;
          final sa = (be['startAngle'] as double?) ?? 0;
          final ea = (be['endAngle'] as double?) ?? 0;
          result.add({
            'type': 'ARC', 'layer': layer, 'color': color, 'lineweight': lw,
            'cx': tx(cx, cy), 'cy': ty(cx, cy),
            'radius': r * ((sx.abs() + sy.abs()) / 2),
            'startAngle': sa + rotDeg, 'endAngle': ea + rotDeg,
          });
          break;
        case 'TEXT':
          final x = (be['x'] as double?) ?? 0;
          final y = (be['y'] as double?) ?? 0;
          result.add({
            'type': 'TEXT', 'layer': layer, 'color': color, 'lineweight': lw,
            'x': tx(x, y), 'y': ty(x, y),
            'text': be['text'] ?? '', 'height': ((be['height'] as double?) ?? 2.5) * sy.abs(),
          });
          break;
        case 'POINT':
          final x = (be['x'] as double?) ?? 0;
          final y = (be['y'] as double?) ?? 0;
          result.add({
            'type': 'POINT', 'layer': layer, 'color': color, 'lineweight': lw,
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
      } else if (code == 370) {
        currentEntity['lineweight'] = int.tryParse(value);
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
        } else if (code == 43) {
          currentEntity['constantWidth'] = double.tryParse(value) ?? 0.0;
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

  /// 레이어 테이블에서 lineweight 정보 추출
  static Map<String, int> _parseLayerLineweights(String dxfContent) {
    final layerLineweights = <String, int>{};
    final lines = dxfContent.split('\n');
    String? currentLayerName;
    bool inLayerRecord = false;

    for (int i = 0; i < lines.length - 1; i += 2) {
      final code = int.tryParse(lines[i].trim());
      if (code == null) { i--; continue; }
      final value = lines[i + 1].trim();

      if (code == 100 && value == 'AcDbLayerTableRecord') {
        inLayerRecord = true;
        continue;
      }
      if (inLayerRecord) {
        if (code == 2) {
          currentLayerName = value;
        } else if (code == 370 && currentLayerName != null) {
          final lw = int.tryParse(value);
          if (lw != null && lw > 0) {
            layerLineweights[currentLayerName] = lw;
          }
        } else if (code == 0) {
          inLayerRecord = false;
          currentLayerName = null;
        }
      }
    }
    return layerLineweights;
  }

  /// lineweight 값(hundredths of mm)을 화면 strokeWidth(px)로 변환
  static double _resolveLineweight(int? entityLw, String layer,
      Map<String, int> layerLineweights, double? constantWidth) {
    // LWPOLYLINE constantWidth가 있으면 DXF 단위 폭 (scale은 painter에서 적용)
    if (constantWidth != null && constantWidth > 0) {
      return -constantWidth; // 음수 = DXF 단위 폭 (painter에서 scale 곱해야 함)
    }

    int lw = entityLw ?? -1;
    // -1 = ByLayer
    if (lw == -1) {
      lw = layerLineweights[layer] ?? -1;
    }
    // -2 = ByBlock, -3 = Default, 0 = 기본
    if (lw <= 0) return 0.5; // 기본 두께

    // hundredths of mm → pixel width
    // 25 (0.25mm) → 0.5px, 50 (0.50mm) → 1.0px, 100 (1.0mm) → 2.0px
    return (lw / 50.0).clamp(0.5, 8.0);
  }

  /// colorCode → ARGB int 변환 (파싱 시 1회만 수행)
  static int _resolveColor(int? colorCode, String layer, Map<String, int> layerColors) {
    int? code = colorCode;
    if (code == null || code == 0) {
      code = layerColors[layer];
    }
    if (code == null || code == 0) {
      return _layerNameToARGB(layer);
    }
    return _aciToARGB(code.abs());
  }

  static int _aciToARGB(int aci) {
    switch (aci) {
      case 1: return 0xFFFF0000;
      case 2: return 0xFFFFFF00;
      case 3: return 0xFF00FF00;
      case 4: return 0xFF00FFFF;
      case 5: return 0xFF0000FF;
      case 6: return 0xFFFF00FF;
      case 7: return 0xFFFFFFFF;
      case 8: return 0xFF414141;
      case 9: return 0xFF808080;
      case 10: return 0xFFFF0000;
      case 11: return 0xFFFFAAAA;
      case 12: return 0xFFBD0000;
      case 13: return 0xFFBD7E7E;
      case 14: return 0xFF810000;
      case 20: return 0xFFFF7F00;
      case 30: return 0xFFFF7F7F;
      case 40: return 0xFFFF3F3F;
      case 50: return 0xFF7F3F00;
      case 60: return 0xFFFF7F3F;
      case 70: return 0xFFBD7E00;
      case 80: return 0xFF7F7F00;
      case 90: return 0xFFBDBD00;
      case 91: return 0xFF7FFF7F;
      case 92: return 0xFF00BD00;
      case 93: return 0xFF007F00;
      case 94: return 0xFF3FFF3F;
      case 95: return 0xFF00FF7F;
      case 100: return 0xFF00BDBD;
      case 110: return 0xFF7FFFFF;
      case 120: return 0xFF007FBD;
      case 130: return 0xFF0000BD;
      case 140: return 0xFF3F3FFF;
      case 150: return 0xFF00007F;
      case 160: return 0xFF7F7FFF;
      case 170: return 0xFF3F00BD;
      case 180: return 0xFF7F00FF;
      case 190: return 0xFFBD007F;
      case 200: return 0xFFFF00FF;
      case 210: return 0xFFFF7FFF;
      case 220: return 0xFFFF3FBD;
      case 230: return 0xFFBDBDBD;
      case 240: return 0xFF7F7F7F;
      case 250: return 0xFF3F3F3F;
      case 251: return 0xFFC0C0C0;
      case 252: return 0xFF989898;
      case 253: return 0xFF707070;
      case 254: return 0xFF484848;
      case 255: return 0xFF000000;
      default: return 0xFFFFFFFF;
    }
  }

  static int _layerNameToARGB(String layer) {
    final u = layer.toUpperCase();
    if (u.contains('측점') || u.contains('NO') || u.contains('STA')) return 0xFF00E5FF; // cyan
    if (u.contains('계획') || u.contains('PLAN') || u.contains('DESIGN')) return 0xFFF44336; // red
    if (u.contains('현황') || u.contains('EXIST')) return 0xFF4CAF50; // green
    if (u.contains('제방') || u.contains('BANK') || u.contains('LEVEE')) return 0xFFFFEB3B; // yellow
    if (u.contains('홍수위') || u.contains('FLOOD') || u.contains('WATER')) return 0xFF2196F3; // blue
    if (u.contains('문자') || u.contains('TEXT') || u.contains('DIM')) return 0xB3FFFFFF; // white70
    if (u.contains('포장') || u.contains('PAVEMENT') || u.contains('PAVE')) return 0xFFBDBDBD; // grey400
    if (u.contains('중심') || u.contains('CENTER') || u.contains('CL')) return 0xFFFF9800; // orange
    if (u.contains('경계') || u.contains('BOUNDARY') || u.contains('BORDER')) return 0xFF9C27B0; // purple
    return 0xFFFFFFFF; // white
  }

  /// DXF 엔티티 파싱 — raw 파서를 단일 소스로 사용
  static Map<String, dynamic> parseDxfEntities(String dxfContent) {
    final entities = <Map<String, dynamic>>[];
    final layers = <String>{};

    // 1) 레이어 색상/선두께 추출
    final layerColors = _parseLayerColors(dxfContent);
    final layerLineweights = _parseLayerLineweights(dxfContent);

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
      final resolvedColor = _resolveColor(raw['color'] as int?, layer, layerColors);
      final resolvedLw = _resolveLineweight(
        raw['lineweight'] as int?, layer, layerLineweights,
        raw['constantWidth'] as double?,
      );

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
          'resolvedColor': resolvedColor,
          'lw': resolvedLw,
          'x1': x1, 'y1': y1,
          'x2': x2, 'y2': y2,
          'aabb': [min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)],
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
        // AABB 계산 (벌지 호는 반경 추정으로 마진 포함)
        double pMinX = double.infinity, pMinY = double.infinity;
        double pMaxX = double.negativeInfinity, pMaxY = double.negativeInfinity;
        for (final p in points) {
          final px = (p['x'] as double?) ?? 0;
          final py = (p['y'] as double?) ?? 0;
          if (px < pMinX) pMinX = px;
          if (py < pMinY) pMinY = py;
          if (px > pMaxX) pMaxX = px;
          if (py > pMaxY) pMaxY = py;
        }
        // 벌지가 있으면 호의 돌출분 마진 추가
        for (int pi = 0; pi < points.length; pi++) {
          final bulge = ((points[pi]['bulge'] as double?) ?? 0).abs();
          if (bulge > 1e-10) {
            final p1x = (points[pi]['x'] as double?) ?? 0;
            final p1y = (points[pi]['y'] as double?) ?? 0;
            final p2 = points[(pi + 1) % points.length];
            final p2x = (p2['x'] as double?) ?? 0;
            final p2y = (p2['y'] as double?) ?? 0;
            final dx = p2x - p1x;
            final dy = p2y - p1y;
            final chord = sqrt(dx * dx + dy * dy);
            final sagitta = chord * bulge / 2;
            if (sagitta.abs() > 0) {
              pMinX -= sagitta.abs();
              pMinY -= sagitta.abs();
              pMaxX += sagitta.abs();
              pMaxY += sagitta.abs();
            }
          }
        }
        entities.add({
          'type': 'LWPOLYLINE',
          'layer': layer,
          'color': colorCode,
          'resolvedColor': resolvedColor,
          'lw': resolvedLw,
          'points': points,
          'closed': raw['closed'] ?? false,
          'aabb': [pMinX, pMinY, pMaxX, pMaxY],
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
          'resolvedColor': resolvedColor,
          'lw': resolvedLw,
          'cx': cx, 'cy': cy, 'radius': radius,
          'aabb': [cx - radius, cy - radius, cx + radius, cy + radius],
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
          'resolvedColor': resolvedColor,
          'lw': resolvedLw,
          'cx': cx, 'cy': cy, 'radius': radius,
          'startAngle': startAngle, 'endAngle': endAngle,
          'aabb': [cx - radius, cy - radius, cx + radius, cy + radius],
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

        // 텍스트 AABB: 대략적으로 높이×글자수 크기
        final textWidth = height * text.length * 0.7;
        entities.add({
          'type': 'TEXT',
          'layer': layer,
          'color': colorCode,
          'resolvedColor': resolvedColor,
          'lw': resolvedLw,
          'x': x, 'y': y,
          'text': text, 'height': height,
          'aabb': [x, y, x + textWidth, y + height],
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
          'resolvedColor': resolvedColor,
          'lw': resolvedLw,
          'x': x, 'y': y,
          'aabb': [x, y, x, y],
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
          'resolvedColor': resolvedColor,
          'solid': raw['solid'] ?? false,
          'patternName': raw['patternName'] ?? '',
          'boundaries': boundaries,
          'patternScale': raw['patternScale'] ?? 1.0,
          'patternAngle': raw['patternAngle'] ?? 0.0,
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

  /// DXF 색상코드 (ARGB → ACI 근사)
  static int _argbToAci(int argb) {
    final r = (argb >> 16) & 0xFF;
    final g = (argb >> 8) & 0xFF;
    final b = argb & 0xFF;
    // 기본 ACI 색상 매핑
    const aciColors = <int, List<int>>{
      1: [255, 0, 0],       // 빨강
      2: [255, 255, 0],     // 노랑
      3: [0, 255, 0],       // 초록
      4: [0, 255, 255],     // 시안
      5: [0, 0, 255],       // 파랑
      6: [255, 0, 255],     // 마젠타
      7: [255, 255, 255],   // 흰색
      8: [128, 128, 128],   // 회색
      9: [192, 192, 192],   // 밝은회색
      10: [255, 0, 0],
      30: [255, 127, 0],    // 주황
      50: [255, 255, 0],
      90: [0, 255, 0],
      150: [0, 255, 255],
      210: [0, 0, 255],
    };
    int bestAci = 7;
    double bestDist = double.infinity;
    for (final entry in aciColors.entries) {
      final dr = (r - entry.value[0]).toDouble();
      final dg = (g - entry.value[1]).toDouble();
      final db = (b - entry.value[2]).toDouble();
      final dist = dr * dr + dg * dg + db * db;
      if (dist < bestDist) {
        bestDist = dist;
        bestAci = entry.key;
      }
    }
    // 연두색 (0xFF00FF00 계열) → ACI 3
    if (g > 200 && r > 100 && r < 255 && b < 100) return 3;
    return bestAci;
  }

  /// DXF 그룹코드-값 쌍을 한 줄씩 기록
  static void _w(StringBuffer sb, int code, String value) {
    sb.write('${code.toString()}\n${value}\n');
  }

  /// 엔티티 하나를 AC1032 호환 DXF 바이트로 변환 (핸들+서브클래스 마커 포함)
  static List<int> _entityToDxfBytes(Map<String, dynamic> e, int handleNum, String nl, {bool useCP949 = false, String ownerHandle = '1F'}) {
    final buf = <int>[];
    final nlBytes = nl.codeUnits;
    final type = e['type'] as String?;
    if (type == null) return [];
    final layer = (e['layer'] ?? '0').toString();
    final color = e['resolvedColor'] != null
        ? _argbToAci((e['resolvedColor'] as num).toInt())
        : (e['color'] as int? ?? 7);
    final handle = handleNum.toRadixString(16).toUpperCase();

    /// 그룹코드+값을 바이트로 기록 (그룹코드는 3자리 우측정렬)
    void w(int code, String value, {bool mayContainKorean = false}) {
      buf.addAll(code.toString().padLeft(3).codeUnits);
      buf.addAll(nlBytes);
      if (mayContainKorean && useCP949) {
        buf.addAll(encodeCP949(value));
      } else if (mayContainKorean) {
        buf.addAll(utf8.encode(value));
      } else {
        buf.addAll(value.codeUnits);
      }
      buf.addAll(nlBytes);
    }

    switch (type) {
      case 'LINE':
        w(0, 'LINE');
        w(5, handle);
        w(330, ownerHandle);
        w(100, 'AcDbEntity');
        w(8, layer, mayContainKorean: true);
        w(62, color.toString());
        w(100, 'AcDbLine');
        w(10, (e['x1'] as num).toDouble().toString());
        w(20, (e['y1'] as num).toDouble().toString());
        w(30, '0.0');
        w(11, (e['x2'] as num).toDouble().toString());
        w(21, (e['y2'] as num).toDouble().toString());
        w(31, '0.0');
        break;
      case 'CIRCLE':
        w(0, 'CIRCLE');
        w(5, handle);
        w(330, ownerHandle);
        w(100, 'AcDbEntity');
        w(8, layer, mayContainKorean: true);
        w(62, color.toString());
        w(100, 'AcDbCircle');
        w(10, (e['cx'] as num).toDouble().toString());
        w(20, (e['cy'] as num).toDouble().toString());
        w(30, '0.0');
        w(40, (e['radius'] as num).toDouble().toString());
        break;
      case 'ARC':
        w(0, 'ARC');
        w(5, handle);
        w(330, ownerHandle);
        w(100, 'AcDbEntity');
        w(8, layer, mayContainKorean: true);
        w(62, color.toString());
        w(100, 'AcDbCircle');
        w(10, (e['cx'] as num).toDouble().toString());
        w(20, (e['cy'] as num).toDouble().toString());
        w(30, '0.0');
        w(40, (e['radius'] as num).toDouble().toString());
        w(100, 'AcDbArc');
        w(50, (e['startAngle'] as num).toDouble().toString());
        w(51, (e['endAngle'] as num).toDouble().toString());
        break;
      case 'TEXT':
        w(0, 'TEXT');
        w(5, handle);
        w(330, ownerHandle);
        w(100, 'AcDbEntity');
        w(8, layer, mayContainKorean: true);
        w(62, color.toString());
        w(100, 'AcDbText');
        w(10, (e['x'] as num).toDouble().toString());
        w(20, (e['y'] as num).toDouble().toString());
        w(30, '0.0');
        w(40, (e['height'] as num? ?? 1.0).toDouble().toString());
        w(1, (e['text'] ?? '').toString(), mayContainKorean: true);
        w(100, 'AcDbText');
        break;
      case 'POINT':
        w(0, 'POINT');
        w(5, handle);
        w(330, ownerHandle);
        w(100, 'AcDbEntity');
        w(8, layer, mayContainKorean: true);
        w(62, color.toString());
        w(100, 'AcDbPoint');
        w(10, (e['x'] as num).toDouble().toString());
        w(20, (e['y'] as num).toDouble().toString());
        w(30, '0.0');
        break;
      case 'LWPOLYLINE':
        final points = e['points'] as List?;
        if (points == null || points.isEmpty) break;
        w(0, 'LWPOLYLINE');
        w(5, handle);
        w(330, ownerHandle);
        w(100, 'AcDbEntity');
        w(8, layer, mayContainKorean: true);
        w(62, color.toString());
        w(100, 'AcDbPolyline');
        w(90, points.length.toString());
        w(70, (e['closed'] == true) ? '1' : '0');
        w(43, '0.0');
        for (final pt in points) {
          w(10, (pt['x'] as num).toDouble().toString());
          w(20, (pt['y'] as num).toDouble().toString());
          w(42, ((pt['bulge'] as num?) ?? 0.0).toDouble().toString());
        }
        break;
    }
    return buf;
  }

  /// 원본 DXF 바이너리에서 가장 큰 핸들 번호를 찾아 반환
  static int _findMaxHandle(List<int> data) {
    int maxHandle = 0;
    final content = String.fromCharCodes(data);
    // 그룹코드 5 뒤의 핸들 값 찾기
    final regex = RegExp(r'[\r\n]\s*5\r?\n\s*([0-9A-Fa-f]+)\r?\n');
    for (final match in regex.allMatches(content)) {
      final h = int.tryParse(match.group(1)!, radix: 16) ?? 0;
      if (h > maxHandle) maxHandle = h;
    }
    return maxHandle;
  }

  /// $HANDSEED 값을 업데이트 (다음 사용 가능한 핸들 번호)
  /// AutoCAD는 HANDSEED가 실제 최대 핸들보다 작으면 파일을 거부함
  static List<int> _updateHandSeed(List<int> data, int newSeed, String nl) {
    // HANDSEED 패턴: "$HANDSEED{nl}  5{nl}{hex}{nl}"
    final marker = '\$HANDSEED${nl}'.codeUnits;
    final pos = _findBytes(data, marker, 0);
    if (pos < 0) return data;

    // "  5{nl}" 찾기
    final code5Start = pos + marker.length;
    final code5Marker = '  5$nl'.codeUnits;
    if (!_matchBytes(data, code5Start, code5Marker)) return data;

    // 기존 핸들 값의 끝 위치 찾기
    final valueStart = code5Start + code5Marker.length;
    final nlBytes = nl.codeUnits;
    int valueEnd = valueStart;
    while (valueEnd < data.length) {
      if (_matchBytes(data, valueEnd, nlBytes)) break;
      valueEnd++;
    }

    // 새 HANDSEED 값으로 교체
    final newValue = newSeed.toRadixString(16).toUpperCase().codeUnits;
    final result = <int>[];
    result.addAll(data.sublist(0, valueStart));
    result.addAll(newValue);
    result.addAll(data.sublist(valueEnd));
    return result;
  }

  /// 바이트 배열의 특정 위치에서 패턴이 일치하는지 확인
  static bool _matchBytes(List<int> data, int offset, List<int> pattern) {
    if (offset + pattern.length > data.length) return false;
    for (int i = 0; i < pattern.length; i++) {
      if (data[offset + i] != pattern[i]) return false;
    }
    return true;
  }

  /// ENTITIES 섹션의 첫 번째 엔티티에서 330 (owner handle) 값을 추출
  /// 대부분 Model_Space 블록 레코드 핸들 (보통 '1F')
  static String _findModelSpaceOwner(List<int> data, String nl) {
    final marker = 'ENTITIES$nl'.codeUnits;
    final pos = _findBytes(data, marker, 0);
    if (pos < 0) return '1F';
    // ENTITIES 이후 첫 330 그룹코드 찾기
    final content = String.fromCharCodes(data.sublist(pos, (pos + 500).clamp(0, data.length)));
    final regex = RegExp(r'330\r?\n\s*([0-9A-Fa-f]+)\r?\n');
    final match = regex.firstMatch(content);
    return match?.group(1) ?? '1F';
  }

  /// 원본 DXF 바이트 데이터에 새 엔티티를 삽입하여 내보내기
  /// originalBytes가 있으면 바이너리 삽입, 없으면 새로 생성
  static Future<List<int>?> exportDxfBytes(
    Map<String, dynamic> dxfData,
    List<int>? originalBytes,
  ) async {
    try {
      final entities = dxfData['entities'] as List;
      final originalEntityCount = dxfData['_originalEntityCount'] as int? ?? 0;

      if (originalBytes != null && originalBytes.isNotEmpty) {
        // 새로 추가된 엔티티만 추출
        final newEntities = originalEntityCount > 0 && originalEntityCount < entities.length
            ? entities.sublist(originalEntityCount)
            : <dynamic>[];

        if (newEntities.isEmpty) {
          return originalBytes;
        }

        // 줄바꿈 감지
        final hasCRLF = _containsBytes(originalBytes, [13, 10]); // \r\n
        final nl = hasCRLF ? '\r\n' : '\n';

        // ENTITIES 섹션의 ENDSEC 바이트 위치 찾기
        final entitiesMarker = 'ENTITIES$nl'.codeUnits;
        final endsecMarker = '0${nl}ENDSEC$nl'.codeUnits;

        int entitiesPos = _findBytes(originalBytes, entitiesMarker, 0);
        if (entitiesPos < 0) return null;

        int endsecPos = _findBytes(originalBytes, endsecMarker, entitiesPos);
        if (endsecPos < 0) return null;

        // 최대 핸들 번호 찾기
        int handleNum = _findMaxHandle(originalBytes) + 1;

        // 인코딩 감지
        final useCP949 = isCP949(originalBytes);

        // Model_Space owner handle 찾기
        final ownerHandle = _findModelSpaceOwner(originalBytes, nl);

        // 새 엔티티 바이트 생성
        final newBytes = <int>[];
        for (final e in newEntities) {
          newBytes.addAll(_entityToDxfBytes(e, handleNum, nl, useCP949: useCP949, ownerHandle: ownerHandle));
          handleNum++;
        }

        // 원본에 삽입
        final result = <int>[];
        result.addAll(originalBytes.sublist(0, endsecPos));
        result.addAll(newBytes);
        result.addAll(originalBytes.sublist(endsecPos));

        // $HANDSEED 업데이트 (handleNum은 마지막 사용+1 상태)
        return _updateHandSeed(result, handleNum, nl);
      }

      return null;
    } catch (e) {
      debugPrint('DXF 내보내기 오류: $e');
      return null;
    }
  }

  static bool _containsBytes(List<int> data, List<int> pattern) {
    return _findBytes(data, pattern, 0) >= 0;
  }

  static int _findBytes(List<int> data, List<int> pattern, int start) {
    outer:
    for (int i = start; i <= data.length - pattern.length; i++) {
      for (int j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  /// 원본 DXF 바이트에서 특정 레이어의 엔티티를 제거
  /// dxfData의 entities/layers도 함께 수정
  /// 반환: 수정된 originalBytes (null이면 실패)
  static List<int>? removeLayerFromBytes(
    Map<String, dynamic> dxfData,
    List<int> originalBytes,
    String layerName,
  ) {
    try {
      // 줄바꿈 감지
      final hasCRLF = _containsBytes(originalBytes, [13, 10]);
      final nl = hasCRLF ? '\r\n' : '\n';
      final nlBytes = nl.codeUnits;

      // 인코딩 감지 — 레이어 이름 바이트
      final useCP949 = isCP949(originalBytes);
      List<int> layerNameBytes;
      if (useCP949) {
        try {
          layerNameBytes = utf8.encode(layerName); // 먼저 UTF-8 시도
          // CP949 파일이면 CP949 인코딩 사용
          // 하지만 실제로 파일이 CP949이더라도 레이어 이름 검색은 바이트 매칭으로
        } catch (_) {
          layerNameBytes = utf8.encode(layerName);
        }
      } else {
        layerNameBytes = utf8.encode(layerName);
      }

      // ENTITIES 섹션 위치 찾기
      final endsecMarker = '0${nl}ENDSEC$nl'.codeUnits;

      int entitiesPos = _findBytes(originalBytes, 'ENTITIES$nl'.codeUnits, 0);
      if (entitiesPos < 0) return null;

      int endsecPos = _findBytes(originalBytes, endsecMarker, entitiesPos);
      if (endsecPos < 0) return null;

      // ENTITIES 섹션 내에서 엔티티 단위로 파싱하여 필터링
      // 각 엔티티는 "0\r\n타입명\r\n" 으로 시작
      final entityStartMarker = '0$nl'.codeUnits;
      final layerGroupCode = '8$nl'.codeUnits; // 그룹코드 8 = 레이어

      // ENTITIES 마커 다음부터 ENDSEC까지의 영역
      final sectionStart = entitiesPos + 'ENTITIES$nl'.codeUnits.length;

      // 엔티티 시작 위치들 수집
      final entityPositions = <int>[];
      int pos = sectionStart;
      while (pos < endsecPos) {
        int nextEntity = _findBytes(originalBytes, entityStartMarker, pos);
        if (nextEntity < 0 || nextEntity >= endsecPos) break;
        entityPositions.add(nextEntity);
        pos = nextEntity + entityStartMarker.length;
        // 엔티티 타입명 건너뛰기 (다음 줄)
        while (pos < endsecPos && originalBytes[pos] != nlBytes[0]) pos++;
        pos += nlBytes.length;
      }

      // 삭제할 엔티티 범위 수집
      final removeRanges = <(int, int)>[];
      for (int i = 0; i < entityPositions.length; i++) {
        final start = entityPositions[i];
        final end = i + 1 < entityPositions.length ? entityPositions[i + 1] : endsecPos;

        // 이 엔티티의 레이어 확인 (그룹코드 8 검색)
        int searchPos = start;
        bool isTargetLayer = false;
        while (searchPos < end - layerGroupCode.length - layerNameBytes.length) {
          // "8\r\n" 찾기
          if (_matchBytes(originalBytes, searchPos, layerGroupCode)) {
            // 다음 줄이 레이어 이름인지 확인
            final nameStart = searchPos + layerGroupCode.length;
            // 줄 끝까지 읽기
            int nameEnd = nameStart;
            while (nameEnd < end && originalBytes[nameEnd] != nlBytes[0]) nameEnd++;
            final nameBytes = originalBytes.sublist(nameStart, nameEnd);

            // 레이어 이름 비교 (UTF-8 또는 CP949)
            String foundName;
            try {
              foundName = utf8.decode(nameBytes);
            } catch (_) {
              foundName = String.fromCharCodes(nameBytes);
            }
            if (foundName.trim() == layerName) {
              isTargetLayer = true;
              break;
            }
          }
          searchPos++;
        }

        if (isTargetLayer) {
          removeRanges.add((start, end));
        }
      }

      if (removeRanges.isEmpty) return originalBytes; // 삭제할 게 없음

      // 바이트 재조립 (삭제 범위 제외)
      final result = <int>[];
      int lastEnd = 0;
      for (final (start, end) in removeRanges) {
        result.addAll(originalBytes.sublist(lastEnd, start));
        lastEnd = end;
      }
      result.addAll(originalBytes.sublist(lastEnd));

      // dxfData에서도 제거
      final entities = dxfData['entities'] as List;
      entities.removeWhere((e) => e['layer'] == layerName);
      final layers = dxfData['layers'] as List;
      layers.remove(layerName);
      // originalEntityCount 업데이트
      dxfData['_originalEntityCount'] = entities.length;

      debugPrint('[DXF] 레이어 "$layerName" 삭제: ${removeRanges.length}개 엔티티 제거');
      return result;
    } catch (e) {
      debugPrint('[DXF] 레이어 삭제 오류: $e');
      return null;
    }
  }

  /// 원본 DXF 바이트에서 특정 엔티티 1개를 제거
  /// entityIndex: dxfData['entities'] 내 인덱스
  static List<int>? removeEntityFromBytes(
    Map<String, dynamic> dxfData,
    List<int> originalBytes,
    int entityIndex,
  ) {
    try {
      final entities = dxfData['entities'] as List;
      if (entityIndex < 0 || entityIndex >= entities.length) return null;

      final entity = entities[entityIndex];
      final entityLayer = entity['layer'] as String?;
      final entityType = entity['type'] as String?;

      // 줄바꿈 감지
      final hasCRLF = _containsBytes(originalBytes, [13, 10]);
      final nl = hasCRLF ? '\r\n' : '\n';
      final nlBytes = nl.codeUnits;

      // ENTITIES 섹션 위치
      int entitiesPos = _findBytes(originalBytes, 'ENTITIES$nl'.codeUnits, 0);
      if (entitiesPos < 0) return null;
      final endsecMarker = '0${nl}ENDSEC$nl'.codeUnits;
      int endsecPos = _findBytes(originalBytes, endsecMarker, entitiesPos);
      if (endsecPos < 0) return null;

      final sectionStart = entitiesPos + 'ENTITIES$nl'.codeUnits.length;
      final entityStartMarker = '0$nl'.codeUnits;

      // 모든 엔티티 위치 수집
      final entityPositions = <int>[];
      int pos = sectionStart;
      while (pos < endsecPos) {
        int nextEntity = _findBytes(originalBytes, entityStartMarker, pos);
        if (nextEntity < 0 || nextEntity >= endsecPos) break;
        entityPositions.add(nextEntity);
        pos = nextEntity + entityStartMarker.length;
        while (pos < endsecPos && originalBytes[pos] != nlBytes[0]) pos++;
        pos += nlBytes.length;
      }

      // entityIndex번째로 매칭되는 엔티티 찾기
      // dxfData의 entities 순서와 바이트 내 순서가 같다고 가정
      if (entityIndex >= entityPositions.length) return null;

      final start = entityPositions[entityIndex];
      final end = entityIndex + 1 < entityPositions.length ? entityPositions[entityIndex + 1] : endsecPos;

      // 바이트 재조립
      final result = <int>[];
      result.addAll(originalBytes.sublist(0, start));
      result.addAll(originalBytes.sublist(end));

      // dxfData에서도 제거
      entities.removeAt(entityIndex);
      dxfData['_originalEntityCount'] = entities.length;

      debugPrint('[DXF] 엔티티 삭제: #$entityIndex type=$entityType layer=$entityLayer');
      return result;
    } catch (e) {
      debugPrint('[DXF] 엔티티 삭제 오류: $e');
      return null;
    }
  }

  /// DXF 파일 저장 (바이너리)
  static Future<bool> saveDxfToFile(
    Map<String, dynamic> dxfData,
    String filePath, {
    List<int>? originalBytes,
  }) async {
    final bytes = await exportDxfBytes(dxfData, originalBytes);
    if (bytes == null) return false;
    try {
      final file = File(filePath);
      await file.writeAsBytes(bytes);
      return true;
    } catch (e) {
      debugPrint('DXF 저장 오류: $e');
      return false;
    }
  }
}
