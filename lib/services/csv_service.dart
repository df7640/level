import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart';
import '../models/station_data.dart';

/// CSV 파일 처리 서비스
class CsvService {
  /// Assets에서 CSV 파일 읽기
  static Future<List<StationData>> loadFromAssets(String assetPath) async {
    try {
      // CSV 파일 읽기
      final csvString = await rootBundle.loadString(assetPath);

      // CSV 파싱
      final csvData = const CsvToListConverter().convert(
        csvString,
        eol: '\n',
        fieldDelimiter: ',',
      );

      if (csvData.isEmpty) {
        throw Exception('CSV 파일이 비어있습니다');
      }

      // 헤더 추출
      final headers = csvData[0].map((e) => e.toString().trim()).toList();
      final headerMap = <String, int>{};
      for (int i = 0; i < headers.length; i++) {
        headerMap[headers[i]] = i;
      }

      print('CSV 헤더: $headers');

      // 데이터 행 파싱
      final List<StationData> stations = [];

      for (int i = 1; i < csvData.length; i++) {
        final row = csvData[i];

        try {
          // 측점 번호 (NO.0, NO.1, +7.00 등)
          final no = _getStringValue(row, headerMap['측점']);
          if (no == null || no.isEmpty) continue;

          // StationData 생성 - CSV의 모든 필드 읽기
          final station = StationData(
            no: no,
            intervalDistance: _getDoubleValue(row, headerMap['점간거리']),
            distance: _getDoubleValue(row, headerMap['누가거리']),
            gh: _getDoubleValue(row, headerMap['지반고']),
            deepestBedLevel: _getDoubleValue(row, headerMap['최심하상고']),
            ip: _getDoubleValue(row, headerMap['계획하상고']),
            plannedFloodLevel: _getDoubleValue(row, headerMap['계획홍수위']),
            leftBankHeight: _getDoubleValue(row, headerMap['좌안제방고']),
            rightBankHeight: _getDoubleValue(row, headerMap['우안제방고']),
            plannedBankLeft: _getDoubleValue(row, headerMap['계획제방고_좌안']),
            plannedBankRight: _getDoubleValue(row, headerMap['계획제방고_우안']),
            roadbedLeft: _getDoubleValue(row, headerMap['노체_좌안']),
            roadbedRight: _getDoubleValue(row, headerMap['노체_우안']),
            x: _getDoubleValue(row, headerMap['X']),
            y: _getDoubleValue(row, headerMap['Y']),
            isInterpolated: no.contains('+'),
            lastModified: DateTime.now(),
          );

          stations.add(station);
        } catch (e) {
          print('행 파싱 오류 (행 ${i + 1}): $e');
          continue;
        }
      }

      print('CSV 로드 완료: ${stations.length}개 측점');
      return stations;
    } catch (e) {
      print('CSV 파일 로드 오류: $e');
      rethrow;
    }
  }

  /// 셀에서 double 값 추출
  static double? _getDoubleValue(List<dynamic> row, int? index) {
    if (index == null || index >= row.length) return null;

    final value = row[index];
    if (value == null || value == '') return null;

    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);

    return null;
  }

  /// 셀에서 String 값 추출
  static String? _getStringValue(List<dynamic> row, int? index) {
    if (index == null || index >= row.length) return null;

    final value = row[index];
    if (value == null || value == '') return null;

    return value.toString().trim();
  }
}
