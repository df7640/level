import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
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
    return NtripConfig(
      host: host,
      port: prefs.getInt('ntrip_port') ?? 2101,
      mountPoint: prefs.getString('ntrip_mount') ?? '',
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

  // 디버그 로그 (앱 화면 표시용)
  final List<String> debugLog = [];
  static const int _maxLogLines = 30;

  NtripState get state => _state;
  NtripConfig? get config => _config;
  String? get errorMessage => _errorMessage;
  int get bytesReceived => _bytesReceived;
  DateTime? get lastDataTime => _lastDataTime;
  bool get isConnected => _state == NtripState.connected;

  void _log(String msg) {
    final ts = DateTime.now();
    final line = '[${ts.hour.toString().padLeft(2,'0')}:${ts.minute.toString().padLeft(2,'0')}:${ts.second.toString().padLeft(2,'0')}] $msg';
    debugPrint('[NTRIP] $msg');
    debugLog.add(line);
    if (debugLog.length > _maxLogLines) debugLog.removeAt(0);
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

    try {
      final socket = await Socket.connect(cfg.host, cfg.port,
          timeout: const Duration(seconds: 10));
      _log('소스테이블 TCP 연결 성공');

      final request = 'GET / HTTP/1.1\r\n'
          'Host: ${cfg.host}\r\n'
          'Ntrip-Version: Ntrip/2.0\r\n'
          'User-Agent: NTRIP LongitudinalViewer/1.0\r\n'
          '\r\n';
      socket.add(utf8.encode(request));
      _log('소스테이블 요청 전송');

      final completer = Completer<List<String>>();
      final buffer = StringBuffer();

      socket.listen(
        (data) {
          buffer.write(utf8.decode(data, allowMalformed: true));
        },
        onDone: () {
          final response = buffer.toString();
          _log('소스테이블 응답 수신 (${response.length}바이트)');
          final mountPoints = <String>[];
          for (final line in response.split('\n')) {
            if (line.startsWith('STR;')) {
              final parts = line.split(';');
              if (parts.length > 1) mountPoints.add(parts[1].trim());
            }
          }
          _log('마운트포인트 ${mountPoints.length}개 발견: ${mountPoints.take(5).join(', ')}');
          notifyListeners();
          if (!completer.isCompleted) completer.complete(mountPoints);
        },
        onError: (e) {
          _log('소스테이블 오류: $e');
          notifyListeners();
          if (!completer.isCompleted) completer.complete([]);
        },
      );

      Future.delayed(const Duration(seconds: 8), () {
        if (!completer.isCompleted) {
          _log('소스테이블 타임아웃');
          socket.destroy();
          notifyListeners();
          completer.complete([]);
        }
      });

      final result = await completer.future;
      try { socket.destroy(); } catch (_) {}
      return result;
    } catch (e) {
      _log('소스테이블 TCP 연결 실패: $e');
      notifyListeners();
      return [];
    }
  }

  /// NTRIP 서버 연결
  Future<void> connect(NtripConfig config) async {
    if (_state == NtripState.connecting || _state == NtripState.connected) {
      await disconnect();
    }

    _config = config;
    _state = NtripState.connecting;
    _errorMessage = null;
    _bytesReceived = 0;
    debugLog.clear();
    notifyListeners();

    // 연결 전에 설정 저장 (실패해도 다음에 불러옴)
    await config.save();

    _log('마운트포인트: ${config.mountPoint}');
    _log('계정: ${config.username} / ${config.password.replaceAll(RegExp(r'.'), '*')}');

    // 국토지리정보원 서버 주소 후보 (구주소 → 신주소 → 직접IP 순서로 시도)
    final hosts = <String>{
      config.host,
      'RTS1.ngii.go.kr',
      'gnss.ngii.go.kr',
      '1.241.250.218',
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
          'Host: ${config.host}\r\n'
          'Ntrip-Version: Ntrip/2.0\r\n'
          'User-Agent: NTRIP LongitudinalViewer/1.0\r\n'
          'Authorization: Basic $credentials\r\n'
          'Accept: */*\r\n'
          'Connection: close\r\n'
          '\r\n';

      _socket!.add(utf8.encode(request));
      _log('HTTP 요청 전송 완료');

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

              if (firstLine.contains('200')) {
                _log('✅ 연결 성공! RTCM 수신 시작');
                _state = NtripState.connected;
                _errorMessage = null;
                notifyListeners();
                _startGgaSender();

                if (bodyStart < headerBuffer.length) {
                  final rtcmData = Uint8List.fromList(headerBuffer.sublist(bodyStart));
                  _log('초기 RTCM 데이터: ${rtcmData.length}바이트');
                  _handleRtcmData(rtcmData);
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
            _handleRtcmData(data);
          }
        },
        onDone: () {
          _log('연결 종료 (서버가 닫음)');
          _state = NtripState.disconnected;
          _stopGgaSender();
          notifyListeners();
        },
        onError: (error) {
          _log('소켓 오류: $error');
          _errorMessage = '소켓 오류: $error';
          _state = NtripState.error;
          _stopGgaSender();
          notifyListeners();
        },
      );
    } catch (e) {
      _log('연결 예외: $e');
      _errorMessage = '연결 실패: $e';
      _state = NtripState.error;
      notifyListeners();
    }
  }

  void _handleRtcmData(Uint8List data) {
    final wasZero = _bytesReceived == 0;
    _bytesReceived += data.length;
    _lastDataTime = DateTime.now();
    if (wasZero) _log('첫 RTCM 데이터 수신 (${data.length}바이트)');
    onRtcmData?.call(data);
    notifyListeners();
  }

  void _startGgaSender() {
    _stopGgaSender();
    _sendGga();
    _ggaSendTimer = Timer.periodic(const Duration(seconds: 10), (_) => _sendGga());
  }

  void _sendGga() {
    if (_socket == null || _state != NtripState.connected) return;
    if (_lastGga == null || _lastGga!.isEmpty) {
      _log('GGA 미수신 - GPS 연결 확인 필요');
      return;
    }
    try {
      _socket!.add(utf8.encode('${_lastGga!}\r\n'));
      _log('GGA 전송: ${_lastGga!.substring(0, _lastGga!.length.clamp(0, 50))}');
    } catch (e) {
      _log('GGA 전송 실패: $e');
    }
  }

  void _stopGgaSender() {
    _ggaSendTimer?.cancel();
    _ggaSendTimer = null;
  }

  Future<void> disconnect() async {
    _stopGgaSender();
    try { _socket?.destroy(); } catch (_) {}
    _socket = null;
    _state = NtripState.disconnected;
    _errorMessage = null;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    super.dispose();
  }
}
