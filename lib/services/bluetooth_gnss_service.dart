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
  final double? hdop;
  final double? diffAge;  // 차분 보정 나이 (초)

  const GnssPosition({
    required this.tmX,
    required this.tmY,
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.fixQuality = 0,
    this.satellites = 0,
    this.utcTime,
    this.hdop,
    this.diffAge,
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

  // 위치 유무와 관계없이 항상 업데이트되는 상태값
  int _satellites = 0;
  int _fixQuality = 0;
  double? _pdop;

  // 마지막 GGA 문장 (NTRIP VRS용)
  String? _lastGga;

  GnssConnectionState get connectionState => _connectionState;
  String? get deviceName => _deviceName;
  GnssPosition? get position => _position;
  int get satellites => _satellites;
  int get fixQuality => _fixQuality;
  double? get pdop => _pdop;
  String? get lastGga => _lastGga;

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

  /// NMEA 버퍼 처리 — 매 BT 패킷마다 즉시 파싱 + notify
  void _processBuffer() {
    bool changed = false;
    while (_buffer.contains('\n')) {
      final idx = _buffer.indexOf('\n');
      final sentence = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);

      if (!sentence.startsWith('\$')) continue;

      // GGA 캡처 (NTRIP VRS용 + 디버그)
      if (sentence.contains('GGA')) {
        _lastGga = sentence;
        debugPrint('[NMEA] $sentence');
      }

      final nmeaPos = _parser.parse(sentence);
      // GSA 등은 null 반환하지만 PDOP를 업데이트할 수 있음
      if (_parser.pdop != null) _pdop = _parser.pdop;
      if (nmeaPos == null) continue;

      // 위성수/Fix상태는 항상 업데이트 (fixQuality=0이어도)
      _satellites = nmeaPos.satellites;
      _fixQuality = nmeaPos.fixQuality;
      changed = true;

      // 좌표가 파싱되면 업데이트 (fixQuality=0이어도 좌표 자체는 유효할 수 있음)
      if (nmeaPos.latitude != 0.0 && nmeaPos.longitude != 0.0) {
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
          hdop: nmeaPos.hdop,
          diffAge: nmeaPos.diffAge,
        );
      }
    }
    if (changed) notifyListeners();
  }

  /// RTCM 보정 데이터를 수신기로 전송 (NTRIP → BT → i80)
  void sendRtcm(Uint8List data) {
    if (_connection == null || _connectionState != GnssConnectionState.connected) return;
    try {
      _connection!.output.add(data);
    } catch (e) {
      debugPrint('[GNSS] RTCM 전송 실패: $e');
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
