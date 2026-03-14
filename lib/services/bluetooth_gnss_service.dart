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

  /// 외부 파일 로거 (NtripService의 _log와 공유)
  void Function(String msg)? fileLogger;

  // 위치 유무와 관계없이 항상 업데이트되는 상태값
  int _satellites = 0;
  int _fixQuality = 0;
  double? _pdop;

  // 마지막 GGA 문장 (NTRIP VRS용)
  String? _lastGga;
  int _ggaCount = 0;

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
      fileLogger?.call('[BT] 연결됨: $_deviceName (${device.address})');

      // i80 초기화: RTCM 입력 포트를 BT로 설정
      await _sendInitCommands();

      _connection!.input!.listen(
        (Uint8List data) {
          _buffer += utf8.decode(data, allowMalformed: true);
          _processBuffer();
        },
        onDone: () {
          debugPrint('[GNSS] 연결 종료');
          fileLogger?.call('[BT] 연결 종료');
          _connectionState = GnssConnectionState.disconnected;
          _position = null;
          notifyListeners();
        },
        onError: (error) {
          debugPrint('[GNSS] 수신 오류: $error');
          fileLogger?.call('[BT] 수신 오류: $error');
          _connectionState = GnssConnectionState.error;
          notifyListeners();
        },
      );
    } catch (e) {
      debugPrint('[GNSS] 연결 실패: $e');
      fileLogger?.call('[BT] 연결 실패: $e');
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

      if (!sentence.startsWith('\$')) {
        // $ 로 시작하지 않는 응답도 로그 (CONFIG OK, ERROR 등)
        if (sentence.isNotEmpty) {
          debugPrint('[GNSS] 응답: $sentence');
          fileLogger?.call('[BT] 응답: $sentence');
        }
        continue;
      }

      // $PCHC 응답 로그 (OK, ERROR 등)
      if (sentence.contains('PCHC')) {
        debugPrint('[GNSS] PCHC응답: $sentence');
        fileLogger?.call('[BT] PCHC응답: $sentence');
      }

      // GGA 캡처 (NTRIP VRS용 + 디버그)
      if (sentence.contains('GGA')) {
        _lastGga = sentence;
        _ggaCount++;
        debugPrint('[NMEA] $sentence');
        // GGA에서 Fix/위성/diffAge 추출하여 파일 로그 (5초마다)
        if (_ggaCount <= 5 || _ggaCount % 5 == 0) {
          final parts = sentence.split(',');
          final fix = parts.length > 6 ? parts[6] : '?';
          final sats = parts.length > 7 ? parts[7] : '?';
          final hdop = parts.length > 8 ? parts[8] : '?';
          final diffAge = parts.length > 13 ? parts[13] : '';
          final diffAgeClean = diffAge.contains('*') ? diffAge.split('*')[0] : diffAge;
          fileLogger?.call('[NMEA] GGA#$_ggaCount Fix:$fix 위성:$sats HDOP:$hdop diffAge:${diffAgeClean.isEmpty ? "null" : diffAgeClean} RTCM전송:$_rtcmSendCount');
        }
      }

      final nmeaPos = _parser.parse(sentence);
      // GSA 등은 null 반환하지만 PDOP를 업데이트할 수 있음
      if (_parser.pdop != null) _pdop = _parser.pdop;
      if (nmeaPos == null) continue;

      // 위성수/Fix상태는 항상 업데이트 (fixQuality=0이어도)
      final prevFix = _fixQuality;
      _satellites = nmeaPos.satellites;
      _fixQuality = nmeaPos.fixQuality;
      changed = true;

      // Fix 변화 시 파일 로그
      if (prevFix != _fixQuality) {
        fileLogger?.call('[BT] Fix변화: $prevFix→$_fixQuality 위성:$_satellites HDOP:${nmeaPos.hdop} diffAge:${nmeaPos.diffAge}');
      }

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

  /// NMEA 체크섬 계산 ($ 와 * 사이 XOR)
  String _nmeaChecksum(String sentence) {
    // '$' 제거, '*' 이전까지
    final body = sentence.startsWith('\$') ? sentence.substring(1) : sentence;
    int cs = 0;
    for (int i = 0; i < body.length; i++) {
      cs ^= body.codeUnitAt(i);
    }
    return cs.toRadixString(16).toUpperCase().padLeft(2, '0');
  }

  /// BT 연결 직후 초기화
  Future<void> _sendInitCommands() async {
    if (_connection == null) return;

    fileLogger?.call('[BT] === i70 초기화 시작 ===');

    // 1) 먼저 불필요한 출력 모두 중단 (Unicore)
    await _sendRawCommand('UNLOGALL');
    // 2) GGA만 1초 간격 출력
    await _sendRawCommand('LOG GPGGA ONTIME 1');
    await _sendRawCommand('LOG GPGSA ONTIME 5');
    // 3) 로버 모드 + RTCM 입력 설정
    await _sendRawCommand('MODE ROVER');
    await _sendRawCommand('CONFIG RTK ON');
    // 4) $PCHC 명령
    await _sendPchcCommand('PCHC,MODE,ROVER');
    await _sendPchcCommand('PCHC,SET,PORT,BT,RTCM3,115200');
    await _sendPchcCommand('PCHC,SET,CORRPORT,BT');
    await _sendPchcCommand('PCHC,SET,NMEAPORT,BT,GGA,1');
    // 5) 설정 저장
    await _sendRawCommand('SAVECONFIG');

    try {
      await _connection!.output.allSent;
      fileLogger?.call('[BT] === i70 초기화 완료 ===');
    } catch (e) {
      fileLogger?.call('[BT] 초기화 flush 실패: $e');
    }
  }

  /// i70 수신기 내부 NTRIP 클라이언트 설정 (i70에 자체 인터넷이 있는 경우)
  Future<void> configureReceiverNtrip({
    required String host,
    required int port,
    required String mountPoint,
    required String username,
    required String password,
  }) async {
    if (_connection == null || _connectionState != GnssConnectionState.connected) {
      fileLogger?.call('[BT] NTRIP 설정 불가 - BT 미연결');
      return;
    }

    fileLogger?.call('[BT] === i70 내부 NTRIP 설정 ===');
    fileLogger?.call('[BT] 서버: $host:$port/$mountPoint');

    // 기존 세션 정리
    await _sendPchcCommand('PCHC,NTRIP,STOP');
    await _sendRawCommand('CONFIG NTRIP STOP');

    // $PCHC 형식
    await _sendPchcCommand('PCHC,NTRIP,SERVER,$host,$port');
    await _sendPchcCommand('PCHC,NTRIP,MOUNT,$mountPoint');
    await _sendPchcCommand('PCHC,NTRIP,USER,$username');
    await _sendPchcCommand('PCHC,NTRIP,PASS,$password');
    await _sendPchcCommand('PCHC,NTRIP,START');

    // Unicore CONFIG 형식
    await _sendRawCommand('CONFIG NTRIP SERVER $host');
    await _sendRawCommand('CONFIG NTRIP PORT $port');
    await _sendRawCommand('CONFIG NTRIP MOUNTPOINT $mountPoint');
    await _sendRawCommand('CONFIG NTRIP USER $username');
    await _sendRawCommand('CONFIG NTRIP PASSWORD $password');
    await _sendRawCommand('CONFIG NTRIP START');

    try {
      await _connection!.output.allSent;
      fileLogger?.call('[BT] === i70 NTRIP 설정 전송 완료 ===');
    } catch (e) {
      fileLogger?.call('[BT] NTRIP 설정 flush 실패: $e');
    }
  }

  /// $PCHC 명령 전송 (체크섬 자동 계산)
  Future<void> _sendPchcCommand(String body) async {
    if (_connection == null) return;
    try {
      final cs = _nmeaChecksum(body);
      final sentence = '\$$body*$cs\r\n';
      final data = Uint8List.fromList(utf8.encode(sentence));
      _connection!.output.add(data);
      debugPrint('[GNSS] CMD: $sentence'.trim());
      fileLogger?.call('[BT] CMD: \$$body*$cs');
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      fileLogger?.call('[BT] CMD 실패: $body → $e');
    }
  }

  /// 원시 명령 전송 (CR+LF 종단)
  Future<void> _sendRawCommand(String cmd) async {
    if (_connection == null) return;
    try {
      final data = Uint8List.fromList(utf8.encode('$cmd\r\n'));
      _connection!.output.add(data);
      debugPrint('[GNSS] RAW: $cmd');
      fileLogger?.call('[BT] RAW: $cmd');
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      fileLogger?.call('[BT] RAW 실패: $cmd → $e');
    }
  }

  int _rtcmBytesSent = 0;
  int _rtcmSendCount = 0;
  int _rtcmFlushErrors = 0;
  int _rtcmFlushOk = 0;

  // RTCM 버퍼링 (작은 패킷을 모아서 한번에 전송)
  final List<int> _rtcmBuffer = [];
  Timer? _rtcmFlushTimer;
  static const int _rtcmBufferThreshold = 256; // 256B 이상 모이면 전송 (BT 모듈 호환성)

  /// RTCM 전송 통계
  int get rtcmBytesSent => _rtcmBytesSent;
  int get rtcmSendCount => _rtcmSendCount;
  int get rtcmFlushErrors => _rtcmFlushErrors;

  /// RTCM 보정 데이터를 버퍼에 추가 (NTRIP → 버퍼 → BT → i80)
  void sendRtcm(Uint8List data) {
    if (_connection == null || _connectionState != GnssConnectionState.connected) {
      debugPrint('[GNSS] RTCM 전송 불가 - BT 미연결 (${_connectionState.name})');
      fileLogger?.call('[BT] RTCM 전송 불가 - BT 미연결 (${_connectionState.name})');
      return;
    }

    _rtcmBuffer.addAll(data);

    // 버퍼가 threshold 이상이면 즉시 전송
    if (_rtcmBuffer.length >= _rtcmBufferThreshold) {
      _flushRtcmBuffer();
    } else {
      // 아직 작으면 100ms 타이머로 지연 전송 (데이터가 더 올 수 있으므로)
      _rtcmFlushTimer?.cancel();
      _rtcmFlushTimer = Timer(const Duration(milliseconds: 100), _flushRtcmBuffer);
    }
  }

  /// 버퍼에 모인 RTCM을 한번에 BT 전송
  void _flushRtcmBuffer() {
    _rtcmFlushTimer?.cancel();
    if (_rtcmBuffer.isEmpty) return;
    if (_connection == null || _connectionState != GnssConnectionState.connected) return;

    final sendData = Uint8List.fromList(_rtcmBuffer);
    _rtcmBuffer.clear();

    try {
      // RTCM3 프레임 검증 및 상세 로그
      final msgTypes = <int>[];
      int offset = 0;
      bool validFrame = false;
      while (offset < sendData.length - 4) {
        if (sendData[offset] == 0xD3) {
          validFrame = true;
          final len = ((sendData[offset + 1] & 0x03) << 8) | sendData[offset + 2];
          if (offset + 3 + len + 3 <= sendData.length) {
            final msgType = ((sendData[offset + 3] & 0xFF) << 4) | ((sendData[offset + 4] & 0xF0) >> 4);
            msgTypes.add(msgType);
            offset += 3 + len + 3;
            continue;
          }
        }
        offset++;
      }

      _connection!.output.add(sendData);
      _connection!.output.allSent.then((_) {
        _rtcmFlushOk++;
      }).catchError((e) {
        _rtcmFlushErrors++;
        fileLogger?.call('[BT] ⚠️ RTCM flush 실패 (#$_rtcmFlushErrors): $e');
      });
      _rtcmBytesSent += sendData.length;
      _rtcmSendCount++;

      // 로그 (처음 10개 + 이후 10개마다)
      if (_rtcmSendCount <= 10 || _rtcmSendCount % 10 == 0) {
        final hex = sendData.take(12).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
        final errInfo = _rtcmFlushErrors > 0 ? ' flush오류:$_rtcmFlushErrors' : '';
        final flushInfo = ' flush성공:$_rtcmFlushOk';
        final frameInfo = validFrame ? 'RTCM3✓' : '⚠️비RTCM';
        final typeInfo = msgTypes.isNotEmpty ? ' [${msgTypes.join(",")}]' : '';
        final msg = '[BT] #$_rtcmSendCount $frameInfo ${sendData.length}B(버퍼)$typeInfo '
            'hex:[$hex] 누적:${(_rtcmBytesSent / 1024).toStringAsFixed(1)}KB$flushInfo$errInfo';
        debugPrint('[GNSS] $msg');
        fileLogger?.call(msg);
      }
    } catch (e) {
      debugPrint('[GNSS] RTCM 전송 실패: $e');
      fileLogger?.call('[BT] ❌ RTCM 전송 예외: $e');
    }
  }

  /// 연결 해제
  Future<void> disconnect() async {
    _rtcmFlushTimer?.cancel();
    _rtcmBuffer.clear();
    final conn = _connection;
    _connection = null;
    _connectionState = GnssConnectionState.disconnected;
    _position = null;
    _buffer = '';
    notifyListeners();

    if (conn != null) {
      try {
        await conn.finish();
      } catch (_) {
        try { await conn.close(); } catch (_) {}
      }
    }
  }

  @override
  void dispose() {
    // 동기적으로 소켓 닫기 시도 (dispose는 await 불가)
    try { _connection?.close(); } catch (_) {}
    _connection = null;
    super.dispose();
  }
}
