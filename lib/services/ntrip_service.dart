import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum NtripState {
  disconnected,
  connecting,
  connected,
  error,
}

/// NTRIP 서버 설정
class NtripConfig {
  final String host;
  final int port;
  final String mountPoint;
  final String username;
  final String password;

  const NtripConfig({
    required this.host,
    required this.port,
    required this.mountPoint,
    required this.username,
    required this.password,
  });

  static Future<NtripConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final host = prefs.getString('ntrip_host');
    if (host == null || host.isEmpty) return null;
    // 마이그레이션: VRS-RTCM31 → VRS-RTCM34 (i80 다중주파 수신기용)
    var mount = prefs.getString('ntrip_mount') ?? '';
    if (mount == 'VRS-RTCM31') {
      mount = 'VRS-RTCM34';
      await prefs.setString('ntrip_mount', mount);
    }
    return NtripConfig(
      host: host,
      port: prefs.getInt('ntrip_port') ?? 2101,
      mountPoint: mount,
      username: prefs.getString('ntrip_user') ?? '',
      password: prefs.getString('ntrip_pass') ?? '',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ntrip_host', host);
    await prefs.setInt('ntrip_port', port);
    await prefs.setString('ntrip_mount', mountPoint);
    await prefs.setString('ntrip_user', username);
    await prefs.setString('ntrip_pass', password);
  }
}

/// NTRIP 클라이언트 서비스
class NtripService extends ChangeNotifier {
  Socket? _socket;
  NtripState _state = NtripState.disconnected;
  NtripConfig? _config;
  String? _errorMessage;

  void Function(Uint8List rtcmData)? onRtcmData;

  String? _lastGga;
  Timer? _ggaSendTimer;

  int _bytesReceived = 0;
  DateTime? _lastDataTime;
  Timer? _reconnectTimer;
  bool _isChunked = false;
  final List<int> _chunkBuffer = [];
  bool _shouldAutoReconnect = false;

  // 디버그 로그 (앱 화면 표시용)
  final List<String> debugLog = [];
  static const int _maxLogLines = 30;

  // 파일 로그
  IOSink? _logSink;
  IOSink? _internalLogSink;  // 앱 내부 디렉토리 백업
  String? _logFilePath;
  String? _internalLogPath;
  int _logLineCount = 0;
  String? get logFilePath => _logFilePath;
  String? get internalLogPath => _internalLogPath;

  NtripState get state => _state;
  NtripConfig? get config => _config;
  String? get errorMessage => _errorMessage;
  int get bytesReceived => _bytesReceived;
  DateTime? get lastDataTime => _lastDataTime;
  bool get isConnected => _state == NtripState.connected;

  /// 파일 로그 초기화 (앱 시작 시 호출)
  /// Download 폴더 + 앱 내부 디렉토리 동시 저장
  Future<void> initFileLog() async {
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) {
        final dlDir = Directory('/storage/emulated/0/Download');
        if (await dlDir.exists()) {
          _logFilePath = '${dlDir.path}/ntrip_debug.log';
        }
      } else {
        final segments = dir.path.split('/');
        final emulatedIdx = segments.indexOf('Android');
        if (emulatedIdx > 0) {
          _logFilePath = '${segments.sublist(0, emulatedIdx).join('/')}/Download/ntrip_debug.log';
        } else {
          _logFilePath = '${dir.path}/ntrip_debug.log';
        }
      }

      // 앱 내부 디렉토리에도 저장 (adb pull 가능, 삭제 안됨)
      final appDir = await getExternalStorageDirectory();
      if (appDir != null) {
        final ts = DateTime.now();
        final dateStr = '${ts.year}${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}_${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}';
        _internalLogPath = '${appDir.path}/bt_log_$dateStr.log';
        final internalFile = File(_internalLogPath!);
        _internalLogSink = internalFile.openWrite(mode: FileMode.write);
        _internalLogSink!.writeln('========== 세션 시작 ${ts.toString()} ==========');
        debugPrint('[NTRIP] 내부 로그: $_internalLogPath');
      }

