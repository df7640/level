import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'nmea_parser.dart';
import 'coordinate_service.dart';

enum GnssConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// GNSS 위치 상태
class GnssPosition {
  final double tmX;       // EPSG:5186 Easting (= DXF X)
  final double tmY;       // EPSG:5186 Northing (= DXF Y)
  final double latitude;  // WGS84
  final double longitude; // WGS84
  final double? altitude;
  final int fixQuality;
  final int satellites;
  final DateTime? utcTime;

  const GnssPosition({
    required this.tmX,
    required this.tmY,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.fixQuality = 0,
    this.satellites = 0,
    this.utcTime,
  });

  String get fixLabel {
    switch (fixQuality) {
      case 1: return 'GPS';
      case 2: return 'DGPS';
      case 4: return 'RTK';
      case 5: return 'Float';
      default: return 'N/A';
    }
  }
}

/// 블루투스 GNSS 통합 서비스
/// BT 연결 → NMEA 수신 → 파싱 → 좌표 변환 → 실시간 위치 노출
class BluetoothGnssService extends ChangeNotifier {
  BluetoothConnection? _connection;
  GnssConnectionState _connectionState = GnssConnectionState.disconnected;
  String? _deviceName;
  GnssPosition? _position;
  final NmeaParser _parser = NmeaParser();
  String _buffer = '';

  GnssConnectionState get connectionState => _connectionState;
  String? get deviceName => _deviceName;
  GnssPosition? get position => _position;

  /// 페어링된 블루투스 기기 목록
  Future<List<BluetoothDevice>> getPairedDevices() async {
    try {
      return await FlutterBluetoothSerial.instance.getBondedDevices();
    } catch (e) {
      debugPrint('[GNSS] 페어링 기기 조회 실패: $e');
      return [];
    }
  }

  /// 블루투스 기기에 연결
  Future<void> connect(BluetoothDevice device) async {
    _connectionState = GnssConnectionState.connecting;
    _deviceName = device.name ?? device.address;
    notifyListeners();

    try {
      _connection = await BluetoothConnection.toAddress(device.address);
      _connectionState = GnssConnectionState.connected;
      notifyListeners();

      debugPrint('[GNSS] 연결됨: $_deviceName');

      _connection!.input!.listen(
        (Uint8List data) {
          _buffer += utf8.decode(data, allowMalformed: true);
          _processBuffer();
        },
        onDone: () {
          debugPrint('[GNSS] 연결 종료');
          _connectionState = GnssConnectionState.disconnected;
          _position = null;
          notifyListeners();
        },
        onError: (error) {
          debugPrint('[GNSS] 수신 오류: $error');
          _connectionState = GnssConnectionState.error;
          notifyListeners();
        },
      );
    } catch (e) {
      debugPrint('[GNSS] 연결 실패: $e');
      _connectionState = GnssConnectionState.error;
      notifyListeners();
    }
  }

  /// NMEA 버퍼 처리
  void _processBuffer() {
    while (_buffer.contains('\r\n')) {
      final idx = _buffer.indexOf('\r\n');
      final sentence = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 2);

      if (!sentence.startsWith('\$')) continue;

      final nmeaPos = _parser.parse(sentence);
      if (nmeaPos != null && nmeaPos.hasValidFix) {
        final tm = CoordinateService.wgs84ToTm(
          nmeaPos.latitude,
          nmeaPos.longitude,
        );

        _position = GnssPosition(
          tmX: tm.x,
          tmY: tm.y,
          latitude: nmeaPos.latitude,
          longitude: nmeaPos.longitude,
          altitude: nmeaPos.altitude,
          fixQuality: nmeaPos.fixQuality,
          satellites: nmeaPos.satellites,
          utcTime: nmeaPos.utcTime,
        );
        notifyListeners();
      }
    }
  }

  /// 연결 해제
  Future<void> disconnect() async {
    try {
      await _connection?.close();
    } catch (_) {}
    _connection = null;
    _connectionState = GnssConnectionState.disconnected;
    _position = null;
    _buffer = '';
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
