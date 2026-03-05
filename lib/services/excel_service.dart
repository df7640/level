import 'dart:io';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import '../models/station_data.dart';

/// Excel 파일 처리 서비스
class ExcelService {
  /// Excel 파일 선택
  static Future<String?> pickExcelFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
      );

      if (result != null && result.files.isNotEmpty) {
        return result.files.first.path;
      }
      return null;
    } catch (e) {
      debugPrint('파일 선택 오류: $e');
      return null;
    }
  }

  /// Excel 파일에서 측점 데이터 읽기
  static Future<List<StationData>> loadFromExcel(String filePath) async {
    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();
      final excel = Excel.decodeBytes(bytes);

      // 첫 번째 시트 사용
      if (excel.tables.isEmpty) {
        throw Exception('시트를 찾을 수 없습니다');
      }
      final sheet = excel.tables.values.first;

      final List<StationData> stations = [];

      // 헤더 행 찾기 (첫 번째 행)
      final headers = <String, int>{};
      final headerRow = sheet.rows.first;

      for (int i = 0; i < headerRow.length; i++) {
        final cell = headerRow[i];
        if (cell?.value != null) {
          final headerName = cell!.value.toString().trim();
          headers[headerName] = i;
        }
      }

      // 데이터 행 읽기 (헤더 제외)
      for (int rowIndex = 1; rowIndex < sheet.rows.length; rowIndex++) {
        final row = sheet.rows[rowIndex];

        // 측점 컬럼 (헤더가 '측점' 또는 'NO')
        final noIndex = headers['측점'] ?? headers['NO'];
        if (noIndex == null || row[noIndex]?.value == null) continue;

        final stationNo = row[noIndex]!.value.toString().trim();
        if (stationNo.isEmpty) continue;

        // 각 컬럼 값 추출
        final station = StationData(
          no: stationNo,
          intervalDistance: _getDoubleValue(row, headers['점간거리']),
          distance: _getDoubleValue(row, headers['누가거리']),
          gh: _getDoubleValue(row, headers['지반고']),
          deepestBedLevel: _getDoubleValue(row, headers['최심하상고']),
          ip: _getDoubleValue(row, headers['계획하상고']),
          plannedFloodLevel: _getDoubleValue(row, headers['계획홍수위']),
          leftBankHeight: _getDoubleValue(row, headers['좌안제방고']),
          rightBankHeight: _getDoubleValue(row, headers['우안제방고']),
          plannedBankLeft: _getDoubleValue(row, headers['계획제방고_좌']) ?? _getDoubleValue(row, headers['계획제방고_좌안']),
          plannedBankRight: _getDoubleValue(row, headers['계획제방고_우']) ?? _getDoubleValue(row, headers['계획제방고_우안']),
          roadbedLeft: _getDoubleValue(row, headers['노체_좌']) ?? _getDoubleValue(row, headers['노체_좌안']),
          roadbedRight: _getDoubleValue(row, headers['노체_우']) ?? _getDoubleValue(row, headers['노체_우안']),
          foundationExcavation: _getDoubleValue(row, headers['기초터파기']),
          offsetLeft: _getDoubleValue(row, headers['옵셋좌']),
          offsetRight: _getDoubleValue(row, headers['옵셋우']),
          lr: _getStringValue(row, headers['LR']),
          height: _getDoubleValue(row, headers['Height']),
          singleCount: _getDoubleValue(row, headers['단수']),
          slope: _getDoubleValue(row, headers['기울기']),
          angle: _getDoubleValue(row, headers['각도']),
          ghD: _getDoubleValue(row, headers['GH-D']),
          gh1: _getDoubleValue(row, headers['GH-1']),
          gh2: _getDoubleValue(row, headers['GH-2']),
          gh3: _getDoubleValue(row, headers['GH-3']),
          gh4: _getDoubleValue(row, headers['GH-4']),
          gh5: _getDoubleValue(row, headers['GH-5']),
          x: _getDoubleValue(row, headers['X']),
          y: _getDoubleValue(row, headers['Y']),
          actualReading: _getDoubleValue(row, headers['읽은 값']),
          targetReading: _getDoubleValue(row, headers['읽을 값']),
          cutFill: _getDoubleValue(row, headers['절/성토']),
          cutFillStatus: _getStringValue(row, headers['상태']),
          isInterpolated: stationNo.contains('+'),
          lastModified: DateTime.now(),
        );

        stations.add(station);
      }

      return stations;
    } catch (e) {
      debugPrint('Excel 파일 읽기 오류: $e');
      rethrow;
    }
  }

  /// assets에서 샘플 Excel 파일 읽기
  static Future<List<StationData>> loadSampleExcel() async {
    try {
      // assets 파일은 rootBundle 사용
      // 하지만 excel 패키지는 File이 필요하므로
      // 임시로 파일 경로 반환
      return [];
    } catch (e) {
      debugPrint('샘플 파일 로드 오류: $e');
      return [];
    }
  }

  /// Excel로 내보내기
  static Future<String?> exportToExcel(
    List<StationData> stations,
    String fileName,
  ) async {
    try {
      final excel = Excel.createExcel();
      final sheet = excel['측점데이터'];

      // 헤더 작성
      final headers = [
        '측점',
        '점간거리',
        '누가거리',
        '지반고',
        '최심하상고',
        '계획하상고',
        '계획홍수위',
        '좌안제방고',
        '우안제방고',
        '계획제방고_좌',
        '계획제방고_우',
        '노체_좌',
        '노체_우',
        '기초터파기',
        '옵셋좌',
        '옵셋우',
        'LR',
        'Height',
        '단수',
        '기울기',
        '각도',
        'X',
        'Y',
        '읽을 값',
        '읽은 값',
        '절/성토',
        '상태',
      ];

      for (int i = 0; i < headers.length; i++) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0))
          ..value = TextCellValue(headers[i])
          ..cellStyle = CellStyle(
            bold: true,
            backgroundColorHex: ExcelColor.blue,
          );
      }

      // 데이터 작성
      for (int i = 0; i < stations.length; i++) {
        final station = stations[i];
        final rowIndex = i + 1;

        final row = [
          station.no,
          station.intervalDistance,
          station.distance,
          station.gh,
          station.deepestBedLevel,
          station.ip,
          station.plannedFloodLevel,
          station.leftBankHeight,
          station.rightBankHeight,
          station.plannedBankLeft,
          station.plannedBankRight,
          station.roadbedLeft,
          station.roadbedRight,
          station.foundationExcavation,
          station.offsetLeft,
          station.offsetRight,
          station.lr,
          station.height,
          station.singleCount,
          station.slope,
          station.angle,
          station.x,
          station.y,
          station.targetReading,
          station.actualReading,
          station.cutFill,
          station.cutFillStatus,
        ];

        for (int j = 0; j < row.length; j++) {
          final value = row[j];
          if (value != null) {
            final cell = sheet.cell(
              CellIndex.indexByColumnRow(columnIndex: j, rowIndex: rowIndex),
            );

            if (value is String) {
              cell.value = TextCellValue(value);
            } else if (value is num) {
              cell.value = DoubleCellValue(value.toDouble());
            }
          }
        }
      }

      // 파일 저장
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Excel 파일 저장',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );

      if (result != null) {
        final file = File(result);
        final bytes = excel.encode();
        if (bytes != null) {
          await file.writeAsBytes(bytes);
          return result;
        }
      }

      return null;
    } catch (e) {
      debugPrint('Excel 내보내기 오류: $e');
      return null;
    }
  }

  /// 셀에서 double 값 추출
  static double? _getDoubleValue(List<Data?> row, int? index) {
    if (index == null || index >= row.length) return null;

    final cell = row[index];
    if (cell?.value == null) return null;

    final value = cell!.value;

    // Excel 4.x의 CellValue 처리
    if (value is DoubleCellValue) {
      return value.value;
    } else if (value is IntCellValue) {
      return value.value.toDouble();
    } else if (value is TextCellValue) {
      // TextSpan을 String으로 변환
      final text = value.value.text;
      if (text != null) {
        return double.tryParse(text);
      }
    }

    return null;
  }

  /// 셀에서 String 값 추출
  static String? _getStringValue(List<Data?> row, int? index) {
    if (index == null || index >= row.length) return null;

    final cell = row[index];
    if (cell?.value == null) return null;

    final value = cell!.value;

    // Excel 4.x의 CellValue 처리
    if (value is TextCellValue) {
      // TextSpan을 String으로 변환
      final text = value.value.text;
      if (text != null) {
        return text.trim();
      }
    } else if (value is DoubleCellValue) {
      return value.value.toString().trim();
    } else if (value is IntCellValue) {
      return value.value.toString().trim();
    }

    return null;
  }
}