      if (_logFilePath != null) {
        final file = File(_logFilePath!);
        _logSink = file.openWrite(mode: FileMode.write);
        final ts = DateTime.now();
        _logSink!.writeln('\n========== 세션 시작 ${ts.toString()} ==========');
        await _logSink!.flush();
        debugPrint('[NTRIP] 로그파일: $_logFilePath');
      }
    } catch (e) {
      debugPrint('[NTRIP] 로그파일 초기화 실패: $e');
    }
  }

  void _log(String msg) {
    final ts = DateTime.now();
    final line = '[${ts.hour.toString().padLeft(2,'0')}:${ts.minute.toString().padLeft(2,'0')}:${ts.second.toString().padLeft(2,'0')}] $msg';
    debugPrint('[NTRIP] $msg');
    debugLog.add(line);
    if (debugLog.length > _maxLogLines) debugLog.removeAt(0);
    _writeLine(line);
  }

  /// 외부에서 파일 로그에 기록 (BT 서비스 등)
  void logExternal(String msg) {
    final ts = DateTime.now();
    final line = '[${ts.hour.toString().padLeft(2,'0')}:${ts.minute.toString().padLeft(2,'0')}:${ts.second.toString().padLeft(2,'0')}] $msg';
    _writeLine(line);
  }

  /// 양쪽 로그 파일에 기록 + 주기적 flush
  void _writeLine(String line) {
    _logSink?.writeln(line);
    _internalLogSink?.writeln(line);
    _logLineCount++;
    // 100줄마다 flush (hex dump가 많으므로)
    if (_logLineCount % 100 == 0) {
      _logSink?.flush();
      _internalLogSink?.flush();
    }
  }

  /// 로그 flush (공유 전 호출)
  Future<void> flushLog() async {
    await _logSink?.flush();
    await _internalLogSink?.flush();
  }

  Future<void> loadConfig() async {
    _config = await NtripConfig.load();
  }

  void updateGga(String ggaSentence) {
    _lastGga = ggaSentence;
  }

  /// 소스테이블 가져오기
  Future<List<String>> getSourceTable({NtripConfig? tempConfig}) async {
    final cfg = tempConfig ?? _config;
    if (cfg == null) return [];

    _log('소스테이블 요청: ${cfg.host}:${cfg.port}');

    // 여러 호스트 후보 시도
    final hosts = <String>{cfg.host, 'rts1.ngii.go.kr', 'gnss.ngii.go.kr'}.toList();

    for (final host in hosts) {
      try {
        final socket = await Socket.connect(host, cfg.port,
            timeout: const Duration(seconds: 8));
        _log('소스테이블 TCP 연결 성공: $host');

        final credentials = base64Encode(utf8.encode('${cfg.username}:${cfg.password}'));
        final request = 'GET / HTTP/1.1\r\n'
            'Host: $host\r\n'
            'Ntrip-Version: Ntrip/2.0\r\n'
            'User-Agent: NTRIP CHC_LandStar/1.0\r\n'
            'Authorization: Basic $credentials\r\n'
            '\r\n';
        socket.add(utf8.encode(request));

        final completer = Completer<List<String>>();
        final buffer = StringBuffer();
        final mountPoints = <String>[];

        socket.listen(
          (data) {
            buffer.write(utf8.decode(data, allowMalformed: true));
            // 데이터가 올 때마다 즉시 파싱 (서버가 연결 안 닫을 수 있음)
            final text = buffer.toString();
            mountPoints.clear();
            for (final line in text.split('\n')) {
              if (line.startsWith('STR;')) {
                final parts = line.split(';');
                if (parts.length > 1) mountPoints.add(parts[1].trim());
              }
            }
            // ENDSOURCETABLE 감지 시 즉시 완료
            if (text.contains('ENDSOURCETABLE')) {
              if (!completer.isCompleted) {
                _log('마운트포인트 ${mountPoints.length}개 발견: ${mountPoints.take(5).join(', ')}');
                notifyListeners();
                completer.complete(List.from(mountPoints));
              }
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              _log('마운트포인트 ${mountPoints.length}개 발견 (연결종료): ${mountPoints.take(5).join(', ')}');
              notifyListeners();
              completer.complete(List.from(mountPoints));
            }
          },
          onError: (e) {
            _log('소스테이블 오류: $e');
            notifyListeners();
            if (!completer.isCompleted) completer.complete([]);
          },
        );

        Future.delayed(const Duration(seconds: 8), () {
          if (!completer.isCompleted) {
            // 타임아웃이어도 이미 파싱된 결과 반환
            if (mountPoints.isNotEmpty) {
              _log('소스테이블 타임아웃 (${mountPoints.length}개 수집됨)');
            } else {
              _log('소스테이블 타임아웃 ($host)');
            }
            socket.destroy();
            notifyListeners();
            completer.complete(List.from(mountPoints));
          }
        });

        final result = await completer.future;
        try { socket.destroy(); } catch (_) {}
        if (result.isNotEmpty) return result;
        _log('$host에서 마운트포인트 없음, 다음 호스트 시도');
      } catch (e) {
        _log('소스테이블 연결 실패 ($host): $e');
      }
    }
    notifyListeners();
    return [];
  }

  /// NTRIP 서버 연결
  Future<void> connect(NtripConfig config) async {
    if (_state == NtripState.connecting || _state == NtripState.connected) {
      await disconnect();
    }

    _config = config;
    _shouldAutoReconnect = true;
    _reconnectTimer?.cancel();
    _state = NtripState.connecting;
    _errorMessage = null;
    _bytesReceived = 0;
    notifyListeners();

    // 연결 전에 설정 저장 (실패해도 다음에 불러옴)
    await config.save();

    _log('마운트포인트: ${config.mountPoint}');
    _log('계정: ${config.username} / ${config.password.replaceAll(RegExp(r'.'), '*')}');

    // 국토지리정보원 서버 주소 후보 (설정값 → rts1 → gnss 순서로 시도)
    final hosts = <String>{
      config.host,
      'rts1.ngii.go.kr',
      'gnss.ngii.go.kr',
    }.toList();

    try {
      Socket? socket;
      String? connectedHost;
      for (final host in hosts) {
        _log('연결 시도: $host:${config.port}');
        try {
          socket = await Socket.connect(host, config.port,
              timeout: const Duration(seconds: 8));
          connectedHost = host;
          _log('TCP 연결 성공: $host (로컬포트: ${socket.port})');
          break;
        } catch (e) {
          _log('$host 실패: $e');
        }
      }
      if (socket == null || connectedHost == null) {
        throw Exception('모든 서버 주소 연결 실패 (포트 ${config.port} 차단 가능성)');
      }
      _socket = socket;

      final credentials = base64Encode(utf8.encode('${config.username}:${config.password}'));
      final request = 'GET /${config.mountPoint} HTTP/1.1\r\n'
          'Host: $connectedHost\r\n'
          'Ntrip-Version: Ntrip/2.0\r\n'
          'User-Agent: NTRIP CHC_LandStar/1.0\r\n'
          'Authorization: Basic $credentials\r\n'
          'Accept: */*\r\n'
          '\r\n';

      _socket!.add(utf8.encode(request));
      _log('HTTP 요청 전송 완료');
      _log('요청: GET /${config.mountPoint} Auth=${credentials.substring(0, 8)}...');

      bool headerParsed = false;
      final headerBuffer = <int>[];

      _socket!.listen(
        (Uint8List data) {
          if (!headerParsed) {
            headerBuffer.addAll(data);
            final headerStr = utf8.decode(headerBuffer, allowMalformed: true);
            _log('서버 응답 수신 (${headerBuffer.length}바이트)');

            // 첫 줄 추출
            final firstLineEnd = headerStr.indexOf('\r\n');
            final firstLine = firstLineEnd >= 0
                ? headerStr.substring(0, firstLineEnd).trim()
                : headerStr.trim();
            _log('첫 응답줄: "$firstLine"');
            // 401 디버깅: 전체 응답 헤더 로그
            if (firstLine.contains('401') || firstLine.contains('403')) {
              _log('전체 응답: $headerStr');
            }

            // NTRIP 1.0 (ICY 200 OK) vs NTRIP 2.0 (HTTP/1.1 200 OK)
            final isNtrip1Ok = firstLine.contains('ICY 200');
            final headerEnd2 = headerStr.indexOf('\r\n\r\n');
            final headerEnd1 = isNtrip1Ok && firstLineEnd >= 0 ? firstLineEnd : -1;

            int bodyStart = -1;
            if (headerEnd2 >= 0) {
              bodyStart = headerEnd2 + 4;
              _log('NTRIP 2.0 헤더 종료 감지 (bodyStart=$bodyStart)');
            } else if (headerEnd1 >= 0) {
              bodyStart = headerEnd1 + 2;
              _log('NTRIP 1.0 헤더 종료 감지 (bodyStart=$bodyStart)');
            } else if (headerBuffer.length > 512) {
              bodyStart = 0;
              _log('헤더 타임아웃 강제 파싱');
            }

            if (bodyStart >= 0) {
              headerParsed = true;

              // Chunked transfer encoding 감지
              final lowerHeader = headerStr.toLowerCase();
              if (lowerHeader.contains('transfer-encoding') && lowerHeader.contains('chunked')) {
                _isChunked = true;
                _chunkBuffer.clear();
                _log('⚠️ Chunked Transfer-Encoding 감지 → 디코딩 활성화');
              }

              if (firstLine.contains('200')) {
                _log('✅ 연결 성공! RTCM 수신 시작 (chunked=$_isChunked)');
                _state = NtripState.connected;
                _errorMessage = null;
                notifyListeners();
                _startGgaSender();

                if (bodyStart < headerBuffer.length) {
                  final rtcmData = Uint8List.fromList(headerBuffer.sublist(bodyStart));
                  _log('초기 RTCM 데이터: ${rtcmData.length}바이트');
                  if (_isChunked) {
                    _handleChunkedData(rtcmData);
                  } else {
                    _handleRtcmData(rtcmData);
                  }
                }
              } else if (firstLine.contains('401')) {
                _log('❌ 인증 실패 (401) - ID/비번 확인 필요');
                _errorMessage = '인증 실패 (401) - ID/비번을 확인하세요';
                _state = NtripState.error;
                notifyListeners();
                _socket?.destroy();
              } else if (firstLine.contains('403')) {
                _log('❌ 접근 거부 (403) - 마운트포인트 권한 없음');
                _errorMessage = '접근 거부 (403) - 마운트포인트를 확인하세요';
                _state = NtripState.error;
                notifyListeners();
                _socket?.destroy();
              } else if (firstLine.contains('404')) {
                _log('❌ 마운트포인트 없음 (404): ${config.mountPoint}');
                _errorMessage = '마운트포인트 없음 (404): ${config.mountPoint}';
                _state = NtripState.error;
                notifyListeners();
                _socket?.destroy();
              } else {
                _log('❌ 서버 오류: $firstLine');
                _errorMessage = '서버 오류: $firstLine';
                _state = NtripState.error;
                notifyListeners();
                _socket?.destroy();
              }
            }
          } else {
            // 데이터 수신 로그 (처음 10회)
            if (_rtcmPacketCount < 10 || _rtcmPacketCount % 50 == 0) {
              _log('소켓 데이터 ${data.length}B (chunked=$_isChunked, total=${_bytesReceived}B, packets=$_rtcmPacketCount)');
            }
            if (_isChunked) {
              _handleChunkedData(data);
            } else {
              _handleRtcmData(data);
            }
          }
        },
        onDone: () {
          _log('연결 종료 (서버가 닫음)');
          _state = NtripState.disconnected;
          _stopGgaSender();
          notifyListeners();
          _scheduleReconnect();
        },
        onError: (error) {
          _log('소켓 오류: $error');
          _errorMessage = '소켓 오류: $error';
          _state = NtripState.error;
          _stopGgaSender();
          notifyListeners();
          _scheduleReconnect();
        },
      );
    } catch (e) {
      _log('연결 예외: $e');
      _errorMessage = '연결 실패: $e';
      _state = NtripState.error;
      notifyListeners();
    }
  }

  int _rtcmPacketCount = 0;
  final Map<int, int> _rtcmTypeCounts = {};
  DateTime? _rtcmStartTime;

  /// 수신된 RTCM 메시지 타입 집계
  Map<int, int> get rtcmTypeCounts => Map.unmodifiable(_rtcmTypeCounts);

  /// RTCM 메시지 타입 이름
  static String rtcmTypeName(int type) {
    switch (type) {
      case 1001: case 1002: case 1003: case 1004: return 'GPS L1/L2(구형)';
      case 1005: case 1006: return '기준국좌표';
      case 1007: case 1008: return '안테나정보';
      case 1009: case 1010: case 1011: case 1012: return 'GLO L1/L2(구형)';
      case 1019: return 'GPS 궤도';
      case 1020: return 'GLO 궤도';
      case 1033: return '안테나+수신기';
      case 1042: return 'BDS 궤도';
      case 1044: return 'QZSS 궤도';
      case 1045: case 1046: return 'GAL 궤도';
      case 1074: return 'GPS MSM4';
      case 1077: return 'GPS MSM7';
      case 1084: return 'GLO MSM4';
      case 1087: return 'GLO MSM7';
      case 1094: return 'GAL MSM4';
      case 1097: return 'GAL MSM7';
      case 1104: return 'SBAS MSM4';
      case 1107: return 'SBAS MSM7';
      case 1114: return 'QZSS MSM4';
      case 1117: return 'QZSS MSM7';
      case 1124: return 'BDS MSM4';
      case 1127: return 'BDS MSM7';
      case 1230: return 'GLO 코드바이어스';
      case 4094: return '사용자정의';
      default:
        if (type >= 1071 && type <= 1137) return 'MSM($type)';
        return '$type';
    }
  }

  /// MSM 메시지 수신 여부 확인 (RTK Fix에 필수)
  bool get hasReceivedMsm => _rtcmTypeCounts.keys.any((t) => t >= 1071 && t <= 1137);

  /// HTTP chunked transfer encoding 디코딩
  /// 형식: <chunk-size-hex>\r\n<chunk-data>\r\n<chunk-size-hex>\r\n<chunk-data>\r\n...
  void _handleChunkedData(Uint8List data) {
    _chunkBuffer.addAll(data);

    while (true) {
      // \r\n을 찾아서 chunk size 라인 파싱
      int crlfIdx = -1;
      for (int i = 0; i < _chunkBuffer.length - 1; i++) {
        if (_chunkBuffer[i] == 0x0D && _chunkBuffer[i + 1] == 0x0A) {
          crlfIdx = i;
          break;
        }
      }
      if (crlfIdx < 0) break; // 아직 완전한 chunk size 라인이 없음

      // chunk size 파싱 (hex)
      final sizeLine = String.fromCharCodes(_chunkBuffer.sublist(0, crlfIdx)).trim();
      if (sizeLine.isEmpty) {
        // 빈 줄 스킵 (이전 chunk 끝의 \r\n)
        _chunkBuffer.removeRange(0, crlfIdx + 2);
        continue;
      }

      final chunkSize = int.tryParse(sizeLine, radix: 16);
      if (chunkSize == null) {
        // hex 파싱 실패 → chunk가 아닌 raw RTCM일 수 있음, 그대로 전달
        final raw = Uint8List.fromList(_chunkBuffer);
        _chunkBuffer.clear();
        _handleRtcmData(raw);
        break;
      }

      if (chunkSize == 0) {
        // 마지막 chunk (0\r\n\r\n)
        _chunkBuffer.clear();
        break;
      }

      // chunk data 시작: crlfIdx + 2, 길이: chunkSize
      final dataStart = crlfIdx + 2;
      final dataEnd = dataStart + chunkSize;

      if (_chunkBuffer.length < dataEnd) break; // 아직 chunk data가 다 안 옴

      // 순수 RTCM 데이터 추출
      final rtcmChunk = Uint8List.fromList(_chunkBuffer.sublist(dataStart, dataEnd));
      _handleRtcmData(rtcmChunk);

      // chunk data 뒤의 \r\n 포함하여 제거
      final nextStart = dataEnd + ((_chunkBuffer.length > dataEnd + 1 &&
          _chunkBuffer[dataEnd] == 0x0D && _chunkBuffer[dataEnd + 1] == 0x0A)
          ? 2 : 0);
      _chunkBuffer.removeRange(0, nextStart);
    }
  }

  void _handleRtcmData(Uint8List data) {
    final wasZero = _bytesReceived == 0;
    _bytesReceived += data.length;
    _rtcmPacketCount++;
    _lastDataTime = DateTime.now();
    _rtcmStartTime ??= DateTime.now();

    // RTCM3 프레임 파싱 - 한 패킷에 여러 메시지가 있을 수 있음
    int offset = 0;
    final msgTypes = <int>[];
    while (offset < data.length - 4) {
      if (data[offset] == 0xD3) {
        final len = ((data[offset + 1] & 0x03) << 8) | data[offset + 2];
        if (offset + 3 + len <= data.length) {
          final msgType = ((data[offset + 3] & 0xFF) << 4) | ((data[offset + 4] & 0xF0) >> 4);
          msgTypes.add(msgType);
          _rtcmTypeCounts[msgType] = (_rtcmTypeCounts[msgType] ?? 0) + 1;
          offset += 3 + len + 3; // header(3) + payload(len) + CRC(3)
          continue;
        }
      }
      offset++;
    }

    String msgInfo = '${data.length}B';
    if (msgTypes.isNotEmpty) {
      msgInfo = '${data.length}B [${msgTypes.map((t) => rtcmTypeName(t)).join(',')}]';
    }

    if (wasZero) {
      _log('첫 RTCM 수신 ($msgInfo)');
    } else if (_rtcmPacketCount % 20 == 0) {
      final elapsed = DateTime.now().difference(_rtcmStartTime!).inSeconds;
      final typesSummary = _rtcmTypeCounts.entries
          .map((e) => '${rtcmTypeName(e.key)}:${e.value}')
          .join(', ');
      _log('RTCM ${elapsed}초 누적 ${(_bytesReceived / 1024).toStringAsFixed(1)}KB (${_rtcmPacketCount}패킷)');
      _log('  메시지: $typesSummary');
      if (!hasReceivedMsm) {
        _log('⚠️ MSM 메시지 미수신! 마운트포인트 확인 필요 (VRS-RTCM34 권장)');
      }
    }
    onRtcmData?.call(data);
    notifyListeners();
  }

  void _startGgaSender() {
    _stopGgaSender();
    _sendGga();
    _ggaSendTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendGga());
  }

  int _ggaSendCount = 0;

  void _sendGga() {
    if (_socket == null || _state != NtripState.connected) return;
    if (_lastGga == null || _lastGga!.isEmpty) {
      _log('GGA 미수신 - GPS 연결 확인 필요 (count=$_ggaSendCount)');
      _ggaSendCount++;
      return;
    }
    try {
      _socket!.add(utf8.encode('${_lastGga!}\r\n'));
      _ggaSendCount++;

      // 처음 5회는 매번 로그, 이후 5초마다
      if (_ggaSendCount <= 5 || _ggaSendCount % 5 == 0) {
        final parts = _lastGga!.split(',');
        final fixQ = parts.length > 6 ? parts[6] : '?';
        final sats = parts.length > 7 ? parts[7] : '?';
        final hdop = parts.length > 8 ? parts[8] : '?';
        final alt = parts.length > 9 ? parts[9] : '?';
        final hasChecksum = _lastGga!.contains('*');
        final lat = parts.length > 2 ? '${parts[2]}${parts[3]}' : '?';
        final lon = parts.length > 5 ? '${parts[4]}${parts[5]}' : '?';
        _log('GGA→서버 Fix:$fixQ 위성:$sats HDOP:$hdop 고도:${alt}m ${hasChecksum ? "CK✓" : "CK✗"}');
        if (_ggaSendCount % 15 == 0) {
          _log('  좌표: $lat/$lon');
        }
      }
    } catch (e) {
      _log('GGA 전송 실패: $e');
    }
  }

  void _stopGgaSender() {
    _ggaSendTimer?.cancel();
    _ggaSendTimer = null;
  }

  /// 자동 재연결 (5초 후)
  void _scheduleReconnect() {
    if (!_shouldAutoReconnect || _config == null) return;
    _reconnectTimer?.cancel();
    _log('5초 후 자동 재연결...');
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      if (_shouldAutoReconnect && _state == NtripState.disconnected) {
        _log('자동 재연결 시도');
        connect(_config!);
      }
    });
  }

  Future<void> disconnect() async {
    _shouldAutoReconnect = false;
    _reconnectTimer?.cancel();
    _stopGgaSender();
    try { _socket?.destroy(); } catch (_) {}
    _socket = null;
    _state = NtripState.disconnected;
    _errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _log('세션 종료');
    _logSink?.flush().then((_) => _logSink?.close());
    _logSink = null;
    _internalLogSink?.flush().then((_) => _internalLogSink?.close());
    _internalLogSink = null;
    disconnect();
    super.dispose();
  }
}
