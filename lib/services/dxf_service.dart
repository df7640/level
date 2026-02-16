import 'dart:io';
import 'dart:math';
import 'package:file_picker/file_picker.dart';
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
          print('DXF 파일이 아닙니다');
          return null;
        }
      }
      return null;
    } catch (e) {
      print('DXF 파일 선택 오류: $e');
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
      print('DXF 파일 로드 오류 (assets): $e');
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
      print('DXF 파일 로드 오류: $e');
      return null;
    }
  }

  /// DXF 내용 파싱
  static Map<String, dynamic>? parseDxfContent(String content) {
    try {
      return parseDxfEntities(content);
    } catch (e) {
      print('DXF 파싱 오류: $e');
      return null;
    }
  }

  /// DXF 원본에서 엔티티 정보 추출 (bulge, 색상 등)
  /// 그룹코드-값 쌍 단위(i += 2)로 올바르게 파싱
  static List<Map<String, dynamic>> _parseRawDxfEntities(String dxfContent) {
    final rawEntities = <Map<String, dynamic>>[];
    final lines = dxfContent.split('\n');

    // ENTITIES 섹션 찾기
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
      // ENTITIES 섹션을 찾지 못한 경우, 전체 파일에서 파싱 시도
      entitiesStart = 0;
    }

    Map<String, dynamic>? currentEntity;
    List<Map<String, dynamic>>? currentPolylinePoints;
    final supportedTypes = {'LWPOLYLINE', 'LINE', 'CIRCLE', 'ARC', 'TEXT', 'POINT'};

    void saveCurrentEntity() {
      if (currentEntity == null) return;
      final e = currentEntity;
      final type = e['type'] as String?;
      if (type == 'LWPOLYLINE' && currentPolylinePoints != null) {
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
        // 그룹코드가 아니면 1줄만 건너뛰기 (비정상 라인 처리)
        i--;
        continue;
      }
      final value = lines[i + 1].trim();

      // 그룹 코드 0 = 새로운 엔티티
      if (code == 0) {
        saveCurrentEntity();
        currentEntity = null;
        currentPolylinePoints = null;

        if (supportedTypes.contains(value)) {
          currentEntity = {'type': value};
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
    saveCurrentEntity();

    print('[DXF Parser] 원본 파싱 완료: ${rawEntities.length}개 엔티티');

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
              print('[DXF Parser] Bulge 발견: layer=${entity['layer']}, bulge=$bulge, x=${point['x']}, y=${point['y']}');
            }
          }
        }
      }
    }
    print('[DXF Parser] Bulge가 있는 점: $bulgeCount개');

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

    print('[DXF Parser] 레이어 색상 맵: ${layerColors.length}개');
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

    print('[DXF Parser] 좌표 수: ${allXCoords.length}개');
    print('[DXF Parser] 유효 범위: X=[$validMinX ~ $validMaxX], Y=[$validMinY ~ $validMaxY]');

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
      }
    }

    print('[DXF Parser] 파싱 완료: ${entities.length}개 엔티티, ${layers.length}개 레이어');
    print('[DXF Parser] 경계: minX=$minX, minY=$minY, maxX=$maxX, maxY=$maxY');

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
