import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'nmea_parser.dart';
import 'coordinate_service.dart';
import 'chcnav_init_data.dart';

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
/// CHCNav i70 전용 바이너리 프로토콜 지원
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

  // CHCNav 바이너리 프로토콜 시퀀스 번호
  int _chcSeq = 0;

  // RTCM 전송 모드: true=RAW, false=CHCNav 래퍼

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
  /// [skipInit] true이면 초기화 명령 없이 연결만 (테라에스 설정 유지 테스트용)
  Future<void> connect(BluetoothDevice device, {bool skipInit = false}) async {
    _connectionState = GnssConnectionState.connecting;
    _deviceName = device.name ?? device.address;
    _chcSeq = 0;
    notifyListeners();

    try {
      _connection = await BluetoothConnection.toAddress(device.address);
      _connectionState = GnssConnectionState.connected;
      notifyListeners();

      debugPrint('[GNSS] 연결됨: $_deviceName (skipInit=$skipInit)');
      fileLogger?.call('[BT] 연결됨: $_deviceName (${device.address}) skipInit=$skipInit');

      // 초기화 명령 전송 (skipInit=false일 때만)
      if (!skipInit) {
        await _sendInitCommands();
      } else {
        fileLogger?.call('[BT] === 초기화 생략 (테라에스 설정 유지) ===');
      }

      // 수신 패킷 카운터 (hex dump 로그용)
      int rxCount = 0;

      _connection!.input!.listen(
        (Uint8List data) {
          rxCount++;
          // 처음 50개 수신 패킷은 전체 hex dump (테라에스 캡처와 비교용)
          if (rxCount <= 50) {
            final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
            fileLogger?.call('[BT-HEX] RX#$rxCount ${data.length}B: $hex');
          }
          // i70에서 데이터 수신 → 초기화 명령 응답 대기 해제
          _onBinaryResponse();
          // 디버그 모드일 때 바이너리 메시지 감지
          if (_isDebugQuerying) {
            _detectBinaryResponses(data);
          }
          // 바이너리/텍스트 분리 수신: $$ 바이너리 프레임 제거 후 NMEA만 버퍼에 추가
          _processRawData(data);
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

  // 바이너리 프레임 조립용 버퍼
  final List<int> _binBuffer = [];

  /// raw bytes에서 $$(0x24 0x24) 바이너리 프레임 분리 → 나머지 NMEA만 텍스트 버퍼에 추가
  void _processRawData(Uint8List data) {
    // 이전 잔여 바이너리 버퍼에 새 데이터 추가
    _binBuffer.addAll(data);

    int textStart = 0;
    int i = 0;

    while (i < _binBuffer.length - 1) {
      // $$ 바이너리 프레임 시작 감지
      if (_binBuffer[i] == 0x24 && _binBuffer[i + 1] == 0x24) {
        // $$ 앞의 텍스트(NMEA)를 버퍼에 추가
        if (i > textStart) {
          final textBytes = _binBuffer.sublist(textStart, i);
          _buffer += utf8.decode(Uint8List.fromList(textBytes), allowMalformed: true);
        }

        // 바이너리 프레임 끝(09 24 0D 0A) 찾기
        int endIdx = -1;
        for (int j = i + 4; j < _binBuffer.length - 3; j++) {
          if (_binBuffer[j] == 0x09 && _binBuffer[j + 1] == 0x24 &&
              _binBuffer[j + 2] == 0x0D && _binBuffer[j + 3] == 0x0A) {
            endIdx = j + 4;
            break;
          }
        }

        if (endIdx == -1) {
          // 프레임이 아직 완성되지 않음 → 남은 데이터 보관
          _binBuffer.removeRange(0, i);
          _processBuffer();
          return;
        }

        // 바이너리 프레임 로그
        final frameLen = endIdx - i;
        final hex = _binBuffer.sublist(i, min(i + 20, endIdx))
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ');
        fileLogger?.call('[BT] BIN-RX ${frameLen}B: [$hex...]');

        i = endIdx;
        textStart = endIdx;
      } else {
        i++;
      }
    }

    // 남은 텍스트 데이터를 NMEA 버퍼에 추가
    if (textStart < _binBuffer.length) {
      final remaining = _binBuffer.sublist(textStart);
      _binBuffer.clear();
      // 마지막 바이트가 $일 수 있으므로 보관
      if (remaining.isNotEmpty && remaining.last == 0x24) {
        _binBuffer.addAll(remaining);
      } else {
        _buffer += utf8.decode(Uint8List.fromList(remaining), allowMalformed: true);
      }
    } else {
      _binBuffer.clear();
    }

    _processBuffer();
  }

  /// NMEA 버퍼 처리
  void _processBuffer() {
    bool changed = false;
    while (_buffer.contains('\n')) {
      final idx = _buffer.indexOf('\n');
      final sentence = _buffer.substring(0, idx).trim();
      _buffer = _buffer.substring(idx + 1);

      if (!sentence.startsWith('\$')) {
        if (sentence.isNotEmpty) {
          final clean = _cleanResponse(sentence);
          if (clean.isNotEmpty) {
            debugPrint('[GNSS] 응답: $clean');
            fileLogger?.call('[BT] 응답: $clean');
            if (_isDebugQuerying) debugResponses.add('<< $clean');
          }
        }
        continue;
      }

      // $$ = CHCNav 바이너리 → 텍스트 처리 스킵
      if (sentence.startsWith('\$\$')) continue;

      // $PCHC 응답
      if (sentence.contains('PCHC')) {
        debugPrint('[GNSS] PCHC응답: $sentence');
        fileLogger?.call('[BT] PCHC응답: $sentence');
        if (_isDebugQuerying) debugResponses.add('<< $sentence');
      }

      // 디버그 모드: NMEA 외 텍스트 응답 캡처
      if (_isDebugQuerying &&
          !sentence.contains('GGA') && !sentence.contains('GSA') &&
          !sentence.contains('RMC') && !sentence.contains('GSV') &&
          !sentence.contains('PCHC')) {
        final clean = _cleanResponse(sentence);
        if (clean.length > 2) {
          debugResponses.add('<< $clean');
          fileLogger?.call('[BT] 응답: $clean');
        }
      }

      // GGA 캡처 (NTRIP VRS용)
      if (sentence.contains('GGA')) {
        _lastGga = sentence;
        _ggaCount++;
        debugPrint('[NMEA] $sentence');
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
      if (_parser.pdop != null) _pdop = _parser.pdop;
      if (nmeaPos == null) continue;

      final prevFix = _fixQuality;
      _satellites = nmeaPos.satellites;
      _fixQuality = nmeaPos.fixQuality;
      changed = true;

      if (prevFix != _fixQuality) {
        fileLogger?.call('[BT] Fix변화: $prevFix→$_fixQuality 위성:$_satellites HDOP:${nmeaPos.hdop} diffAge:${nmeaPos.diffAge}');
      }

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

  /// 응답에서 비ASCII/깨진 문자 제거
  String _cleanResponse(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^\x20-\x7E가-힣ㄱ-ㅎㅏ-ㅣ]'), '').trim();
    return cleaned;
  }

  /// 바이너리 메시지 감지 (디버그용)
  void _detectBinaryResponses(Uint8List data) {
    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 0x24 && data[i + 1] == 0x24) {
        if (i + 6 < data.length) {
          final msgLen = data[i + 2] | (data[i + 3] << 8);
          final msgId = data[i + 4] | (data[i + 5] << 8);
          final hex = data.skip(i).take(min(20, data.length - i))
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(' ');
          debugResponses.add('<BIN> msgId:$msgId len:$msgLen hex:[$hex...]');
          fileLogger?.call('[BT] BIN msgId:$msgId len:$msgLen');
        }
        break;
      }
    }
  }

  // ── CHCNav 바이너리 프로토콜 ──

  /// CHCNav 바이너리 명령 프레임 생성
  /// 형식: $$ 01 [seq] [len] 04 11 [00x8] 01 [payloadLen:2] [payload] 09 24 0D 0A
  Uint8List _buildChcCommand(List<int> payload) {
    final payloadLen = payload.length;
    final seq = _chcSeq++ & 0xFF;

    final frame = <int>[
      0x24, 0x24,           // magic $$
      0x01,                 // direction: request (tablet → i70)
      seq,                  // sequence number
      ((payloadLen + 19) < 0xFA ? (payloadLen + 19) : 0xFA), // length field: min(payloadLen+19, 0xFA)
      0x04, 0x11,           // protocol ID
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 8 zero bytes
      0x01,                 // constant
      (payloadLen >> 8) & 0xFF, payloadLen & 0xFF, // payload length (BE)
      ...payload,
      0x09, 0x24, 0x0D, 0x0A, // terminator
    ];

    return Uint8List.fromList(frame);
  }

  /// CHCNav 설정 명령 생성 (파라미터 ID + 값 설정)
  Uint8List _buildChcSetCommand(int paramHi, int paramLo, int valueHi, int valueLo) {
    final payload = [
      0x00, 0x01, 0x00, 0x02, // constants
      0x00, 0x0A,             // sub-command: set parameter
      paramHi, paramLo,       // parameter ID
      0x00, 0x02,             // value length
      valueHi, valueLo,       // value
      0x00, 0x00,             // padding
    ];
    return _buildChcCommand(payload);
  }

  /// CHCNav 바이너리 프레임 직접 전송
  Future<void> _sendChcBinary(Uint8List frame, String desc) async {
    if (_connection == null) return;
    try {
      _connection!.output.add(frame);
      final hex = frame.take(min(24, frame.length))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      debugPrint('[GNSS] CHC: $desc [$hex...]');
      fileLogger?.call('[BT] CHC: $desc (${frame.length}B)');
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      fileLogger?.call('[BT] CHC 실패: $desc → $e');
    }
  }

  /// CHCNav RTCM 래퍼: RTCM3 데이터를 HCNP 비즈니스 패킷으로 감싸기
  /// TerrAs BT Snoop 캡처 기반 (2026-03-17, 1164프레임 분석)
  ///
  /// 전송 프레임: [24 24 01] [seq] [chunkLen] [비즈니스패킷] [0D 0A]
  /// 비즈니스 패킷: [04 11] [00] [cmdID:4B=0] [seq:4B=1] [blocksLen:2B] [blocks] [09 24]
  /// Block 1: [00 01] [00 02] [00 32]  — 제어블록 (ID=0x0001, data=0x0032)
  /// Block 2: [15 04] [len:2B] [RTCM]  — RTCM 페이로드
  Uint8List _wrapRtcmInChcFrame(Uint8List rtcmData) {
    final rtcmLen = rtcmData.length;
    // Block1: ID(2) + len(2) + data(2) = 6B
    // Block2: ID(2) + len(2) + rtcmData = 4 + rtcmLen
    final blocksLen = 10 + rtcmLen;

    // 비즈니스 패킷 조립
    final businessPacket = <int>[
      0x04, 0x11,                                          // 매직
      0x00,                                                // 예약
      0x00, 0x00, 0x00, 0x00,                              // cmdID=0 (고정, TerrAs 확인)
      0x00, 0x00, 0x00, 0x01,                              // seq=1 (고정, TerrAs 확인)
      (blocksLen >> 8) & 0xFF, blocksLen & 0xFF,           // blocksLen (BE)
      // Block 1: 제어 블록 (TerrAs BT Snoop: ID=0x0001, data=00 32)
      0x00, 0x01,                                          // block ID (BE)
      0x00, 0x02,                                          // block data len=2 (BE)
      0x00, 0x32,                                          // block data
      // Block 2: RTCM 페이로드
      0x15, 0x04,                                          // block ID (BE)
      (rtcmLen >> 8) & 0xFF, rtcmLen & 0xFF,               // block data len (BE)
      ...rtcmData,                                         // RTCM 바이너리
      // 테일
      0x09, 0x24,                                          // 테일 매직
    ];

    // 전송 프레임 래핑
    final seq = _chcSeq;
    _chcSeq = (_chcSeq + 1) % 0xFB; // 0~250 순환 (TerrAs 패턴)
    final chunkLen = min(businessPacket.length, 0xFA);

    return Uint8List.fromList([
      0x24, 0x24, 0x01, seq, chunkLen,
      ...businessPacket,
      0x0D, 0x0A,
    ]);
  }

  // 응답 대기용 Completer
  Completer<void>? _responseCompleter;

  /// i70로부터 바이너리 응답 수신 시 호출 (응답 대기 해제)
  void _onBinaryResponse() {
    if (_responseCompleter != null && !_responseCompleter!.isCompleted) {
      _responseCompleter!.complete();
    }
  }

  /// 바이너리 명령 전송 후 응답 대기 (타임아웃 포함)
  Future<void> _sendAndWaitResponse(Uint8List cmd, int index, {int timeoutMs = 500}) async {
    if (_connection == null) return;

    _responseCompleter = Completer<void>();

    try {
      // 초기화 명령 전체 hex dump
      final hex = cmd.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      fileLogger?.call('[BT-HEX] INIT#$index SENT ${cmd.length}B: $hex');

      _connection!.output.add(cmd);
      // 응답 대기 (타임아웃)
      await _responseCompleter!.future.timeout(
        Duration(milliseconds: timeoutMs),
        onTimeout: () {
          // 타임아웃 — 무시하고 진행
        },
      );
    } catch (e) {
      fileLogger?.call('[BT] 초기화 #$index 전송 실패: $e');
    }
    _responseCompleter = null;
  }

  /// BT 연결 직후 초기화 — 테라에스 캡처 시퀀스 재생 (응답 대기 포함)
  Future<void> _sendInitCommands() async {
    if (_connection == null) return;

    fileLogger?.call('[BT] === i70 테라에스 초기화 시작 (${chcnavInitCommands.length}개, 응답대기) ===');

    for (int i = 0; i < chcnavInitCommands.length; i++) {
      if (_connection == null || _connectionState != GnssConnectionState.connected) break;
      final cmd = Uint8List.fromList(chcnavInitCommands[i]);
      final seq = cmd.length > 3 ? cmd[3] : i;

      await _sendAndWaitResponse(cmd, i + 1);

      if (i < 5 || i % 10 == 0 || i >= chcnavInitCommands.length - 3) {
        fileLogger?.call('[BT] 초기화 #${i + 1}/${chcnavInitCommands.length} seq=0x${seq.toRadixString(16)} (${cmd.length}B) 완료');
      }
    }

    // 초기화 명령의 마지막 시퀀스 번호를 추출하여 _chcSeq 동기화
    // chcnavInitCommands는 하드코딩된 바이트이므로 _chcSeq가 증가하지 않음
    // 마지막 명령의 Byte[3]이 시퀀스 번호
    if (chcnavInitCommands.isNotEmpty) {
      final lastCmd = chcnavInitCommands.last;
      if (lastCmd.length > 3) {
        _chcSeq = (lastCmd[3] + 1) & 0xFF;
        fileLogger?.call('[BT] 시퀀스 동기화: 마지막 init seq=${lastCmd[3]} → 다음 _chcSeq=$_chcSeq');
      }
    }

    try {
      await _connection!.output.allSent;
      fileLogger?.call('[BT] === i70 초기화 완료 (HCNP RTCM, nextSeq=$_chcSeq) ===');
    } catch (e) {
      fileLogger?.call('[BT] 초기화 flush 실패: $e');
    }
  }

  /// i70 수신기 내부 NTRIP 클라이언트 설정
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

    await _sendPchcCommand('PCHC,NTRIP,STOP');
    await _sendPchcCommand('PCHC,NTRIP,SERVER,$host,$port');
    await _sendPchcCommand('PCHC,NTRIP,MOUNT,$mountPoint');
    await _sendPchcCommand('PCHC,NTRIP,USER,$username');
    await _sendPchcCommand('PCHC,NTRIP,PASS,$password');
    await _sendPchcCommand('PCHC,NTRIP,START');

    try {
      await _connection!.output.allSent;
      fileLogger?.call('[BT] === i70 NTRIP 설정 전송 완료 ===');
    } catch (e) {
      fileLogger?.call('[BT] NTRIP 설정 flush 실패: $e');
    }
  }

  /// NMEA 체크섬 계산
  String _nmeaChecksum(String sentence) {
    final body = sentence.startsWith('\$') ? sentence.substring(1) : sentence;
    int cs = 0;
    for (int i = 0; i < body.length; i++) {
      cs ^= body.codeUnitAt(i);
    }
    return cs.toRadixString(16).toUpperCase().padLeft(2, '0');
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

  // ── RTCM 전송 (CHCNav 바이너리 래퍼) ──

  int _rtcmBytesSent = 0;
  int _rtcmSendCount = 0;
  int _rtcmFlushErrors = 0;

  final List<int> _rtcmBuffer = [];
  Timer? _rtcmFlushTimer;

  int get rtcmBytesSent => _rtcmBytesSent;
  int get rtcmSendCount => _rtcmSendCount;
  int get rtcmFlushErrors => _rtcmFlushErrors;

  /// RTCM 보정 데이터 수신 → RTCM3 프레임 파싱 → 개별 CHCNav 래핑 전송
  /// 테라에스처럼 RTCM3 프레임 단위로 개별 래핑하여 전송 (배치 X)
  void sendRtcm(Uint8List data) {
    if (_connection == null || _connectionState != GnssConnectionState.connected) {
      debugPrint('[GNSS] RTCM 전송 불가 - BT 미연결 (${_connectionState.name})');
      fileLogger?.call('[BT] RTCM 전송 불가 - BT 미연결 (${_connectionState.name})');
      return;
    }

    _rtcmBuffer.addAll(data);
    _parseAndSendRtcmFrames();
  }

  /// RTCM3 프레임(D3 헤더) 파싱 → 개별 CHCNav 래핑 전송
  void _parseAndSendRtcmFrames() {
    _rtcmFlushTimer?.cancel();

    int offset = 0;
    while (offset < _rtcmBuffer.length) {
      // D3 헤더 찾기
      if (_rtcmBuffer[offset] != 0xD3) {
        offset++;
        continue;
      }

      // 최소 6바이트 필요 (D3 + len(2) + msgType(2) + ... + CRC(3))
      if (offset + 6 > _rtcmBuffer.length) break;

      final rtcmLen = ((_rtcmBuffer[offset + 1] & 0x03) << 8) | _rtcmBuffer[offset + 2];
      final frameSize = 3 + rtcmLen + 3; // header(3) + data(rtcmLen) + CRC(3)

      // 프레임이 아직 완성되지 않았으면 대기
      if (offset + frameSize > _rtcmBuffer.length) break;

      // 메시지 타입 추출
      final msgType = ((_rtcmBuffer[offset + 3] & 0xFF) << 4) |
                       ((_rtcmBuffer[offset + 4] & 0xF0) >> 4);

      // 개별 RTCM3 프레임 추출
      final rtcmFrame = Uint8List.fromList(
        _rtcmBuffer.sublist(offset, offset + frameSize),
      );

      try {
        final sentData = _wrapRtcmInChcFrame(rtcmFrame);
        _connection!.output.add(sentData);

        _rtcmBytesSent += rtcmFrame.length;
        _rtcmSendCount++;

        // 처음 20개는 전체 hex dump (테라에스 캡처와 비교용)
        if (_rtcmSendCount <= 20) {
          final fullHex = sentData.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
          fileLogger?.call('[BT-HEX] RTCM#$_rtcmSendCount type:$msgType SENT ${sentData.length}B: $fullHex');
        } else if (_rtcmSendCount % 10 == 0) {
          final errInfo = _rtcmFlushErrors > 0 ? ' err:$_rtcmFlushErrors' : '';
          fileLogger?.call('[BT] RTCM#$_rtcmSendCount type:$msgType ${rtcmFrame.length}B 누적:${(_rtcmBytesSent / 1024).toStringAsFixed(1)}KB$errInfo');
        }
      } catch (e) {
        _rtcmFlushErrors++;
        fileLogger?.call('[BT] RTCM 전송 실패 type:$msgType: $e');
      }

      offset += frameSize;
    }

    // 처리된 데이터 제거, 잔여 데이터 보관
    if (offset > 0) {
      _rtcmBuffer.removeRange(0, offset);
    }

    // 잔여 데이터가 있으면 다음 수신 시 합쳐서 처리 (타임아웃으로 폐기 방지)
    if (_rtcmBuffer.isNotEmpty) {
      _rtcmFlushTimer = Timer(const Duration(seconds: 2), () {
        if (_rtcmBuffer.isNotEmpty) {
          fileLogger?.call('[BT] RTCM 잔여 버퍼 폐기: ${_rtcmBuffer.length}B');
          _rtcmBuffer.clear();
        }
      });
    }
  }

  // ── 디버그 도구 ──

  final List<String> debugResponses = [];
  bool _isDebugQuerying = false;

  Future<void> sendDebugCommand(String cmd) async {
    if (_connection == null || _connectionState != GnssConnectionState.connected) return;

    _isDebugQuerying = true;

    if (cmd.startsWith('PCHC')) {
      final cs = _nmeaChecksum(cmd);
      final sentence = '\$$cmd*$cs\r\n';
      final data = Uint8List.fromList(utf8.encode(sentence));
      _connection!.output.add(data);
      debugResponses.add('>> \$$cmd*$cs');
      fileLogger?.call('[DBG] CMD: \$$cmd*$cs');
    } else {
      final data = Uint8List.fromList(utf8.encode('$cmd\r\n'));
      _connection!.output.add(data);
      debugResponses.add('>> $cmd');
      fileLogger?.call('[DBG] CMD: $cmd');
    }

    await Future.delayed(const Duration(milliseconds: 1500));
    try { await _connection!.output.allSent; } catch (_) {}
    _isDebugQuerying = false;
    notifyListeners();
  }

  Future<void> queryReceiverSettings() async {
    debugResponses.clear();
    debugResponses.add('=== i70 설정 조회 시작 ===');
    notifyListeners();

    final commands = [
      'LOG VERSION ONCE',
      'PCHC,GET,MODE',
      'PCHC,GET,CORRPORT',
      'PCHC,GET,DIFFPORT',
      'PCHC,GET,PORT,BT',
      'PCHC,GET,NMEAPORT',
      'PCHC,GET,RTCMPORT',
      'PCHC,GET,NTRIP',
      'PCHC,GET,DIFF',
      'PCHC,GET,RTCM',
      'LOG COMCONFIG ONCE',
      'LOG RTCMCONFIG ONCE',
      'LOG RTKCONFIG ONCE',
    ];

    for (final cmd in commands) {
      await sendDebugCommand(cmd);
    }

    debugResponses.add('=== 조회 완료 (${debugResponses.length}줄) ===');
    notifyListeners();
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
    try { _connection?.close(); } catch (_) {}
    _connection = null;
    super.dispose();
  }
}
