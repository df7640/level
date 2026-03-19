import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/dimension_data.dart';
import '../models/station_data.dart';
import '../services/bluetooth_gnss_service.dart';
import '../services/chcnav_init_data.dart';
import '../services/dxf_service.dart';
import '../services/ntrip_service.dart';
import '../services/snap_service.dart';
import '../services/stakeout_beep_service.dart';
import '../widgets/dxf_painter.dart';
import '../widgets/dimension_painter.dart';
import '../widgets/gps_position_painter.dart';
import '../widgets/magnification_painter.dart';
import '../widgets/snap_overlay_painter.dart';
import '../widgets/user_entity_painter.dart';

/// Undo/Redo 액션 종류
enum _UndoType { addUserEntity, addDimension, addPoint, deleteEntity, changeProperty }

/// Undo/Redo 액션 데이터
class _UndoAction {
  final _UndoType type;
  final dynamic data; // 타입별 데이터

  _UndoAction(this.type, this.data);
}

/// DXF 뷰어 화면
class DxfViewerScreen extends StatefulWidget {
  final List<StationData> stations;

  const DxfViewerScreen({super.key, this.stations = const []});

  @override
  State<DxfViewerScreen> createState() => _DxfViewerScreenState();
}

class _DxfViewerScreenState extends State<DxfViewerScreen> {
  Map<String, dynamic>? _dxfData;
  List<int>? _originalDxfBytes; // 원본 DXF 바이너리 보존
  bool _isLoading = false;
  double _zoom = 1.0;
  Offset _offset = Offset.zero;
  Offset _lastFocalPoint = Offset.zero;
  double _lastZoom = 1.0; // 핀치 줌 누적 방지용

  // 영역 확대 모드 (확대 버튼 드래그 시 활성)
  bool _isZoomWindowMode = false;
  Offset? _zoomWindowStart;
  Offset? _zoomWindowEnd;

  // 측점 선택
  StationData? _selectedStation;

  // 레이어 표시/숨기기
  final Set<String> _hiddenLayers = {};
  // 레이어 잠금 (편집 불가)
  final Set<String> _lockedLayers = {};
  // 시작 시 비활성화할 레이어
  static const _defaultHiddenLayers = [
    '#00temp', '#_leftblock', '#기초라인', '#센터라인',
    '#측점마커&텍스트', '#측점횡단라인',
    '1-블록기초 측점', '1-센터라인 측점강조',
    '47-52 5m 간격 횡단라인',
  ];
  bool _showLayerPanel = false;
  // 레이어별 스타일 오버라이드: { layerName: { 'color': int, 'lw': double } }
  final Map<String, Map<String, dynamic>> _layerStyles = {};

  // 측점 이동 시 사용할 고정 배율
  static const double _stationZoomLevel = 8.0;

  // 하단 툴바 높이
  static const double _bottomBarHeight = 48.0;

  // 캔버스 크기 (LayoutBuilder에서 갱신)
  Size? _lastCanvasSize;

  // 포인트 지정 모드
  bool _isPointMode = false;
  Offset? _touchPoint; // 터치 위치 (화면 좌표)
  SnapResult? _activeSnap; // 현재 활성 스냅
  Map<String, dynamic>? _highlightEntity; // 하이라이트할 엔티티

  // 확정된 스냅 포인트 (DXF 좌표로 저장 → 줌/팬에도 좌표 유지)
  final List<({SnapType type, double dxfX, double dxfY})> _confirmedPoints = [];

  // 치수 측정 모드
  bool _isDimensionMode = false;
  DimensionType _activeDimType = DimensionType.aligned;
  ({SnapType type, double dxfX, double dxfY})? _dimFirstPoint; // 첫 번째 점
  ({SnapType type, double dxfX, double dxfY})? _dimSecondPoint; // 각도 치수용 두 번째 점 (꼭짓점)
  ({double x1, double y1, double x2, double y2, double value, DimensionType type, double? x3, double? y3})? _dimPending; // 배치 대기 중인 치수
  Offset? _dimPlacementDxf; // 배치 드래그 중 치수선 위치 (DXF 좌표)
  final List<DimensionResult> _dimResults = [];
  DimensionStyle _dimStyle = const DimensionStyle();
  int? _selectedDimIndex; // 선택된 치수 (편집/삭제)
  bool _showDimPanel = false; // 치수 관리 패널
  bool _showDimStylePanel = false; // 스타일 설정 패널
  Offset? _cursorTipDxf; // 커서 팁 DXF 좌표 (확대 원용)
  Offset? _cursorTipScreen; // 커서 팁 화면 좌표 (확대창 위치 결정용)

  bool _edgePanDone = false; // 가장자리 자동패닝 1회 제한

  // 그리기 모드: 'line', 'leader', 'text', null
  String? _activeDrawMode;
  ({double dxfX, double dxfY})? _drawFirstPoint; // 그리기 첫 점
  List<Map<String, double>> _leaderPoints = []; // 지시선 점들
  final List<Map<String, dynamic>> _userEntities = []; // 사용자 추가 엔티티
  int _drawColor = 0xFFFFFF00; // 기본 노란색
  double _drawLineWidth = 1.0;
  double _drawTextSize = 14.0;
  int _drawPointStyle = 34; // PDMODE (circle + cross)

  // 엔티티 선택 모드
  bool _isSelectMode = false;
  final List<Map<String, dynamic>> _selectedEntities = [];
  bool _showPropertyPanel = false;
  // 속성 패널 접기/펼치기 상태
  bool _propExpandColor = true;
  bool _propExpandFoundation = true;
  bool _propExpandInterpol = true;
  int? _baselineSegOverride; // 이전/다음 버튼으로 세그먼트 인덱스 오버라이드
  ({double x, double y})? _lastSelectDxfPoint; // 선택 시 터치 DXF 좌표 (기초라인 근접 측점 검색용)

  // 선택 모드 유형: single, multi, area, fence
  String _selectModeType = 'single';
  // 영역/펜스 선택용
  ({double x, double y})? _areaSelectStart;
  ({double x, double y})? _areaSelectEnd;
  final List<({double x, double y})> _fencePoints = [];

  int _dxfRepaintVersion = 0; // DxfPainter 강제 repaint 트리거

  // 기초라인 보간 구간: (시작거리, 끝거리, 간격) 목록
  final List<({double startDist, double endDist, double interval})> _baselineInterpolRanges = [];

  // Undo/Redo 스택
  final List<_UndoAction> _undoStack = [];
  final List<_UndoAction> _redoStack = [];
  static const int _maxUndoSteps = 50;

  // GPS
  final BluetoothGnssService _gnssService = BluetoothGnssService();
  bool _gpsAutoCenter = true; // GPS 자동 중앙 정렬
  Timer? _gpsCenterTimer; // 5초 주기 자동 정렬 타이머
  GnssConnectionState? _prevGnssState; // 연결 상태 변화 감지용

  // NTRIP
  final NtripService _ntripService = NtripService();

  // 측설 모드
  ({double dxfX, double dxfY, String name})? _stakeoutTarget; // 측설 대상 포인트
  final StakeoutBeepService _beepService = StakeoutBeepService();
  double _antennaHeight = 1.8000; // 안테나 높이 (m)

  // GPS 정보 패널 표시 여부
  bool _showInfoPanel = false;

  // 줌 배율 프리뷰 모드
  bool _zoomPreviewMode = false;
  double _previewZoom = 1.0;
  String _previewLabel = '';

  // 측설 자동 줌 배율 (거리 임계값 → 줌 레벨)
  // 거리가 해당 임계값 이내면 대응하는 줌 배율 적용
  final List<(double distance, double zoom)> _autoZoomLevels = [
    (10.0,  10.0),   // 10m 이내
    (5.0,   20.0),   // 5m 이내
    (2.0,   50.0),   // 2m 이내
    (1.0,   100.0),  // 1m 이내
    (0.5,   200.0),  // 50cm 이내
    (0.3,   300.0),  // 30cm 이내
    (0.1,   500.0),  // 10cm 이내
    (0.05,  800.0),  // 5cm 이내
  ];

  /// 좌표가 있는 측점만 필터
  List<StationData> get _stationsWithCoords =>
      widget.stations.where((s) => s.x != null && s.y != null).toList();

  /// 현재 DXF의 레이어 목록
  List<String> get _layers {
    if (_dxfData == null) return [];
    final layers = _dxfData!['layers'] as List?;
    if (layers == null) return [];
    final result = layers.cast<String>().toList()..sort();
    return result;
  }

  /// 자동 줌 배율 저장
  Future<void> _saveAutoZoomLevels() async {
    final prefs = await SharedPreferences.getInstance();
    final values = _autoZoomLevels.map((l) => '${l.$1}:${l.$2}').join(',');
    await prefs.setString('auto_zoom_levels', values);
  }

  /// 자동 줌 배율 로드
  Future<void> _loadAutoZoomLevels() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString('auto_zoom_levels');
    if (str == null || str.isEmpty) return;
    try {
      final parts = str.split(',');
      for (int i = 0; i < parts.length && i < _autoZoomLevels.length; i++) {
        final kv = parts[i].split(':');
        if (kv.length == 2) {
          _autoZoomLevels[i] = (double.parse(kv[0]), double.parse(kv[1]));
        }
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _loadSampleDxf();
    _loadAutoZoomLevels();
    _gnssService.addListener(_onGnssUpdate);
    _ntripService.addListener(_onNtripUpdate);
    _ntripService.loadConfig();
    _ntripService.initFileLog();
    // BT 이벤트도 같은 파일에 기록
    _gnssService.fileLogger = (msg) => _ntripService.logExternal(msg);
    // NTRIP RTCM → 블루투스 수신기로 전달
    _ntripService.onRtcmData = (data) {
      debugPrint('[RTCM-RELAY] NTRIP→BT ${data.length}B');
      _gnssService.sendRtcm(data);
    };
  }

  @override
  void dispose() {
    _gpsCenterTimer?.cancel();
    _beepService.dispose();
    _gnssService.removeListener(_onGnssUpdate);
    _ntripService.removeListener(_onNtripUpdate);
    // NTRIP 먼저 끊고 BT 해제 (순서 중요)
    _ntripService.dispose();
    _gnssService.disconnect();
    _gnssService.dispose();
    super.dispose();
  }

  // Fix 상태 변화 감지용
  int _prevFixQuality = -1;

  void _onGnssUpdate() {
    if (!mounted) return;

    // GPS 연결 상태 변화 감지
    final currentState = _gnssService.connectionState;
    if (_prevGnssState != currentState) {
      if (currentState == GnssConnectionState.connected) {
        _gpsAutoCenter = true;
        _startGpsCenterTimer();
        _showStatusMessage('서버에 연결되었습니다', Colors.green);
      } else if (currentState == GnssConnectionState.disconnected) {
        _stopGpsCenterTimer();
        _exitStakeout();
        _showStatusMessage('연결이 해제되었습니다', Colors.red);
      } else if (currentState == GnssConnectionState.error) {
        _showStatusMessage('연결 오류 발생', Colors.red);
      }
      _prevGnssState = currentState;
    }

    // Fix 품질 변화 감지 → 메시지 표시
    final currentFix = _gnssService.fixQuality;
    if (currentFix != _prevFixQuality && currentState == GnssConnectionState.connected) {
      if (currentFix == 4 && _prevFixQuality != 4) {
        _showStatusMessage('RTK 픽스되었습니다!', Colors.greenAccent);
      } else if (currentFix == 5 && _prevFixQuality != 5) {
        _showStatusMessage('보정신호 수신중입니다 (Float)', Colors.yellow);
      } else if (currentFix == 2 && _prevFixQuality != 2) {
        _showStatusMessage('DGPS 보정 수신중', Colors.orange);
      } else if (currentFix == 1 && _prevFixQuality < 1) {
        _showStatusMessage('GPS 단독측위', Colors.orange);
      } else if (currentFix == 0 && _prevFixQuality > 0) {
        _showStatusMessage('위성 탐색중...', Colors.red);
      }
      _prevFixQuality = currentFix;
    }

    // NTRIP에 GGA 전송 (VRS 보정 기준점)
    if (_ntripService.isConnected && _gnssService.lastGga != null) {
      _ntripService.updateGga(_gnssService.lastGga!);
    } else if (_ntripService.isConnected && _gnssService.lastGga == null) {
      debugPrint('[GGA-FWD] NTRIP연결중이나 GGA null');
    }

    // 측설 거리/비프 업데이트
    if (_stakeoutTarget != null && _gnssService.position != null) {
      final pos = _gnssService.position!;
      final dx = _stakeoutTarget!.dxfX - pos.tmX;
      final dy = _stakeoutTarget!.dxfY - pos.tmY;
      final distance = sqrt(dx * dx + dy * dy);
      _beepService.updateForDistance(distance);
    }

    setState(() {});
  }

  void _onNtripUpdate() {
    if (!mounted) return;
    setState(() {});
  }

  /// 상태 메시지 스낵바 (눈에 잘 보이게)
  void _showStatusMessage(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(Icons.info_outline, color: Colors.black, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  /// GPS 자동 중앙 정렬 타이머 시작 (5초 주기)
  void _startGpsCenterTimer() {
    _gpsCenterTimer?.cancel();
    // 첫 위치 즉시 정렬
    if (_gnssService.position != null) {
      _centerOnGpsPosition();
    }
    _gpsCenterTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_gpsAutoCenter && _gnssService.position != null && mounted) {
        _centerOnGpsPosition();
      }
    });
  }

  void _stopGpsCenterTimer() {
    _gpsCenterTimer?.cancel();
    _gpsCenterTimer = null;
  }

  /// GPS 현재 위치로 화면 중앙 이동
  void _centerOnGpsPosition() {
    final pos = _gnssService.position;
    if (pos == null || _dxfData == null || _lastCanvasSize == null) return;

    double targetZoom = _zoom;

    // 측설 활성 시 거리 기반 단계별 자동 줌
    if (_stakeoutTarget != null) {
      final dx = _stakeoutTarget!.dxfX - pos.tmX;
      final dy = _stakeoutTarget!.dxfY - pos.tmY;
      final distance = sqrt(dx * dx + dy * dy);
      targetZoom = 5.0; // 기본 (10m 밖)
      for (final level in _autoZoomLevels) {
        if (distance <= level.$1) {
          targetZoom = level.$2;
        }
      }
    }

    _centerOnDxfPoint(pos.tmX, pos.tmY, targetZoom: targetZoom);
  }

  /// DXF 좌표를 화면 중앙에 배치
  void _centerOnDxfPoint(double dxfX, double dxfY, {double? targetZoom}) {
    if (_dxfData == null || _lastCanvasSize == null) return;
    final canvasSize = _lastCanvasSize!;
    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;
    if (dxfWidth <= 0 || dxfHeight <= 0) return;

    final sX = canvasSize.width * 0.9 / dxfWidth;
    final sY = canvasSize.height * 0.9 / dxfHeight;
    final baseScale = sX < sY ? sX : sY;

    final zoom = targetZoom ?? _zoom;
    final scale = baseScale * zoom;
    final centerOffsetX = (canvasSize.width - dxfWidth * scale) / 2;
    final centerOffsetY = (canvasSize.height - dxfHeight * scale) / 2;
    final screenCenterX = canvasSize.width / 2;
    final screenCenterY = canvasSize.height / 2;
    final newOffsetDx = screenCenterX - (dxfX - minX) * scale - centerOffsetX;
    final newOffsetDy = canvasSize.height - screenCenterY - (dxfY - minY) * scale - centerOffsetY;

    setState(() {
      if (targetZoom != null) _zoom = targetZoom;
      _offset = Offset(newOffsetDx, newOffsetDy);
    });
  }

  /// GPS 위치와 포인트 위치가 도면뷰에 가득 차도록 줌/오프셋 조정
  void _zoomToFitGpsAndPoint(double ptX, double ptY) {
    final pos = _gnssService.position;
    if (pos == null || _dxfData == null || _lastCanvasSize == null) return;

    final canvasSize = _lastCanvasSize!;
    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;
    if (dxfWidth <= 0 || dxfHeight <= 0) return;

    final sX = canvasSize.width * 0.9 / dxfWidth;
    final sY = canvasSize.height * 0.9 / dxfHeight;
    final baseScale = sX < sY ? sX : sY;

    // 두 점의 범위
    final gpsX = pos.tmX;
    final gpsY = pos.tmY;
    final fitMinX = gpsX < ptX ? gpsX : ptX;
    final fitMaxX = gpsX > ptX ? gpsX : ptX;
    final fitMinY = gpsY < ptY ? gpsY : ptY;
    final fitMaxY = gpsY > ptY ? gpsY : ptY;
    final spanX = fitMaxX - fitMinX;
    final spanY = fitMaxY - fitMinY;

    // 여유 30% 포함하여 줌 계산
    final margin = 1.3;
    double zoom;
    if (spanX <= 0.001 && spanY <= 0.001) {
      zoom = 200.0; // 거의 같은 위치
    } else {
      final neededZoomX = spanX > 0 ? (canvasSize.width * 0.9) / (spanX * margin * baseScale) : 800.0;
      final neededZoomY = spanY > 0 ? (canvasSize.height * 0.9) / (spanY * margin * baseScale) : 800.0;
      zoom = (neededZoomX < neededZoomY ? neededZoomX : neededZoomY).clamp(1.0, 800.0);
    }

    // 중심점
    final centerX = (fitMinX + fitMaxX) / 2;
    final centerY = (fitMinY + fitMaxY) / 2;
    _centerOnDxfPoint(centerX, centerY, targetZoom: zoom);
  }

  /// 측설 모드 종료
  void _exitStakeout() {
    _stakeoutTarget = null;
    _beepService.stop();
  }

  /// GPS 아이콘 색상
  Color _getGpsIconColor() {
    switch (_gnssService.connectionState) {
      case GnssConnectionState.connected:
        final fix = _gnssService.fixQuality;
        if (fix == 4) return Colors.green;
        if (fix == 5) return Colors.yellow;
        if (fix >= 1) return Colors.orange;
        return Colors.red;
      case GnssConnectionState.connecting:
        return Colors.yellow;
      case GnssConnectionState.error:
        return Colors.red;
      case GnssConnectionState.disconnected:
        return Colors.white54;
    }
  }

  /// GPS Fix 상태 텍스트
  String _getFixStatusText() {
    final fix = _gnssService.fixQuality;
    switch (fix) {
      case 4: return 'RTK 픽스';
      case 5: return 'Float (보정신호 수신중)';
      case 2: return 'DGPS';
      case 1: return '단독측위';
      default: return '위성 탐색중...';
    }
  }

  /// GPS 메뉴 (연결/해제/NTRIP 설정)
  void _showGpsMenu() {
    final isConnected = _gnssService.connectionState == GnssConnectionState.connected;
    final isConnecting = _gnssService.connectionState == GnssConnectionState.connecting;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'GPS / NTRIP 설정',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              // GPS 연결 (init59)
              if (!isConnected && !isConnecting)
                ListTile(
                  leading: const Icon(Icons.bluetooth_searching, color: Colors.blue),
                  title: const Text('GPS 59개', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('btsnoop 59개 고유 명령', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _gnssService.initMode = InitMode.init59;
                    _connectGps();
                  },
                ),
              // GPS 연결 (init29)
              if (!isConnected && !isConnecting)
                ListTile(
                  leading: const Icon(Icons.bluetooth_searching, color: Colors.green),
                  title: const Text('GPS 29개', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('원본 29개 명령', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _gnssService.initMode = InitMode.init29;
                    _connectGps();
                  },
                ),
              // GPS 연결 (init25)
              if (!isConnected && !isConnecting)
                ListTile(
                  leading: const Icon(Icons.bluetooth_searching, color: Colors.orange),
                  title: const Text('GPS 25개', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('IN_DART 매칭 25개', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _gnssService.initMode = InitMode.init25;
                    _connectGps();
                  },
                ),
              // GPS 연결 (init99)
              if (!isConnected && !isConnecting)
                ListTile(
                  leading: const Icon(Icons.bluetooth_searching, color: Colors.purple),
                  title: const Text('GPS 99개', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('59개 + 고빈도 폴링 반복', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _gnssService.initMode = InitMode.init99;
                    _connectGps();
                  },
                ),
              // GPS 연결 끊기
              if (isConnected || isConnecting)
                ListTile(
                  leading: const Icon(Icons.bluetooth_disabled, color: Colors.red),
                  title: Text(
                    'GPS 연결 끊기${_gnssService.deviceName != null ? " (${_gnssService.deviceName})" : ""}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _gnssService.disconnect();
                    _ntripService.disconnect();
                    _showStatusMessage('GPS 연결이 해제되었습니다', Colors.red);
                  },
                ),
              const Divider(color: Colors.white24),
              // NTRIP 연결
              ListTile(
                leading: Icon(
                  Icons.cell_tower,
                  color: _ntripService.isConnected ? Colors.greenAccent : Colors.orange,
                ),
                title: Text(
                  _ntripService.isConnected ? 'NTRIP 연결됨' : 'NTRIP 설정',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  _ntripService.isConnected
                      ? '${_ntripService.config?.host ?? ""}/${_ntripService.config?.mountPoint ?? ""} - ${(_ntripService.bytesReceived / 1024).toStringAsFixed(1)} KB 수신'
                      : 'RTK 보정 데이터 수신 설정',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _showNtripSettingsDialog();
                },
              ),
              // NTRIP 연결 끊기
              if (_ntripService.isConnected)
                ListTile(
                  leading: const Icon(Icons.cell_tower, color: Colors.red),
                  title: const Text('NTRIP 연결 끊기', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _ntripService.disconnect();
                    _showStatusMessage('NTRIP 연결이 해제되었습니다', Colors.orange);
                  },
                ),
              // NTRIP 디버그 로그 (항상 표시)
              ListTile(
                leading: const Icon(Icons.bug_report, color: Colors.white54),
                title: Text(
                  'NTRIP 로그${_ntripService.debugLog.isNotEmpty ? " (${_ntripService.debugLog.length})" : ""}',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: _ntripService.hasReceivedMsm
                    ? const Text('MSM 수신중', style: TextStyle(color: Colors.greenAccent, fontSize: 11))
                    : _ntripService.bytesReceived > 0
                        ? const Text('MSM 미수신 - 마운트포인트 확인', style: TextStyle(color: Colors.orangeAccent, fontSize: 11))
                        : null,
                onTap: () {
                  Navigator.pop(ctx);
                  _showNtripLogDialog();
                },
              ),
              // GPS/BT 로그 보기
              ListTile(
                leading: const Icon(Icons.description, color: Colors.white54),
                title: const Text('GPS/BT 로그', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showGpsLogDialog();
                },
              ),
              // BT/NTRIP 로그 파일 공유
              ListTile(
                leading: const Icon(Icons.share, color: Colors.white54),
                title: const Text('로그 파일 공유', style: TextStyle(color: Colors.white)),
                subtitle: Text(
                  _ntripService.internalLogPath != null
                      ? '앱 내부 + Download 저장됨'
                      : '로그 파일 없음',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareLogFile();
                },
              ),
              const Divider(color: Colors.white24),
              // 수신기 명령 전송
              if (isConnected)
                ListTile(
                  leading: const Icon(Icons.terminal, color: Colors.amber),
                  title: const Text('수신기 명령 전송', style: TextStyle(color: Colors.white)),
                  subtitle: const Text('i70 설정 조회/변경', style: TextStyle(color: Colors.white38, fontSize: 12)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showReceiverCommandDialog();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// GPS 블루투스 연결
  void _connectGps() async {
    final btConnect = await Permission.bluetoothConnect.request();
    final btScan = await Permission.bluetoothScan.request();
    final location = await Permission.locationWhenInUse.request();

    if (btConnect.isGranted && btScan.isGranted && location.isGranted) {
      _showBluetoothDeviceDialog();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('블루투스 및 위치 권한이 필요합니다. 설정에서 허용해주세요.')),
        );
      }
    }
  }

  /// NTRIP 설정 다이얼로그
  void _showNtripSettingsDialog() async {
    final config = _ntripService.config;
    final hostCtrl = TextEditingController(text: config?.host ?? 'rts1.ngii.go.kr');
    final portCtrl = TextEditingController(text: (config?.port ?? 2101).toString());
    final mountCtrl = TextEditingController(text: config?.mountPoint ?? 'VRS-RTCM34');
    final userCtrl = TextEditingController(text: config?.username ?? 'ysc7640');
    final passCtrl = TextEditingController(text: config?.password ?? 'ngii');

    // 마운트포인트 목록
    List<String>? mountPoints;
    bool loadingMounts = false;
    bool passVisible = false;

    if (!mounted) return;

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.grey[850],
              title: const Text('NTRIP 설정', style: TextStyle(color: Colors.white)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: hostCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: '서버 주소',
                        labelStyle: TextStyle(color: Colors.white54),
                        hintText: 'gnss.ngii.go.kr',
                        hintStyle: TextStyle(color: Colors.white24),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: portCtrl,
                      style: const TextStyle(color: Colors.white),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '포트',
                        labelStyle: TextStyle(color: Colors.white54),
                        hintText: '2101',
                        hintStyle: TextStyle(color: Colors.white24),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: mountCtrl,
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(
                              labelText: '마운트포인트',
                              labelStyle: TextStyle(color: Colors.white54),
                              hintText: '소스테이블에서 선택',
                              hintStyle: TextStyle(color: Colors.white24),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        loadingMounts
                            ? const SizedBox(
                                width: 24, height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : IconButton(
                                icon: const Icon(Icons.download, color: Colors.cyanAccent),
                                tooltip: '마운트포인트 목록 가져오기',
                                onPressed: () async {
                                  setDialogState(() => loadingMounts = true);
                                  final tempConfig = NtripConfig(
                                    host: hostCtrl.text.trim(),
                                    port: int.tryParse(portCtrl.text) ?? 2101,
                                    mountPoint: '',
                                    username: userCtrl.text.trim(),
                                    password: passCtrl.text.trim(),
                                  );
                                  final mounts = await _ntripService.getSourceTable(tempConfig: tempConfig);
                                  setDialogState(() {
                                    mountPoints = mounts;
                                    loadingMounts = false;
                                  });
                                },
                              ),
                      ],
                    ),
                    // 마운트포인트 목록
                    if (mountPoints != null && mountPoints!.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        constraints: const BoxConstraints(maxHeight: 100),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white24),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: mountPoints!.length,
                          itemBuilder: (_, i) {
                            final mp = mountPoints![i];
                            final isSelected = mountCtrl.text == mp;
                            return ListTile(
                              dense: true,
                              title: Text(
                                mp,
                                style: TextStyle(
                                  color: isSelected ? Colors.cyanAccent : Colors.white,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                              onTap: () {
                                mountCtrl.text = mp;
                                setDialogState(() {});
                              },
                            );
                          },
                        ),
                      ),
                    if (mountPoints != null && mountPoints!.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('마운트포인트를 찾을 수 없습니다', style: TextStyle(color: Colors.red, fontSize: 12)),
                      ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: userCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        labelText: '아이디',
                        labelStyle: TextStyle(color: Colors.white54),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: passCtrl,
                      style: const TextStyle(color: Colors.white),
                      obscureText: !passVisible,
                      decoration: InputDecoration(
                        labelText: '비밀번호',
                        labelStyle: const TextStyle(color: Colors.white54),
                        hintText: '국토지리정보원: ngii',
                        hintStyle: const TextStyle(color: Colors.white24),
                        suffixIcon: IconButton(
                          icon: Icon(
                            passVisible ? Icons.visibility_off : Icons.visibility,
                            color: Colors.white38,
                          ),
                          onPressed: () => setDialogState(() => passVisible = !passVisible),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('취소', style: TextStyle(color: Colors.white54)),
                ),
                TextButton(
                  onPressed: () {
                    final newConfig = NtripConfig(
                      host: hostCtrl.text.trim(),
                      port: int.tryParse(portCtrl.text) ?? 2101,
                      mountPoint: mountCtrl.text.trim(),
                      username: userCtrl.text.trim(),
                      password: passCtrl.text.trim(),
                    );
                    newConfig.save();
                    Navigator.pop(ctx);
                    _showStatusMessage('설정이 저장되었습니다', Colors.blue);
                  },
                  child: const Text('저장', style: TextStyle(color: Colors.cyanAccent)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () {
                    final newConfig = NtripConfig(
                      host: hostCtrl.text.trim(),
                      port: int.tryParse(portCtrl.text) ?? 2101,
                      mountPoint: mountCtrl.text.trim(),
                      username: userCtrl.text.trim(),
                      password: passCtrl.text.trim(),
                    );
                    Navigator.pop(ctx);
                    _ntripService.connect(newConfig);
                    _showStatusMessage('NTRIP 연결 시도중...', Colors.cyanAccent);
                  },
                  child: const Text('연결'),
                ),
              ],
            );
          },
        );
      },
    );
    hostCtrl.dispose();
    portCtrl.dispose();
    mountCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
  }

  /// GPS/BT 로그 다이얼로그 (내부 로그 파일 읽기)
  void _showGpsLogDialog() async {
    final path = _ntripService.internalLogPath;
    String content = '로그 파일이 없습니다.';
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        await _ntripService.flushLog();
        final lines = await file.readAsLines();
        // BT 관련 라인만 필터 + 최근 200줄
        final btLines = lines.where((l) => l.contains('[BT') || l.contains('INIT') || l.contains('연결') || l.contains('오류') || l.contains('실패') || l.contains('GGA')).toList();
        final show = btLines.length > 200 ? btLines.sublist(btLines.length - 200) : btLines;
        content = show.join('\n');
        if (content.isEmpty) content = '(BT 로그 없음, 전체 ${lines.length}줄)';
      }
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Row(children: [
          const Expanded(child: Text('GPS/BT 로그', style: TextStyle(color: Colors.white, fontSize: 14))),
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.cyanAccent, size: 20),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: content));
              _showStatusMessage('복사됨', Colors.greenAccent);
            },
          ),
          IconButton(
            icon: const Icon(Icons.share, color: Colors.cyanAccent, size: 20),
            onPressed: () => _shareLogFile(),
          ),
        ]),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: Text(content, style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
        ],
      ),
    );
  }

  /// NTRIP 디버그 로그 다이얼로그
  void _showNtripLogDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            // 1초마다 갱신
            final timer = Stream.periodic(const Duration(seconds: 1));
            timer.take(60).listen((_) {
              if (ctx.mounted) setDialogState(() {});
            });

            final logs = _ntripService.debugLog;
            return AlertDialog(
              backgroundColor: Colors.grey[900],
              title: Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 12,
                    color: _ntripService.isConnected ? Colors.greenAccent : Colors.orange,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'NTRIP 로그 ${(_ntripService.bytesReceived / 1024).toStringAsFixed(1)}KB${_ntripService.hasReceivedMsm ? " MSM✓" : ""}',
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 400,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // RTCM 메시지 타입 요약
                    if (_ntripService.rtcmTypeCounts.isNotEmpty) ...[
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'RTCM: ${_ntripService.rtcmTypeCounts.entries.map((e) => '${NtripService.rtcmTypeName(e.key)}(${e.value})').join(', ')}',
                          style: TextStyle(
                            color: _ntripService.hasReceivedMsm ? Colors.greenAccent : Colors.orangeAccent,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    // BT 릴레이 상태
                    if (_gnssService.rtcmBytesSent > 0) ...[
                      Text(
                        'BT전송: ${(_gnssService.rtcmBytesSent / 1024).toStringAsFixed(1)}KB (${_gnssService.rtcmSendCount}회)${_gnssService.rtcmFlushErrors > 0 ? " 오류:${_gnssService.rtcmFlushErrors}" : ""}',
                        style: const TextStyle(color: Colors.cyanAccent, fontSize: 10, fontFamily: 'monospace'),
                      ),
                      const SizedBox(height: 4),
                    ],
                    // 로그 목록
                    Expanded(
                      child: logs.isEmpty
                          ? const Center(
                              child: Text('로그 없음', style: TextStyle(color: Colors.white38)),
                            )
                          : ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (_, i) {
                          final line = logs[i];
                          Color color = Colors.white70;
                          if (line.contains('✅')) color = Colors.greenAccent;
                          if (line.contains('❌')) color = Colors.redAccent;
                          if (line.contains('GGA')) color = Colors.cyanAccent;
                          if (line.contains('RTCM')) color = Colors.yellowAccent;
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1),
                            child: Text(
                              line,
                              style: TextStyle(
                                color: color,
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    _ntripService.debugLog.clear();
                    setDialogState(() {});
                  },
                  child: const Text('지우기', style: TextStyle(color: Colors.white38)),
                ),
                TextButton(
                  onPressed: () {
                    final text = _buildDebugText(_gnssService.debugResponses);
                    Clipboard.setData(ClipboardData(text: text));
                    _showStatusMessage('클립보드에 복사됨', Colors.greenAccent);
                  },
                  child: const Text('복사', style: TextStyle(color: Colors.amber)),
                ),
                TextButton(
                  onPressed: () => _shareDebugInfo(_gnssService.debugResponses),
                  child: const Text('공유', style: TextStyle(color: Colors.cyanAccent)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('닫기', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 수신기 명령 전송 다이얼로그
  void _showReceiverCommandDialog() {
    final cmdCtrl = TextEditingController();
    _gnssService.debugResponses.clear();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            // 1초마다 응답 갱신
            final timer = Stream.periodic(const Duration(seconds: 1));
            timer.take(120).listen((_) {
              if (ctx.mounted) setDialogState(() {});
            });

            final responses = _gnssService.debugResponses;
            return AlertDialog(
              backgroundColor: Colors.grey[900],
              title: Row(
                children: [
                  const Icon(Icons.terminal, color: Colors.amber, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('i70 수신기 명령', style: TextStyle(color: Colors.white, fontSize: 14)),
                  ),
                  // 공유 버튼
                  IconButton(
                    icon: const Icon(Icons.share, color: Colors.cyanAccent, size: 20),
                    onPressed: () => _shareDebugInfo(responses),
                    tooltip: '결과 공유',
                  ),
                ],
              ),
              content: SizedBox(
                width: double.maxFinite,
                height: 450,
                child: Column(
                  children: [
                    // 프리셋 버튼
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        _cmdPresetBtn('설정 전체 조회', () async {
                          await _gnssService.queryReceiverSettings();
                          if (ctx.mounted) setDialogState(() {});
                        }),
                        _cmdPresetBtn('VERSION', () async {
                          await _gnssService.sendDebugCommand('LOG VERSION ONCE');
                          if (ctx.mounted) setDialogState(() {});
                        }),
                        _cmdPresetBtn('COMCONFIG', () async {
                          await _gnssService.sendDebugCommand('LOG COMCONFIG ONCE');
                          if (ctx.mounted) setDialogState(() {});
                        }),
                        _cmdPresetBtn('응답 지우기', () {
                          _gnssService.debugResponses.clear();
                          setDialogState(() {});
                        }),
                        // Unicore INTERFACEMODE 테스트
                        _cmdPresetBtn('BT RTCM3 설정', () async {
                          await _gnssService.sendDebugCommand('INTERFACEMODE BT RTCMV3 NMEA OFF');
                          if (ctx.mounted) setDialogState(() {});
                        }),
                        _cmdPresetBtn('BLUETOOTH RTCM3', () async {
                          await _gnssService.sendDebugCommand('INTERFACEMODE BLUETOOTH RTCMV3 NMEA OFF');
                          if (ctx.mounted) setDialogState(() {});
                        }),
                        _cmdPresetBtn('COM2 RTCM3', () async {
                          await _gnssService.sendDebugCommand('INTERFACEMODE COM2 RTCMV3 NMEA OFF');
                          if (ctx.mounted) setDialogState(() {});
                        }),
                        _cmdPresetBtn('COM3 RTCM3', () async {
                          await _gnssService.sendDebugCommand('INTERFACEMODE COM3 RTCMV3 NMEA OFF');
                          if (ctx.mounted) setDialogState(() {});
                        }),
                        _cmdPresetBtn('SAVECONFIG', () async {
                          await _gnssService.sendDebugCommand('SAVECONFIG');
                          if (ctx.mounted) setDialogState(() {});
                        }),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 직접 입력
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: cmdCtrl,
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                            decoration: InputDecoration(
                              hintText: '명령 입력 (예: PCHC,GET,PORT,BT)',
                              hintStyle: const TextStyle(color: Colors.white24, fontSize: 11),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              isDense: true,
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(4),
                                borderSide: BorderSide(color: Colors.grey[700]!),
                              ),
                            ),
                            onSubmitted: (v) async {
                              if (v.trim().isEmpty) return;
                              await _gnssService.sendDebugCommand(v.trim());
                              cmdCtrl.clear();
                              if (ctx.mounted) setDialogState(() {});
                            },
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          height: 34,
                          child: ElevatedButton(
                            onPressed: () async {
                              if (cmdCtrl.text.trim().isEmpty) return;
                              await _gnssService.sendDebugCommand(cmdCtrl.text.trim());
                              cmdCtrl.clear();
                              if (ctx.mounted) setDialogState(() {});
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amber[800],
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                            ),
                            child: const Text('전송', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 응답 목록
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: responses.isEmpty
                            ? const Center(child: Text('명령을 전송하면 응답이 여기에 표시됩니다',
                                style: TextStyle(color: Colors.white24, fontSize: 11)))
                            : ListView.builder(
                                itemCount: responses.length,
                                itemBuilder: (_, i) {
                                  final line = responses[i];
                                  final isSent = line.startsWith('>>>');
                                  final isHeader = line.startsWith('===');
                                  Color color = Colors.white70;
                                  if (isSent) color = Colors.cyanAccent;
                                  if (isHeader) color = Colors.amber;
                                  if (line.contains('OK')) color = Colors.greenAccent;
                                  if (line.contains('ERROR') || line.contains('error')) color = Colors.redAccent;
                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 1),
                                    child: Text(
                                      line,
                                      style: TextStyle(color: color, fontSize: 10, fontFamily: 'monospace'),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    final text = _buildDebugText(responses);
                    Clipboard.setData(ClipboardData(text: text));
                    _showStatusMessage('클립보드에 복사됨', Colors.greenAccent);
                  },
                  child: const Text('복사', style: TextStyle(color: Colors.amber)),
                ),
                TextButton(
                  onPressed: () => _shareDebugInfo(responses),
                  child: const Text('공유', style: TextStyle(color: Colors.cyanAccent)),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('닫기', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _cmdPresetBtn(String label, VoidCallback onTap) {
    return SizedBox(
      height: 28,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          side: BorderSide(color: Colors.grey[600]!),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(label, style: const TextStyle(color: Colors.amber, fontSize: 10)),
      ),
    );
  }

  /// 디버그 텍스트 생성 (공유/복사 공용)
  String _buildDebugText(List<String> responses) {
    final buf = StringBuffer();
    buf.writeln('[i70 디버그 정보]');
    buf.writeln('시각: ${DateTime.now().toString().substring(0, 19)}');
    buf.writeln('기기: ${_gnssService.deviceName ?? "미연결"}');
    buf.writeln('BT: ${_gnssService.connectionState.name}');

    // Fix 상태 상세
    final fixLabel = switch (_gnssService.fixQuality) {
      1 => 'GPS',
      2 => 'DGPS',
      4 => 'RTK Fixed',
      5 => 'RTK Float',
      _ => 'N/A(${_gnssService.fixQuality})',
    };
    buf.writeln('Fix: $fixLabel  위성: ${_gnssService.satellites}  PDOP: ${_gnssService.pdop ?? "-"}');

    // 마지막 GGA
    final gga = _gnssService.lastGga;
    if (gga != null) {
      buf.writeln('GGA: $gga');
    }

    // 위치
    final pos = _gnssService.position;
    if (pos != null) {
      buf.writeln('WGS84: ${pos.latitude.toStringAsFixed(8)}, ${pos.longitude.toStringAsFixed(8)}');
      buf.writeln('TM: ${pos.tmX.toStringAsFixed(3)}, ${pos.tmY.toStringAsFixed(3)}');
      buf.writeln('고도: ${pos.altitude?.toStringAsFixed(2) ?? "-"}m  HDOP: ${pos.hdop ?? "-"}  diffAge: ${pos.diffAge ?? "null"}');
    }

    buf.writeln('RTCM: ${_gnssService.rtcmSendCount}회 ${(_gnssService.rtcmBytesSent / 1024).toStringAsFixed(1)}KB err:${_gnssService.rtcmFlushErrors}');
    buf.writeln('NTRIP: ${_ntripService.state.name} ${(_ntripService.bytesReceived / 1024).toStringAsFixed(1)}KB');
    if (_ntripService.rtcmTypeCounts.isNotEmpty) {
      buf.writeln('RTCM msg: ${_ntripService.rtcmTypeCounts.entries.map((e) => '${NtripService.rtcmTypeName(e.key)}(${e.value})').join(', ')}');
    }
    buf.writeln('');

    // 수신기 명령 응답
    if (responses.isNotEmpty) {
      buf.writeln('[수신기 응답]');
      for (final r in responses) {
        // 깨진 문자 제거
        final clean = r.replaceAll(RegExp(r'[^\x20-\x7E가-힣ㄱ-ㅎㅏ-ㅣ]'), '');
        if (clean.trim().isNotEmpty) buf.writeln(clean);
      }
      buf.writeln('');
    }

    // NTRIP 로그 (이모지 제거)
    if (_ntripService.debugLog.isNotEmpty) {
      buf.writeln('[NTRIP 로그]');
      for (final l in _ntripService.debugLog) {
        final clean = l.replaceAll(RegExp(r'[^\x20-\x7E가-힣ㄱ-ㅎㅏ-ㅣ]'), '');
        if (clean.trim().isNotEmpty) buf.writeln(clean);
      }
    }

    return buf.toString();
  }

  /// 디버그 정보를 파일로 저장 후 공유 (카카오톡/드라이브 등)
  Future<void> _shareDebugInfo(List<String> responses) async {
    final text = _buildDebugText(responses);

    try {
      // 캐시 디렉토리 사용 (공유 권한 문제 없음)
      final cacheDir = await getTemporaryDirectory();
      final ts = DateTime.now();
      final fileName = 'i70_debug_${ts.month.toString().padLeft(2, '0')}${ts.day.toString().padLeft(2, '0')}_${ts.hour.toString().padLeft(2, '0')}${ts.minute.toString().padLeft(2, '0')}.txt';
      final filePath = '${cacheDir.path}/$fileName';

      final file = File(filePath);
      await file.writeAsString(text, encoding: utf8);

      // Download에도 백업 저장
      try {
        final dlDir = Directory('/storage/emulated/0/Download');
        if (await dlDir.exists()) {
          await file.copy('${dlDir.path}/$fileName');
        }
      } catch (_) {}

      _showStatusMessage('저장 완료: $fileName', Colors.greenAccent);

      // 파일로 공유
      await Share.shareXFiles(
        [XFile(filePath, mimeType: 'text/plain')],
        subject: 'i70 디버그 정보',
      );
    } catch (e) {
      _showStatusMessage('파일 공유 실패: $e', Colors.orange);
      Share.share(text, subject: 'i70 디버그 정보');
    }
  }

  /// BT/NTRIP hex dump 로그 파일 공유
  Future<void> _shareLogFile() async {
    await _ntripService.flushLog();

    final files = <XFile>[];

    // 앱 내부 로그 (hex dump 포함)
    final internalPath = _ntripService.internalLogPath;
    if (internalPath != null && File(internalPath).existsSync()) {
      files.add(XFile(internalPath, mimeType: 'text/plain'));
    }

    // Download 폴더 로그
    final dlPath = _ntripService.logFilePath;
    if (dlPath != null && File(dlPath).existsSync() && dlPath != internalPath) {
      files.add(XFile(dlPath, mimeType: 'text/plain'));
    }

    if (files.isEmpty) {
      _showStatusMessage('로그 파일이 없습니다', Colors.orange);
      return;
    }

    try {
      await Share.shareXFiles(files, subject: 'BT/NTRIP 디버그 로그');
      _showStatusMessage('로그 파일 공유 (${files.length}개)', Colors.greenAccent);
    } catch (e) {
      _showStatusMessage('로그 공유 실패: $e', Colors.orange);
    }
  }

  /// GPS 연결 후 NTRIP 자동 연결 (5초 후)
  void _autoConnectNtrip() {
    debugPrint('[AUTO-NTRIP] 5초 후 NTRIP 연결 예약');
    Future.delayed(const Duration(seconds: 5), () async {
      if (!mounted) return;
      if (_gnssService.connectionState != GnssConnectionState.connected) {
        debugPrint('[AUTO-NTRIP] BT 미연결 - 재시도');
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted && _gnssService.connectionState == GnssConnectionState.connected) {
            _autoConnectNtrip();
          }
        });
        return;
      }

      var config = _ntripService.config;
      if (config == null || config.username.isEmpty) {
        config = const NtripConfig(
          host: 'rts1.ngii.go.kr',
          port: 2101,
          mountPoint: 'VRS-RTCM34',
          username: 'ysc7640',
          password: 'ngii',
        );
        await config.save();
      }

      _ntripService.connect(config);
      _showStatusMessage('NTRIP 연결 중...', Colors.cyanAccent);
    });
  }

  Future<void> _showBluetoothDeviceDialog() async {
    final devices = await _gnssService.getPairedDevices();

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '블루투스 GNSS 기기 선택',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (devices.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '페어링된 기기가 없습니다.\n설정에서 먼저 블루투스 페어링을 해주세요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54),
                  ),
                )
              else
                ...devices.map((device) => ListTile(
                      leading: const Icon(Icons.bluetooth, color: Colors.blue),
                      title: Text(
                        device.name ?? '알 수 없는 기기',
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Text(
                        device.address,
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _gnssService.connect(device);
                        // GPS 연결 후 NTRIP 자동 연결
                        _autoConnectNtrip();
                      },
                    )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }


  /// 영역 확대 적용
  /// 드래그 사각형의 중심을 DXF 좌표로 역변환 → 새 줌에서 그 DXF 좌표가 화면 중앙에 오도록 오프셋 계산
  void _applyZoomWindow() {
    if (_zoomWindowStart == null || _zoomWindowEnd == null || _dxfData == null) return;

    final left = _zoomWindowStart!.dx < _zoomWindowEnd!.dx ? _zoomWindowStart!.dx : _zoomWindowEnd!.dx;
    final top = _zoomWindowStart!.dy < _zoomWindowEnd!.dy ? _zoomWindowStart!.dy : _zoomWindowEnd!.dy;
    final right = _zoomWindowStart!.dx > _zoomWindowEnd!.dx ? _zoomWindowStart!.dx : _zoomWindowEnd!.dx;
    final bottom = _zoomWindowStart!.dy > _zoomWindowEnd!.dy ? _zoomWindowStart!.dy : _zoomWindowEnd!.dy;

    final windowWidth = right - left;
    final windowHeight = bottom - top;

    if (windowWidth < 10 || windowHeight < 10) {
      // 드래그 없이 클릭만 한 경우: 클릭 지점 중심으로 2배 확대
      _zoomAtPoint(_zoomWindowStart!, 2.0);
      setState(() {
        _zoomWindowStart = null;
        _zoomWindowEnd = null;
      });
      return;
    }

    // 현재 캔버스 크기 (LayoutBuilder 영역)
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    // _buildDxfView가 LayoutBuilder 안이므로, 실제 캔버스 크기를 구함
    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;
    if (dxfWidth <= 0 || dxfHeight <= 0) return;

    // 사각형 중심 (화면 좌표)을 DXF 좌표로 역변환 (현재 줌/오프셋 기준)
    final windowCenterX = (left + right) / 2;
    final windowCenterY = (top + bottom) / 2;

    // 새 줌 비율 계산: 드래그 영역이 캔버스를 채우도록
    // canvasSize는 LayoutBuilder constraints에서 나오는데, 여기서는 근사적으로 구함
    // _buildDxfView의 Expanded 내부이므로 실제 constraints를 사용할 수 없어 state로 저장
    final canvasSize = _lastCanvasSize;
    if (canvasSize == null) return;

    final scaleX = canvasSize.width * 0.9 / dxfWidth;
    final scaleY = canvasSize.height * 0.9 / dxfHeight;
    final baseScale = scaleX < scaleY ? scaleX : scaleY;
    final currentScale = baseScale * _zoom;

    final centerOffsetX = (canvasSize.width - dxfWidth * currentScale) / 2;
    final centerOffsetY = (canvasSize.height - dxfHeight * currentScale) / 2;

    // 화면 좌표 → DXF 좌표 역변환
    // screenX = (dxfX - minX) * scale + centerOffsetX + offset.dx
    // screenY = canvasH - ((dxfY - minY) * scale + centerOffsetY + offset.dy)
    // → dxfX = (screenX - centerOffsetX - offset.dx) / scale + minX
    // → dxfY = (canvasH - screenY - centerOffsetY - offset.dy) / scale + minY
    final dxfCenterX = (windowCenterX - centerOffsetX - _offset.dx) / currentScale + minX;
    final dxfCenterY = (canvasSize.height - windowCenterY - centerOffsetY - _offset.dy) / currentScale + minY;

    // 새 줌 = 캔버스를 드래그 영역으로 맞추는 비율
    final zoomRatioX = canvasSize.width / windowWidth;
    final zoomRatioY = canvasSize.height / windowHeight;
    final zoomRatio = (zoomRatioX < zoomRatioY ? zoomRatioX : zoomRatioY) * 0.9;
    final newZoom = _zoom * zoomRatio;

    // 새 줌에서의 scale
    final newScale = baseScale * newZoom;
    final newCenterOffsetX = (canvasSize.width - dxfWidth * newScale) / 2;
    final newCenterOffsetY = (canvasSize.height - dxfHeight * newScale) / 2;

    // DXF 중심점이 화면 중앙에 오도록 오프셋 계산
    // screenCenterX = (dxfCenterX - minX) * newScale + newCenterOffsetX + newOffsetDx
    // → newOffsetDx = screenCenterX - (dxfCenterX - minX) * newScale - newCenterOffsetX
    final screenCenterX = canvasSize.width / 2;
    final screenCenterY = canvasSize.height / 2;

    final newOffsetDx = screenCenterX - (dxfCenterX - minX) * newScale - newCenterOffsetX;
    // screenCenterY = canvasH - ((dxfCenterY - minY) * newScale + newCenterOffsetY + newOffsetDy)
    // → newOffsetDy = canvasH - screenCenterY - (dxfCenterY - minY) * newScale - newCenterOffsetY
    final newOffsetDy = canvasSize.height - screenCenterY - (dxfCenterY - minY) * newScale - newCenterOffsetY;

    setState(() {
      _zoom = newZoom;
      _offset = Offset(newOffsetDx, newOffsetDy);
      _zoomWindowStart = null;
      _zoomWindowEnd = null;
    });

    if (_lastCanvasSize != null) _syncNearestStation(_lastCanvasSize!);
  }

  /// 화면 중앙 기준으로 확대/축소
  void _zoomAtScreenCenter(double factor) {
    if (_dxfData == null || _lastCanvasSize == null) return;
    final canvasSize = _lastCanvasSize!;
    // 화면 중앙 좌표
    final centerX = canvasSize.width / 2;
    final centerY = canvasSize.height / 2;

    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;
    if (dxfWidth <= 0 || dxfHeight <= 0) return;

    final scaleX = canvasSize.width * 0.9 / dxfWidth;
    final scaleY = canvasSize.height * 0.9 / dxfHeight;
    final baseScale = scaleX < scaleY ? scaleX : scaleY;
    final oldScale = baseScale * _zoom;
    final newZoom = _zoom * factor;
    final newScale = baseScale * newZoom;

    // 화면 중앙의 DXF 좌표를 유지하도록 오프셋 조정
    final cOffX = (canvasSize.width - dxfWidth * oldScale) / 2;
    final cOffY = (canvasSize.height - dxfHeight * oldScale) / 2;
    final dxfX = (centerX - cOffX - _offset.dx) / oldScale + minX;
    final dxfY = (canvasSize.height - centerY - cOffY - _offset.dy) / oldScale + minY;

    final newCOffX = (canvasSize.width - dxfWidth * newScale) / 2;
    final newCOffY = (canvasSize.height - dxfHeight * newScale) / 2;
    final newOffsetDx = centerX - (dxfX - minX) * newScale - newCOffX;
    final newOffsetDy = canvasSize.height - centerY - (dxfY - minY) * newScale - newCOffY;

    setState(() {
      _zoom = newZoom;
      _offset = Offset(newOffsetDx, newOffsetDy);
    });


    _syncNearestStation(canvasSize);
  }

  /// 특정 화면 좌표 기준으로 확대/축소
  void _zoomAtPoint(Offset screenPoint, double factor) {
    if (_dxfData == null || _lastCanvasSize == null) return;
    final canvasSize = _lastCanvasSize!;

    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;
    if (dxfWidth <= 0 || dxfHeight <= 0) return;

    final scaleX = canvasSize.width * 0.9 / dxfWidth;
    final scaleY = canvasSize.height * 0.9 / dxfHeight;
    final baseScale = scaleX < scaleY ? scaleX : scaleY;
    final oldScale = baseScale * _zoom;
    final newZoom = _zoom * factor;
    final newScale = baseScale * newZoom;

    final cOffX = (canvasSize.width - dxfWidth * oldScale) / 2;
    final cOffY = (canvasSize.height - dxfHeight * oldScale) / 2;
    final dxfX = (screenPoint.dx - cOffX - _offset.dx) / oldScale + minX;
    final dxfY = (canvasSize.height - screenPoint.dy - cOffY - _offset.dy) / oldScale + minY;

    final newCOffX = (canvasSize.width - dxfWidth * newScale) / 2;
    final newCOffY = (canvasSize.height - dxfHeight * newScale) / 2;
    // 클릭 지점의 DXF 좌표가 화면 중앙에 오도록 오프셋 계산
    final centerX = canvasSize.width / 2;
    final centerY = canvasSize.height / 2;
    final newOffsetDx = centerX - (dxfX - minX) * newScale - newCOffX;
    final newOffsetDy = canvasSize.height - centerY - (dxfY - minY) * newScale - newCOffY;

    setState(() {
      _zoom = newZoom;
      _offset = Offset(newOffsetDx, newOffsetDy);
    });


    _syncNearestStation(canvasSize);
  }

  /// 치수 스냅 확정 처리 (1점/2점/3점 워크플로우)
  void _handleDimSnapConfirm() {
    if (_activeSnap == null) return;

    if (_activeDimType == DimensionType.angular) {
      // 각도 치수: 3점 워크플로우 (방향점1 → 꼭짓점 → 방향점2)
      if (_dimFirstPoint == null) {
        _dimFirstPoint = (
          type: _activeSnap!.type,
          dxfX: _activeSnap!.dxfX,
          dxfY: _activeSnap!.dxfY,
        );
      } else if (_dimSecondPoint == null) {
        _dimSecondPoint = (
          type: _activeSnap!.type,
          dxfX: _activeSnap!.dxfX,
          dxfY: _activeSnap!.dxfY,
        );
      } else {
        // 3점 확정 → 각도 계산 → 배치 대기
        final vx = _dimSecondPoint!.dxfX; // 꼭짓점
        final vy = _dimSecondPoint!.dxfY;
        final a1 = atan2(_dimFirstPoint!.dxfY - vy, _dimFirstPoint!.dxfX - vx);
        final a2 = atan2(_activeSnap!.dxfY - vy, _activeSnap!.dxfX - vx);
        double angleDeg = (a2 - a1) * 180.0 / pi;
        if (angleDeg < 0) angleDeg += 360;
        if (angleDeg > 180) angleDeg = 360 - angleDeg;

        _dimPending = (
          x1: _dimFirstPoint!.dxfX,
          y1: _dimFirstPoint!.dxfY,
          x2: _activeSnap!.dxfX,
          y2: _activeSnap!.dxfY,
          x3: vx,
          y3: vy,
          value: angleDeg,
          type: DimensionType.angular,
        );
        final midX = (vx + _dimFirstPoint!.dxfX + _activeSnap!.dxfX) / 3;
        final midY = (vy + _dimFirstPoint!.dxfY + _activeSnap!.dxfY) / 3;
        _dimPlacementDxf = Offset(midX, midY);
      }
    } else {
      // 2점 워크플로우 (정렬/수평/수직)
      if (_dimFirstPoint == null) {
        _dimFirstPoint = (
          type: _activeSnap!.type,
          dxfX: _activeSnap!.dxfX,
          dxfY: _activeSnap!.dxfY,
        );
      } else {
        final dx = _activeSnap!.dxfX - _dimFirstPoint!.dxfX;
        final dy = _activeSnap!.dxfY - _dimFirstPoint!.dxfY;

        double value;
        switch (_activeDimType) {
          case DimensionType.aligned:
            value = sqrt(dx * dx + dy * dy);
            break;
          case DimensionType.horizontal:
            value = dx.abs();
            break;
          case DimensionType.vertical:
            value = dy.abs();
            break;
          case DimensionType.angular:
            value = 0; // 여기 도달하지 않음
            break;
        }

        _dimPending = (
          x1: _dimFirstPoint!.dxfX,
          y1: _dimFirstPoint!.dxfY,
          x2: _activeSnap!.dxfX,
          y2: _activeSnap!.dxfY,
          x3: null,
          y3: null,
          value: value,
          type: _activeDimType,
        );
        final midX = (_dimFirstPoint!.dxfX + _activeSnap!.dxfX) / 2;
        final midY = (_dimFirstPoint!.dxfY + _activeSnap!.dxfY) / 2;
        _dimPlacementDxf = Offset(midX, midY);
      }
    }
  }

  /// 치수 삭제
  void _deleteDimension(int index) {
    setState(() {
      _dimResults.removeAt(index);
      if (_selectedDimIndex == index) _selectedDimIndex = null;
      if (_selectedDimIndex != null && _selectedDimIndex! > index) {
        _selectedDimIndex = _selectedDimIndex! - 1;
      }
    });
  }



  /// 치수 타입 선택 메뉴
  void _showDimTypeMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dimTypeMenuItem(ctx, DimensionType.aligned, Icons.straighten, '정렬(사선) 치수'),
            _dimTypeMenuItem(ctx, DimensionType.horizontal, Icons.swap_horiz, '수평 치수'),
            _dimTypeMenuItem(ctx, DimensionType.vertical, Icons.swap_vert, '수직 치수'),
            _dimTypeMenuItem(ctx, DimensionType.angular, Icons.architecture, '각도 치수'),
          ],
        ),
      ),
    );
  }

  Widget _dimTypeMenuItem(BuildContext ctx, DimensionType type, IconData icon, String label) {
    final isSelected = _activeDimType == type;
    return ListTile(
      leading: Icon(icon, color: isSelected ? Colors.cyan : Colors.white70),
      title: Text(label, style: TextStyle(color: isSelected ? Colors.cyan : Colors.white)),
      selected: isSelected,
      onTap: () {
        setState(() => _activeDimType = type);
        Navigator.pop(ctx);
      },
    );
  }

  /// 치수 타입별 아이콘
  IconData _getDimTypeIcon(DimensionType type) {
    switch (type) {
      case DimensionType.aligned:
        return Icons.straighten;
      case DimensionType.horizontal:
        return Icons.swap_horiz;
      case DimensionType.vertical:
        return Icons.swap_vert;
      case DimensionType.angular:
        return Icons.architecture;
    }
  }

  /// 치수 타입별 라벨
  String _getDimTypeLabel(DimensionType type) {
    switch (type) {
      case DimensionType.aligned:
        return '정렬';
      case DimensionType.horizontal:
        return '수평';
      case DimensionType.vertical:
        return '수직';
      case DimensionType.angular:
        return '각도';
    }
  }

  /// 샘플 DXF 파일 로드
  Future<void> _loadSampleDxf() async {
    setState(() => _isLoading = true);

    try {
      final byteData = await rootBundle.load('assets/sample_data/거정천.dxf');
      final rawBytes = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);
      final rawContent = DxfService.decodeDxfBytes(rawBytes);
      debugPrint('[DXF Load] codepage=${DxfService.isCP949(rawBytes) ? "CP949" : "other"}, bytes=${rawBytes.length}');
      final data = DxfService.parseDxfContent(rawContent);

      if (data != null) {
        data['_originalEntityCount'] = (data['entities'] as List).length;
        setState(() {
          _dxfData = data;
          _originalDxfBytes = rawBytes;
          _isLoading = false;
          _hiddenLayers.clear();
          _applyDefaultHiddenLayers();
          _dimResults.clear();
          _dimFirstPoint = null;
          _dimSecondPoint = null;
          _dimPending = null;
          _dimPlacementDxf = null;
          _isDimensionMode = false;
          _selectedDimIndex = null;
          _showDimPanel = false;
          _showDimStylePanel = false;
          _confirmedPoints.clear();
          _isPointMode = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[DXF Viewer] 로드 오류: $e');
      setState(() => _isLoading = false);
    }
  }

  /// DXF 로드 시 기본 비표시 레이어 적용
  void _applyDefaultHiddenLayers() {
    if (_dxfData == null) return;
    final layers = (_dxfData!['layers'] as List).cast<String>();
    for (final dl in _defaultHiddenLayers) {
      if (layers.contains(dl)) _hiddenLayers.add(dl);
    }
  }

  /// 파일에서 DXF 열기
  Future<void> _openDxfFile() async {
    try {
      final filePath = await DxfService.pickDxfFile();

      if (filePath != null) {
        setState(() => _isLoading = true);

        final rawBytes = await File(filePath).readAsBytes();
        final rawContent = DxfService.decodeDxfBytes(rawBytes);
        final data = DxfService.parseDxfContent(rawContent);

        if (data != null) {
          data['_originalEntityCount'] = (data['entities'] as List).length;
          setState(() {
            _dxfData = data;
            _originalDxfBytes = rawBytes;
            _isLoading = false;
            _zoom = 1.0;
            _offset = Offset.zero;
            _selectedStation = null;
            _hiddenLayers.clear();
            _applyDefaultHiddenLayers();
            _showLayerPanel = false;
            _dimResults.clear();
            _dimFirstPoint = null;
            _dimSecondPoint = null;
            _dimPending = null;
            _dimPlacementDxf = null;
            _isDimensionMode = false;
            _selectedDimIndex = null;
            _showDimPanel = false;
            _showDimStylePanel = false;
            _confirmedPoints.clear();
            _isPointMode = false;
          });
        } else {
          setState(() => _isLoading = false);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('DXF 파일을 불러올 수 없습니다')),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('[DXF Viewer] 파일 열기 오류: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류: $e')),
        );
      }
    }
  }

  /// 화면 중앙에서 가장 가까운 측점으로 선택 상태 동기화
  void _syncNearestStation(Size canvasSize) {
    if (_dxfData == null || _baseStationsWithCoords.isEmpty) return;

    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfW = maxX - minX;
    final dxfH = maxY - minY;
    if (dxfW <= 0 || dxfH <= 0) return;

    final sX = canvasSize.width * 0.9 / dxfW;
    final sY = canvasSize.height * 0.9 / dxfH;
    final baseScale = sX < sY ? sX : sY;
    final scale = baseScale * _zoom;
    final cOffX = (canvasSize.width - dxfW * scale) / 2;
    final cOffY = (canvasSize.height - dxfH * scale) / 2;

    // 화면 중앙 → DXF 좌표
    final centerX = canvasSize.width / 2;
    final centerY = canvasSize.height / 2;
    final dxfX = (centerX - cOffX - _offset.dx) / scale + minX;
    final dxfY = (canvasSize.height - centerY - cOffY - _offset.dy) / scale + minY;

    // 가장 가까운 측점 찾기
    StationData? nearest;
    double minDist = double.infinity;
    for (final s in _baseStationsWithCoords) {
      final dx = s.x! - dxfX;
      final dy = s.y! - dxfY;
      final d = dx * dx + dy * dy;
      if (d < minDist) {
        minDist = d;
        nearest = s;
      }
    }

    if (nearest != null && nearest.no != _selectedStation?.no) {
      setState(() => _selectedStation = nearest);
    }
  }

  /// 선택된 측점의 DXF 좌표로 뷰 이동
  void _goToStation(StationData station) {
    if (_dxfData == null || station.x == null || station.y == null) return;

    // 패널 닫기 + 선택 상태 먼저 반영
    setState(() {
      _selectedStation = station;
      _showStationPanel = false;
    });

    // 레이아웃 갱신 후 실제 캔버스 크기로 오프셋 계산
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final canvasSize = _lastCanvasSize;
      if (canvasSize == null) return;

      final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
      final minX = bounds['minX'] as double;
      final minY = bounds['minY'] as double;
      final maxX = bounds['maxX'] as double;
      final maxY = bounds['maxY'] as double;
      final dxfWidth = maxX - minX;
      final dxfHeight = maxY - minY;
      if (dxfWidth <= 0 || dxfHeight <= 0) return;

      final scaleX = canvasSize.width * 0.9 / dxfWidth;
      final scaleY = canvasSize.height * 0.9 / dxfHeight;
      final baseScale = scaleX < scaleY ? scaleX : scaleY;

      final newZoom = _stationZoomLevel;
      final scale = baseScale * newZoom;

      final centerOffsetX = (canvasSize.width - dxfWidth * scale) / 2;
      final centerOffsetY = (canvasSize.height - dxfHeight * scale) / 2;

      // 측점 DXF 좌표가 화면 중앙에 오도록 오프셋 계산
      final screenCenterX = canvasSize.width / 2;
      final screenCenterY = canvasSize.height / 2;
      final newOffsetDx = screenCenterX - (station.x! - minX) * scale - centerOffsetX;
      final newOffsetDy = canvasSize.height - screenCenterY - (station.y! - minY) * scale - centerOffsetY;

      setState(() {
        _zoom = newZoom;
        _offset = Offset(newOffsetDx, newOffsetDy);
      });
  
    });
  }

  /// 현재 DXF 좌표 → 화면 좌표 변환 함수 생성
  /// DxfPainter.transformPoint 와 동일한 로직
  Offset Function(double, double)? _getTransformPoint(Size canvasSize) {
    if (_dxfData == null) return null;
    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;
    if (dxfWidth <= 0 || dxfHeight <= 0) return null;

    final scaleX = canvasSize.width * 0.9 / dxfWidth;
    final scaleY = canvasSize.height * 0.9 / dxfHeight;
    final baseScale = scaleX < scaleY ? scaleX : scaleY;
    final scale = baseScale * _zoom;
    final centerOffsetX = (canvasSize.width - dxfWidth * scale) / 2;
    final centerOffsetY = (canvasSize.height - dxfHeight * scale) / 2;

    return (double x, double y) {
      final screenX = (x - minX) * scale + centerOffsetX + _offset.dx;
      final screenY = canvasSize.height -
          ((y - minY) * scale + centerOffsetY + _offset.dy);
      return Offset(screenX, screenY);
    };
  }

  /// 현재 스케일(baseScale * zoom) 계산
  double _getCurrentScale(Size canvasSize) {
    if (_dxfData == null) return 1.0;
    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;
    if (dxfWidth <= 0 || dxfHeight <= 0) return 1.0;

    final scaleX = canvasSize.width * 0.9 / dxfWidth;
    final scaleY = canvasSize.height * 0.9 / dxfHeight;
    final baseScale = scaleX < scaleY ? scaleX : scaleY;
    return baseScale * _zoom;
  }

  /// 포인트/치수 모드에서 터치 시 스냅 계산
  void _handlePointTouch(Offset touchPoint, Size canvasSize) {
    final transformPoint = _getTransformPoint(canvasSize);
    if (transformPoint == null || _dxfData == null) return;

    // 우측 가장자리 자동 패닝: 터치가 화면 우측 60px 이내이면 뷰를 좌측으로 1회 이동
    const edgeThreshold = 60.0;
    if (!_edgePanDone && touchPoint.dx > canvasSize.width - edgeThreshold) {
      final panAmount = canvasSize.width / 10;
      _offset = Offset(_offset.dx - panAmount, _offset.dy);
      _edgePanDone = true;
    }

    final cursorTip = SnapOverlayPainter.getCursorTip(touchPoint);
    final scale = _getCurrentScale(canvasSize);

    final result = SnapService.findSnap(
      cursorTip: cursorTip,
      entities: _dxfData!['entities'] as List,
      hiddenLayers: Set.of(_hiddenLayers),
      transformPoint: transformPoint,
      inverseTransform: transformPoint,
      scale: scale,
      zoom: _zoom,
    );

    // 커서 팁의 DXF 좌표 계산 (확대 원용)
    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfW = maxX - minX;
    final dxfH = maxY - minY;
    final sX = canvasSize.width * 0.9 / dxfW;
    final sY = canvasSize.height * 0.9 / dxfH;
    final baseScale = sX < sY ? sX : sY;
    final currentScale = baseScale * _zoom;
    final cOffX = (canvasSize.width - dxfW * currentScale) / 2;
    final cOffY = (canvasSize.height - dxfH * currentScale) / 2;
    final tipDxfX = (cursorTip.dx - cOffX - _offset.dx) / currentScale + minX;
    final tipDxfY = (canvasSize.height - cursorTip.dy - cOffY - _offset.dy) / currentScale + minY;

    setState(() {
      _touchPoint = touchPoint;
      _highlightEntity = result.entity;
      _activeSnap = result.snap;
      _cursorTipDxf = Offset(tipDxfX, tipDxfY);
      _cursorTipScreen = cursorTip;
    });
  }

  /// 치수 배치 단계: 터치 위치를 DXF 좌표로 변환하여 치수선 위치 결정
  void _handleDimPlacement(Offset touchPoint, Size canvasSize) {
    if (_dxfData == null || _dimPending == null) return;

    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfW = maxX - minX;
    final dxfH = maxY - minY;
    final sX = canvasSize.width * 0.9 / dxfW;
    final sY = canvasSize.height * 0.9 / dxfH;
    final baseScale = sX < sY ? sX : sY;
    final currentScale = baseScale * _zoom;
    final cOffX = (canvasSize.width - dxfW * currentScale) / 2;
    final cOffY = (canvasSize.height - dxfH * currentScale) / 2;
    final dxfX = (touchPoint.dx - cOffX - _offset.dx) / currentScale + minX;
    final dxfY = (canvasSize.height - touchPoint.dy - cOffY - _offset.dy) / currentScale + minY;

    setState(() {
      _dimPlacementDxf = Offset(dxfX, dxfY);

      // 각도 치수는 자동 감지 안 함
      if (_dimPending!.type != DimensionType.angular) {
        final p = _dimPending!;
        // 두 측정점의 중점에서 배치점까지의 변위
        final midX = (p.x1 + p.x2) / 2;
        final midY = (p.y1 + p.y2) / 2;
        final dispX = (dxfX - midX).abs();
        final dispY = (dxfY - midY).abs();
        // 두 측정점 간 변위
        final lineDx = (p.x2 - p.x1).abs();
        final lineDy = (p.y2 - p.y1).abs();

        DimensionType autoType;
        // 측정선이 거의 수평(lineDy 작음)이면: 위/아래 드래그 → 수평치수, 좌/우 드래그 → 수직치수
        // 측정선이 거의 수직(lineDx 작음)이면: 좌/우 드래그 → 수직치수, 위/아래 드래그 → 수평치수
        // 사선인 경우: 배치 방향에 따라 결정
        if (lineDx < 0.001 && lineDy < 0.001) {
          autoType = DimensionType.aligned;
        } else {
          // 측정선 각도 (0=수평, 90=수직)
          final lineAngle = atan2(lineDy, lineDx);
          // 배치점이 측정선에 대해 수직 방향으로 얼마나 벗어났는지
          // 측정선 방향 단위벡터
          final len = sqrt(lineDx * lineDx + lineDy * lineDy);
          final ux = (p.x2 - p.x1) / len;
          final uy = (p.y2 - p.y1) / len;
          // 배치점-중점 벡터를 측정선 방향/수직 방향으로 분해
          final toPlaceX = dxfX - midX;
          final toPlaceY = dxfY - midY;
          final parallel = (toPlaceX * ux + toPlaceY * uy).abs();
          final perp = (toPlaceX * (-uy) + toPlaceY * ux).abs();

          if (lineAngle < 0.3) {
            // 거의 수평 측정선 → 대부분 수평치수, 매우 수평 드래그시 수직치수
            autoType = dispY > dispX * 0.3 ? DimensionType.horizontal : DimensionType.vertical;
          } else if (lineAngle > 1.27) {
            // 거의 수직 측정선 → 대부분 수직치수, 매우 수직 드래그시 수평치수
            autoType = dispX > dispY * 0.3 ? DimensionType.vertical : DimensionType.horizontal;
          } else {
            // 사선 → 수직 방향 벗어남이 크면 정렬, 아니면 방향에 따라
            if (perp > parallel * 0.7) {
              autoType = DimensionType.aligned;
            } else if (dispY > dispX) {
              autoType = DimensionType.horizontal;
            } else {
              autoType = DimensionType.vertical;
            }
          }
        }

        // 타입이 변경되면 값도 재계산
        if (autoType != p.type) {
          final dx = p.x2 - p.x1;
          final dy = p.y2 - p.y1;
          double value;
          switch (autoType) {
            case DimensionType.aligned:
              value = sqrt(dx * dx + dy * dy);
              break;
            case DimensionType.horizontal:
              value = dx.abs();
              break;
            case DimensionType.vertical:
              value = dy.abs();
              break;
            case DimensionType.angular:
              value = p.value;
              break;
          }
          _dimPending = (
            x1: p.x1, y1: p.y1, x2: p.x2, y2: p.y2,
            x3: p.x3, y3: p.y3,
            value: value, type: autoType,
          );
          _activeDimType = autoType;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // 줌 배율 프리뷰 모드
    if (_zoomPreviewMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            _buildDxfView(),
            // 상단 라벨
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$_previewLabel  x${_previewZoom.toInt()}',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
            // 나가기 버튼
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 24,
              right: 24,
              child: FloatingActionButton(
                heroTag: 'exitPreview',
                onPressed: _exitZoomPreview,
                backgroundColor: Colors.red[700],
                child: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('DXF 도면'),
        actions: [
          // Undo
          IconButton(
            icon: Icon(Icons.undo, color: _undoStack.isNotEmpty ? Colors.white : Colors.white24),
            onPressed: _undoStack.isNotEmpty ? _undo : null,
            tooltip: '실행취소',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36),
          ),
          // Redo
          IconButton(
            icon: Icon(Icons.redo, color: _redoStack.isNotEmpty ? Colors.white : Colors.white24),
            onPressed: _redoStack.isNotEmpty ? _redo : null,
            tooltip: '다시실행',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36),
          ),
          // GPS / NTRIP 메뉴 버튼
          Stack(
            alignment: Alignment.center,
            children: [
              IconButton(
                icon: Icon(
                  _gnssService.connectionState == GnssConnectionState.connected
                      ? Icons.gps_fixed
                      : Icons.gps_off,
                  color: _getGpsIconColor(),
                ),
                onPressed: _showGpsMenu,
              ),
              // NTRIP 연결됨 표시 (GPS 아이콘 우측 상단에 녹색 점)
              if (_ntripService.isConnected)
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Colors.greenAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
          IconButton(
            icon: Icon(
              Icons.zoom_in,
              color: _isZoomWindowMode ? Colors.blue : null,
            ),
            onPressed: () {
              setState(() {
                _isZoomWindowMode = !_isZoomWindowMode;
                _zoomWindowStart = null;
                _zoomWindowEnd = null;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.zoom_out),
            onPressed: () => _zoomAtScreenCenter(1 / 1.5),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {
                _zoom = 1.0;
                _offset = Offset.zero;
                _selectedStation = null;
              });
          
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _dxfData != null
              ? Column(
                  children: [
                    Expanded(child: _buildDxfView()),
                    _buildBottomBar(),
                  ],
                )
              : const Center(child: Text('DXF 파일을 불러올 수 없습니다')),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _dxfData != null
          ? Padding(
              padding: const EdgeInsets.only(bottom: 80),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // GPS 자동 중앙 정렬 토글 (GPS 연결 시만 표시)
                  if (_gnssService.connectionState == GnssConnectionState.connected)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FloatingActionButton.small(
                        heroTag: 'gpsAutoCenter',
                        onPressed: () {
                          setState(() {
                            _gpsAutoCenter = !_gpsAutoCenter;
                            if (_gpsAutoCenter) {
                              _startGpsCenterTimer();
                            } else {
                              _stopGpsCenterTimer();
                            }
                          });
                        },
                        backgroundColor: _gpsAutoCenter ? Colors.green : Colors.grey[700],
                        child: Icon(
                          _gpsAutoCenter ? Icons.my_location : Icons.location_disabled,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  // 측설 종료 버튼 (측설 활성 시만 표시)
                  if (_stakeoutTarget != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: FloatingActionButton.small(
                        heroTag: 'stakeoutExit',
                        onPressed: () {
                          setState(() => _exitStakeout());
                        },
                        backgroundColor: Colors.red[700],
                        child: const Icon(Icons.close, color: Colors.white, size: 20),
                      ),
                    ),
                  // 포인트 지정 버튼 (치수 모드 아닐 때)
                  if (!_isDimensionMode)
                    FloatingActionButton(
                      heroTag: 'pointMode',
                      onPressed: () {
                        setState(() {
                          _isPointMode = !_isPointMode;
                          if (!_isPointMode) {
                            _touchPoint = null;
                            _activeSnap = null;
                            _highlightEntity = null;
                          }
                        });
                      },
                      backgroundColor: _isPointMode ? Colors.cyan : Colors.grey[800],
                      child: Icon(
                        Icons.control_point,
                        color: _isPointMode ? Colors.black : Colors.white70,
                      ),
                    ),
                ],
              ),
            )
          : null,
    );
  }

  // 측점 패널 표시 여부
  bool _showStationPanel = false;

  /// "NO.12" → "12" 로 표시
  String _shortStationNo(String no) {
    final match = RegExp(r'^NO\.(\d+)', caseSensitive: false).firstMatch(no);
    if (match != null) return match.group(1)!;
    return no;
  }

  /// 좌표 있는 기본 측점만 (NO.xx만, 플러스 체인 제외)
  List<StationData> get _baseStationsWithCoords =>
      _stationsWithCoords.where((s) => s.isBaseStation).toList();


  // ===== Undo/Redo =====

  void _pushUndo(_UndoAction action) {
    _undoStack.add(action);
    if (_undoStack.length > _maxUndoSteps) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    final action = _undoStack.removeLast();
    setState(() {
      switch (action.type) {
        case _UndoType.addUserEntity:
          final entity = action.data as Map<String, dynamic>;
          _userEntities.remove(entity);
          _redoStack.add(action);
          break;
        case _UndoType.addDimension:
          final dim = action.data as DimensionResult;
          _dimResults.remove(dim);
          _redoStack.add(action);
          break;
        case _UndoType.addPoint:
          final pt = action.data as ({SnapType type, double dxfX, double dxfY});
          _confirmedPoints.remove(pt);
          // 측설 타겟도 해제
          if (_stakeoutTarget != null &&
              _stakeoutTarget!.dxfX == pt.dxfX && _stakeoutTarget!.dxfY == pt.dxfY) {
            _stakeoutTarget = null;
            _beepService.stop();
          }
          _redoStack.add(action);
          break;
        case _UndoType.deleteEntity:
          // data = {'entity': Map, 'source': 'user'|'dxf', 'index': int?}
          final info = action.data as Map<String, dynamic>;
          final entity = info['entity'] as Map<String, dynamic>;
          if (info['source'] == 'user') {
            _userEntities.add(entity);
          } else {
            final entities = _dxfData?['entities'] as List?;
            entities?.add(entity);
            _dxfRepaintVersion++;
          }
          _redoStack.add(action);
          break;
        case _UndoType.changeProperty:
          // data = {'entity': Map, 'field': String, 'oldValue': dynamic, 'newValue': dynamic}
          final info = action.data as Map<String, dynamic>;
          final entity = info['entity'] as Map<String, dynamic>;
          entity[info['field']] = info['oldValue'];
          _dxfRepaintVersion++;
          _redoStack.add(action);
          break;
      }
    });
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    final action = _redoStack.removeLast();
    setState(() {
      switch (action.type) {
        case _UndoType.addUserEntity:
          _userEntities.add(action.data as Map<String, dynamic>);
          _undoStack.add(action);
          break;
        case _UndoType.addDimension:
          _dimResults.add(action.data as DimensionResult);
          _undoStack.add(action);
          break;
        case _UndoType.addPoint:
          _confirmedPoints.add(action.data as ({SnapType type, double dxfX, double dxfY}));
          _undoStack.add(action);
          break;
        case _UndoType.deleteEntity:
          final info = action.data as Map<String, dynamic>;
          final entity = info['entity'] as Map<String, dynamic>;
          if (info['source'] == 'user') {
            _userEntities.remove(entity);
          } else {
            (_dxfData?['entities'] as List?)?.remove(entity);
            _dxfRepaintVersion++;
          }
          _undoStack.add(action);
          break;
        case _UndoType.changeProperty:
          final info = action.data as Map<String, dynamic>;
          final entity = info['entity'] as Map<String, dynamic>;
          entity[info['field']] = info['newValue'];
          _dxfRepaintVersion++;
          _undoStack.add(action);
          break;
      }
    });
  }

  // ===== 그리기/선택 모드 메서드 =====

  /// 화면 좌표 → DXF 좌표
  ({double x, double y})? _screenToDxf(Offset screenPt, Size canvasSize) {
    if (_dxfData == null) return null;
    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final dxfW = (bounds['maxX'] as double) - minX;
    final dxfH = (bounds['maxY'] as double) - minY;
    if (dxfW <= 0 || dxfH <= 0) return null;
    final sX = canvasSize.width * 0.9 / dxfW;
    final sY = canvasSize.height * 0.9 / dxfH;
    final baseScale = sX < sY ? sX : sY;
    final scale = baseScale * _zoom;
    final cOffX = (canvasSize.width - dxfW * scale) / 2;
    final cOffY = (canvasSize.height - dxfH * scale) / 2;
    final dxfX = (screenPt.dx - cOffX - _offset.dx) / scale + minX;
    final dxfY = (canvasSize.height - screenPt.dy - cOffY - _offset.dy) / scale + minY;
    return (x: dxfX, y: dxfY);
  }

  /// 그리기 모드 터치 처리 (onScaleStart/Update에서 호출)
  void _handleDrawTouch(Offset touchPoint, Size canvasSize) {
    if (_activeDrawMode == null) return;
    final dxf = _screenToDxf(touchPoint, canvasSize);
    if (dxf == null) return;

    // 스냅 활용 (있으면)
    final transformPoint = _getTransformPoint(canvasSize);
    if (transformPoint == null) return;
    final scale = _getCurrentScale(canvasSize);
    final cursorTip = SnapOverlayPainter.getCursorTip(touchPoint);
    final snap = SnapService.findSnap(
      cursorTip: cursorTip,
      entities: (_dxfData!['entities'] as List) + _userEntities,
      hiddenLayers: Set.of(_hiddenLayers),
      transformPoint: transformPoint,
      inverseTransform: transformPoint,
      scale: scale,
      zoom: _zoom,
    );

    setState(() {
      _touchPoint = touchPoint;
      _activeSnap = snap.snap;
      _highlightEntity = snap.entity;
      if (snap.snap != null) {
        _cursorTipDxf = Offset(snap.snap!.dxfX, snap.snap!.dxfY);
      } else {
        _cursorTipDxf = Offset(dxf.x, dxf.y);
      }
    });
  }

  /// 그리기 모드 확정 (onScaleEnd에서 호출)
  void _handleDrawConfirm(Size canvasSize) {
    final dxfPt = _activeSnap != null
        ? (x: _activeSnap!.dxfX, y: _activeSnap!.dxfY)
        : (_cursorTipDxf != null ? (x: _cursorTipDxf!.dx, y: _cursorTipDxf!.dy) : null);
    if (dxfPt == null) {
      setState(() {
        _touchPoint = null;
        _activeSnap = null;
        _highlightEntity = null;
        _cursorTipDxf = null;
      });
      return;
    }

    setState(() {
      switch (_activeDrawMode) {
        case 'point':
          final pointEntity = {
            'type': 'POINT',
            'x': dxfPt.x,
            'y': dxfPt.y,
            'color': _drawColor,
            'lw': _drawLineWidth,
            'pdmode': _drawPointStyle,
            'layer': '_USER',
          };
          _userEntities.add(pointEntity);
          _pushUndo(_UndoAction(_UndoType.addUserEntity, pointEntity));
          _activeDrawMode = null;
          break;
        case 'line':
          if (_drawFirstPoint == null) {
            _drawFirstPoint = (dxfX: dxfPt.x, dxfY: dxfPt.y);
          } else {
            final lineEntity = {
              'type': 'LINE',
              'x1': _drawFirstPoint!.dxfX,
              'y1': _drawFirstPoint!.dxfY,
              'x2': dxfPt.x,
              'y2': dxfPt.y,
              'color': _drawColor,
              'lw': _drawLineWidth,
              'layer': '_USER',
            };
            _userEntities.add(lineEntity);
            _pushUndo(_UndoAction(_UndoType.addUserEntity, lineEntity));
            _drawFirstPoint = null;
            _activeDrawMode = null;
          }
          break;
        case 'leader':
          _leaderPoints.add({'x': dxfPt.x, 'y': dxfPt.y});
          if (_leaderPoints.length >= 2) {
            // 지시선 2점 이상이면 텍스트 입력 다이얼로그
            _showLeaderTextDialog();
          }
          break;
        case 'text':
          _showTextInputDialog(dxfPt.x, dxfPt.y);
          break;
      }
      _touchPoint = null;
      _activeSnap = null;
      _highlightEntity = null;
      _cursorTipDxf = null;
    });
  }

  /// 지시선 텍스트 입력 다이얼로그
  void _showLeaderTextDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('지시선 텍스트'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '텍스트 입력 (빈칸 가능)'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                final leaderEntity = {
                  'type': 'LEADER',
                  'points': List<Map<String, double>>.from(_leaderPoints),
                  'text': controller.text,
                  'color': _drawColor,
                  'lw': _drawLineWidth,
                  'layer': '_USER',
                };
                _userEntities.add(leaderEntity);
                _pushUndo(_UndoAction(_UndoType.addUserEntity, leaderEntity));
                _leaderPoints = [];
                _activeDrawMode = null;
              });
            },
            child: const Text('확인'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                _leaderPoints = [];
                _activeDrawMode = null;
              });
            },
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }

  /// 텍스트 입력 다이얼로그
  void _showTextInputDialog(double dxfX, double dxfY) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('텍스트 입력'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '텍스트 내용'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() {
                if (controller.text.isNotEmpty) {
                  final textEntity = {
                    'type': 'TEXT',
                    'x': dxfX,
                    'y': dxfY,
                    'text': controller.text,
                    'fontSize': _drawTextSize,
                    'color': _drawColor,
                    'layer': '_USER',
                  };
                  _userEntities.add(textEntity);
                  _pushUndo(_UndoAction(_UndoType.addUserEntity, textEntity));
                }
                _activeDrawMode = null;
              });
            },
            child: const Text('확인'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _activeDrawMode = null);
            },
            child: const Text('취소'),
          ),
        ],
      ),
    );
  }

  /// 선택 모드별 아이콘
  IconData _getSelectModeIcon() {
    switch (_selectModeType) {
      case 'multi': return Icons.checklist;
      case 'area': return Icons.crop_square;
      case 'fence': return Icons.polyline;
      default: return Icons.touch_app;
    }
  }

  /// 선택 모드 메뉴 (롱프레스)
  void _showSelectModeMenu() {
    final modes = [
      ('single', Icons.touch_app, '단일 선택', '하나씩 선택/해제'),
      ('multi', Icons.checklist, '다중 선택', '탭할 때마다 추가, 속성창 수동'),
      ('area', Icons.crop_square, '영역 선택', '사각 영역 안의 엔티티 선택'),
      ('fence', Icons.polyline, '펜스 선택', '다각형에 걸치는 엔티티 선택'),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('선택 모드', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
            ),
            ...modes.map((m) => ListTile(
              leading: Icon(m.$2, color: _selectModeType == m.$1 ? Colors.cyan : Colors.white54),
              title: Text(m.$3, style: TextStyle(color: _selectModeType == m.$1 ? Colors.cyan : Colors.white)),
              subtitle: Text(m.$4, style: const TextStyle(color: Colors.white38, fontSize: 11)),
              trailing: _selectModeType == m.$1 ? const Icon(Icons.check, color: Colors.cyan, size: 18) : null,
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _selectModeType = m.$1;
                  _isSelectMode = true;
                  _activeDrawMode = null;
                  _isPointMode = false;
                  _isDimensionMode = false;
                  _selectedEntities.clear();
                  _showPropertyPanel = false;
                  _areaSelectStart = null;
                  _areaSelectEnd = null;
                  _fencePoints.clear();
                });
              },
            )),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// 엔티티 선택 처리
  void _handleSelectTouch(Offset touchPoint, Size canvasSize) {
    final transformPoint = _getTransformPoint(canvasSize);
    if (transformPoint == null || _dxfData == null) return;
    final scale = _getCurrentScale(canvasSize);
    final cursorTip = SnapOverlayPainter.getCursorTip(touchPoint);

    // DXF 엔티티 + 사용자 엔티티 모두 검색
    final allEntities = [...(_dxfData!['entities'] as List), ..._userEntities];
    final snap = SnapService.findSnap(
      cursorTip: cursorTip,
      entities: allEntities,
      hiddenLayers: Set.of(_hiddenLayers),
      transformPoint: transformPoint,
      inverseTransform: transformPoint,
      scale: scale,
      zoom: _zoom,
    );

    // snap으로 못 찾은 사용자 LEADER 엔티티도 거리 기반 검색
    Map<String, dynamic>? found = snap.entity;
    if (found == null) {
      final dxf = _screenToDxf(cursorTip, canvasSize);
      if (dxf != null) {
        double bestDist = 30.0 / scale; // 화면 30px 톨러런스
        for (final ue in _userEntities) {
          if (ue['type'] == 'LEADER') {
            final pts = ue['points'] as List<Map<String, double>>;
            for (int i = 0; i < pts.length - 1; i++) {
              final d = _distToSegment(dxf.x, dxf.y, pts[i]['x']!, pts[i]['y']!, pts[i + 1]['x']!, pts[i + 1]['y']!);
              if (d < bestDist) {
                bestDist = d;
                found = ue;
              }
            }
          } else if (ue['type'] == 'TEXT') {
            final dx = dxf.x - (ue['x'] as double);
            final dy = dxf.y - (ue['y'] as double);
            final d = sqrt(dx * dx + dy * dy);
            if (d < bestDist) {
              bestDist = d;
              found = ue;
            }
          }
        }
      }
    }

    // 기초라인 근접 측점 검색용 DXF 좌표 저장
    final dxfPt = _screenToDxf(cursorTip, canvasSize);

    setState(() {
      _touchPoint = touchPoint;
      _activeSnap = snap.snap;
      _highlightEntity = found;
      if (dxfPt != null) _lastSelectDxfPoint = dxfPt;
    });
  }

  /// 점에서 선분까지의 거리
  double _distToSegment(double px, double py, double x1, double y1, double x2, double y2) {
    final dx = x2 - x1, dy = y2 - y1;
    final lenSq = dx * dx + dy * dy;
    if (lenSq < 1e-10) return sqrt((px - x1) * (px - x1) + (py - y1) * (py - y1));
    final t = ((px - x1) * dx + (py - y1) * dy) / lenSq;
    final ct = t.clamp(0.0, 1.0);
    final nx = x1 + ct * dx, ny = y1 + ct * dy;
    return sqrt((px - nx) * (px - nx) + (py - ny) * (py - ny));
  }

  /// 엔티티 선택 확정
  void _handleSelectConfirm() {
    switch (_selectModeType) {
      case 'single':
        _handleSingleSelectConfirm();
        break;
      case 'multi':
        _handleMultiSelectConfirm();
        break;
      case 'area':
        _handleAreaSelectConfirm();
        break;
      case 'fence':
        _handleFenceSelectConfirm();
        break;
    }
  }

  /// 단일 선택 확정 (기존 동작)
  void _handleSingleSelectConfirm() {
    setState(() {
      if (_highlightEntity != null) {
        final idx = _selectedEntities.indexOf(_highlightEntity!);
        if (idx >= 0) {
          _selectedEntities.removeAt(idx);
        } else {
          // 단일 선택: 기존 선택 해제 후 새로 선택
          _selectedEntities.clear();
          _selectedEntities.add(_highlightEntity!);
        }
        _showPropertyPanel = _selectedEntities.isNotEmpty;
      }
      _touchPoint = null;
      _activeSnap = null;
      _highlightEntity = null;
    });
  }

  /// 다중 선택 확정 (추가/해제 토글, 속성창 안 뜸)
  void _handleMultiSelectConfirm() {
    setState(() {
      if (_highlightEntity != null) {
        final idx = _selectedEntities.indexOf(_highlightEntity!);
        if (idx >= 0) {
          _selectedEntities.removeAt(idx);
        } else {
          _selectedEntities.add(_highlightEntity!);
        }
        // 다중 선택 모드에서는 속성창을 자동으로 열지 않음
      }
      _touchPoint = null;
      _activeSnap = null;
      _highlightEntity = null;
    });
  }

  /// 영역 선택 확정
  void _handleAreaSelectConfirm() {
    setState(() {
      if (_areaSelectStart != null && _areaSelectEnd != null) {
        final x1 = min(_areaSelectStart!.x, _areaSelectEnd!.x);
        final x2 = max(_areaSelectStart!.x, _areaSelectEnd!.x);
        final y1 = min(_areaSelectStart!.y, _areaSelectEnd!.y);
        final y2 = max(_areaSelectStart!.y, _areaSelectEnd!.y);

        _selectedEntities.clear();
        final entities = _dxfData!['entities'] as List;
        for (final e in entities) {
          if (_hiddenLayers.contains(e['layer'])) continue;
          if (_isEntityInRect(e, x1, y1, x2, y2)) {
            _selectedEntities.add(e as Map<String, dynamic>);
          }
        }
        _showPropertyPanel = _selectedEntities.isNotEmpty;
      }
      _areaSelectStart = null;
      _areaSelectEnd = null;
      _touchPoint = null;
      _activeSnap = null;
      _highlightEntity = null;
    });
  }

  /// 펜스 선택 확정
  void _handleFenceSelectConfirm() {
    setState(() {
      if (_fencePoints.length >= 2) {
        _selectedEntities.clear();
        final entities = _dxfData!['entities'] as List;
        for (final e in entities) {
          if (_hiddenLayers.contains(e['layer'])) continue;
          if (_isEntityCrossingFence(e)) {
            _selectedEntities.add(e as Map<String, dynamic>);
          }
        }
        _showPropertyPanel = _selectedEntities.isNotEmpty;
      }
      _fencePoints.clear();
      _touchPoint = null;
      _activeSnap = null;
      _highlightEntity = null;
    });
  }

  /// 엔티티가 사각 영역 안에 있는지 판정
  bool _isEntityInRect(dynamic entity, double x1, double y1, double x2, double y2) {
    final type = entity['type'] as String?;
    if (type == 'LINE') {
      final sx = (entity['startX'] as num?)?.toDouble();
      final sy = (entity['startY'] as num?)?.toDouble();
      final ex = (entity['endX'] as num?)?.toDouble();
      final ey = (entity['endY'] as num?)?.toDouble();
      if (sx == null || sy == null || ex == null || ey == null) return false;
      return sx >= x1 && sx <= x2 && sy >= y1 && sy <= y2 &&
             ex >= x1 && ex <= x2 && ey >= y1 && ey <= y2;
    } else if (type == 'CIRCLE') {
      final cx = (entity['centerX'] as num?)?.toDouble();
      final cy = (entity['centerY'] as num?)?.toDouble();
      if (cx == null || cy == null) return false;
      return cx >= x1 && cx <= x2 && cy >= y1 && cy <= y2;
    } else if (type == 'TEXT' || type == 'MTEXT') {
      final tx = (entity['x'] as num?)?.toDouble();
      final ty = (entity['y'] as num?)?.toDouble();
      if (tx == null || ty == null) return false;
      return tx >= x1 && tx <= x2 && ty >= y1 && ty <= y2;
    } else if (type == 'POINT') {
      final px = (entity['x'] as num?)?.toDouble();
      final py = (entity['y'] as num?)?.toDouble();
      if (px == null || py == null) return false;
      return px >= x1 && px <= x2 && py >= y1 && py <= y2;
    } else if (type == 'LWPOLYLINE' || type == 'POLYLINE') {
      final vertices = entity['vertices'] as List?;
      if (vertices == null) return false;
      return vertices.every((v) {
        final vx = (v['x'] as num?)?.toDouble() ?? 0;
        final vy = (v['y'] as num?)?.toDouble() ?? 0;
        return vx >= x1 && vx <= x2 && vy >= y1 && vy <= y2;
      });
    } else if (type == 'ARC') {
      final cx = (entity['centerX'] as num?)?.toDouble();
      final cy = (entity['centerY'] as num?)?.toDouble();
      if (cx == null || cy == null) return false;
      return cx >= x1 && cx <= x2 && cy >= y1 && cy <= y2;
    } else if (type == 'INSERT') {
      final ix = (entity['x'] as num?)?.toDouble();
      final iy = (entity['y'] as num?)?.toDouble();
      if (ix == null || iy == null) return false;
      return ix >= x1 && ix <= x2 && iy >= y1 && iy <= y2;
    }
    return false;
  }

  /// 엔티티가 펜스 라인과 교차하는지 판정
  bool _isEntityCrossingFence(dynamic entity) {
    if (_fencePoints.length < 2) return false;

    // 엔티티의 선분들을 추출
    final segments = _getEntitySegments(entity);

    // 펜스 각 선분과 교차 검사
    for (int i = 0; i < _fencePoints.length - 1; i++) {
      final fp1 = _fencePoints[i];
      final fp2 = _fencePoints[i + 1];
      for (final seg in segments) {
        if (_segmentsIntersect(fp1.x, fp1.y, fp2.x, fp2.y, seg.$1, seg.$2, seg.$3, seg.$4)) {
          return true;
        }
      }
    }
    return false;
  }

  /// 엔티티에서 선분 리스트 추출 (x1, y1, x2, y2)
  List<(double, double, double, double)> _getEntitySegments(dynamic entity) {
    final type = entity['type'] as String?;
    final result = <(double, double, double, double)>[];

    if (type == 'LINE') {
      final sx = (entity['startX'] as num?)?.toDouble();
      final sy = (entity['startY'] as num?)?.toDouble();
      final ex = (entity['endX'] as num?)?.toDouble();
      final ey = (entity['endY'] as num?)?.toDouble();
      if (sx != null && sy != null && ex != null && ey != null) {
        result.add((sx, sy, ex, ey));
      }
    } else if (type == 'LWPOLYLINE' || type == 'POLYLINE') {
      final vertices = entity['vertices'] as List?;
      if (vertices != null && vertices.length >= 2) {
        for (int i = 0; i < vertices.length - 1; i++) {
          final vx1 = (vertices[i]['x'] as num?)?.toDouble() ?? 0;
          final vy1 = (vertices[i]['y'] as num?)?.toDouble() ?? 0;
          final vx2 = (vertices[i + 1]['x'] as num?)?.toDouble() ?? 0;
          final vy2 = (vertices[i + 1]['y'] as num?)?.toDouble() ?? 0;
          result.add((vx1, vy1, vx2, vy2));
        }
        // 닫힌 폴리라인
        final closed = entity['closed'] == true;
        if (closed && vertices.length >= 3) {
          final first = vertices.first;
          final last = vertices.last;
          result.add((
            (last['x'] as num?)?.toDouble() ?? 0,
            (last['y'] as num?)?.toDouble() ?? 0,
            (first['x'] as num?)?.toDouble() ?? 0,
            (first['y'] as num?)?.toDouble() ?? 0,
          ));
        }
      }
    } else if (type == 'CIRCLE') {
      // 원은 바운딩박스 대각선으로 근사
      final cx = (entity['centerX'] as num?)?.toDouble() ?? 0;
      final cy = (entity['centerY'] as num?)?.toDouble() ?? 0;
      final r = (entity['radius'] as num?)?.toDouble() ?? 0;
      result.add((cx - r, cy, cx + r, cy));
      result.add((cx, cy - r, cx, cy + r));
    } else if (type == 'POINT' || type == 'TEXT' || type == 'MTEXT' || type == 'INSERT') {
      // 점은 아주 작은 십자로 근사
      final px = (entity['x'] as num?)?.toDouble() ?? (entity['centerX'] as num?)?.toDouble() ?? 0;
      final py = (entity['y'] as num?)?.toDouble() ?? (entity['centerY'] as num?)?.toDouble() ?? 0;
      result.add((px - 0.01, py, px + 0.01, py));
    }
    return result;
  }

  /// 두 선분의 교차 판정
  bool _segmentsIntersect(double ax1, double ay1, double ax2, double ay2,
                           double bx1, double by1, double bx2, double by2) {
    double cross(double ox, double oy, double ax, double ay, double bx, double by) {
      return (ax - ox) * (by - oy) - (ay - oy) * (bx - ox);
    }
    final d1 = cross(bx1, by1, bx2, by2, ax1, ay1);
    final d2 = cross(bx1, by1, bx2, by2, ax2, ay2);
    final d3 = cross(ax1, ay1, ax2, ay2, bx1, by1);
    final d4 = cross(ax1, ay1, ax2, ay2, bx2, by2);
    if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
      return true;
    }
    return false;
  }

  /// Select Similar: 선택된 엔티티와 유사한 속성의 엔티티 일괄 선택
  void _selectSimilar() {
    if (_selectedEntities.isEmpty || _dxfData == null) return;
    final ref = _selectedEntities.first;
    final refType = ref['type'] as String;
    final refLayer = ref['layer'] as String?;
    final refColor = ref['resolvedColor'] as int?;

    final allEntities = _dxfData!['entities'] as List;
    final similar = <Map<String, dynamic>>[];

    for (final entity in allEntities) {
      final e = entity as Map<String, dynamic>;
      if (e['type'] != refType) continue;
      if (_hiddenLayers.contains(e['layer'])) continue;
      // 같은 타입 + (같은 레이어 OR 같은 색상)
      if (e['layer'] == refLayer || e['resolvedColor'] == refColor) {
        if (!similar.contains(e)) similar.add(e);
      }
    }

    setState(() {
      _selectedEntities.clear();
      _selectedEntities.addAll(similar);
      _showPropertyPanel = _selectedEntities.isNotEmpty;
    });

    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${similar.length}개 유사 엔티티 선택됨'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 엔티티 정보 텍스트 (하이라이트 시 표시)
  String _getEntityInfoText(Map<String, dynamic> entity) {
    final type = entity['type'] as String? ?? '?';
    final layer = entity['layer'] as String? ?? '';
    final parts = <String>[type, layer];

    switch (type) {
      case 'LINE':
        final x1 = (entity['x1'] as num?)?.toDouble();
        final y1 = (entity['y1'] as num?)?.toDouble();
        final x2 = (entity['x2'] as num?)?.toDouble();
        final y2 = (entity['y2'] as num?)?.toDouble();
        if (x1 != null && y1 != null && x2 != null && y2 != null) {
          final len = sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
          parts.add('길이: ${len.toStringAsFixed(2)}');
        }
        break;
      case 'CIRCLE':
        final r = (entity['radius'] as num?)?.toDouble();
        if (r != null) parts.add('지름: ${(r * 2).toStringAsFixed(2)}');
        break;
      case 'ARC':
        final r = (entity['radius'] as num?)?.toDouble();
        if (r != null) parts.add('R: ${r.toStringAsFixed(2)}');
        break;
      case 'LWPOLYLINE':
      case 'POLYLINE':
        final verts = entity['vertices'] as List?;
        if (verts != null) {
          parts.add('${verts.length}점');
          // 총 길이 계산
          double totalLen = 0;
          for (int i = 1; i < verts.length; i++) {
            final p0 = verts[i - 1];
            final p1 = verts[i];
            final dx = (p1['x'] as num).toDouble() - (p0['x'] as num).toDouble();
            final dy = (p1['y'] as num).toDouble() - (p0['y'] as num).toDouble();
            totalLen += sqrt(dx * dx + dy * dy);
          }
          parts.add('길이: ${totalLen.toStringAsFixed(2)}');
        }
        break;
      case 'TEXT':
      case 'MTEXT':
        final txt = entity['text'] as String?;
        if (txt != null) parts.add('"${txt.length > 20 ? '${txt.substring(0, 20)}...' : txt}"');
        break;
      case 'POINT':
        final x = (entity['x'] as num?)?.toDouble();
        final y = (entity['y'] as num?)?.toDouble();
        if (x != null && y != null) parts.add('(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)})');
        break;
      case 'INSERT':
        final blockName = entity['blockName'] as String?;
        if (blockName != null) parts.add(blockName);
        break;
    }

    return parts.join(' | ');
  }

  /// 접기/펼치기 섹션 위젯
  Widget _buildCollapsibleSection({
    required String title,
    required bool expanded,
    required ValueChanged<bool> onToggle,
    required List<Widget> children,
    Color titleColor = Colors.white70,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => onToggle(!expanded),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 16, color: titleColor,
              ),
              const SizedBox(width: 2),
              Text(title, style: TextStyle(color: titleColor, fontSize: 12)),
            ],
          ),
        ),
        if (expanded) ...children,
      ],
    );
  }

  /// 선택된 엔티티 색상 변경
  void _changeSelectedColor(int newColorARGB) {
    setState(() {
      for (final entity in _selectedEntities) {
        final oldColor = entity['resolvedColor'] as int?;
        _pushUndo(_UndoAction(_UndoType.changeProperty, {
          'entity': entity, 'field': 'resolvedColor', 'oldValue': oldColor, 'newValue': newColorARGB,
        }));
        _pushUndo(_UndoAction(_UndoType.changeProperty, {
          'entity': entity, 'field': 'color', 'oldValue': entity['color'], 'newValue': newColorARGB,
        }));
        entity['resolvedColor'] = newColorARGB;
        entity['color'] = newColorARGB;
      }
      _dxfRepaintVersion++;
    });
  }

  /// 선택된 엔티티 선 두께 변경
  void _changeSelectedLineWidth(double newLw) {
    setState(() {
      for (final entity in _selectedEntities) {
        final oldLw = entity['lw'] as double?;
        _pushUndo(_UndoAction(_UndoType.changeProperty, {
          'entity': entity, 'field': 'lw', 'oldValue': oldLw, 'newValue': newLw,
        }));
        entity['lw'] = newLw;
      }
      _dxfRepaintVersion++;
    });
  }

  /// PDMODE 미리보기 위젯
  Widget _buildPdmodePreview(int pdmode) {
    return CustomPaint(
      size: const Size(24, 24),
      painter: _PdmodePreviewPainter(pdmode),
    );
  }

  /// 포인트 스타일 선택 다이얼로그
  void _showPointStyleDialog() {
    const styles = [0, 2, 3, 4, 32, 33, 34, 35, 64, 65, 66, 67];
    const labels = [
      '점', '+', 'X', '|', '○', '○·', '○+', '○X',
      '□', '□·', '□+', '□X',
    ];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('포인트 스타일 (PDMODE)'),
        content: SizedBox(
          width: 280,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: List.generate(styles.length, (i) {
              final style = styles[i];
              final selected = _drawPointStyle == style;
              return GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _drawPointStyle = style;
                    _activeDrawMode = 'point';
                    _isSelectMode = false;
                    _isPointMode = false;
                    _isDimensionMode = false;
                    _selectedEntities.clear();
                    _showPropertyPanel = false;
                  });
                },
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: selected ? Colors.cyan.withValues(alpha: 0.3) : Colors.grey[200],
                    border: Border.all(
                      color: selected ? Colors.cyan : Colors.grey,
                      width: selected ? 2 : 1,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CustomPaint(
                        size: const Size(28, 28),
                        painter: _PdmodePreviewPainter(style),
                      ),
                      Text(labels[i], style: const TextStyle(fontSize: 9)),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  /// 그리기 메뉴 표시
  void _showDrawMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.location_on),
              title: const Text('포인트'),
              trailing: _buildPdmodePreview(_drawPointStyle),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _activeDrawMode = 'point';
                  _isSelectMode = false;
                  _isPointMode = false;
                  _isDimensionMode = false;
                  _selectedEntities.clear();
                  _showPropertyPanel = false;
                });
              },
              onLongPress: () {
                Navigator.pop(ctx);
                _showPointStyleDialog();
              },
            ),
            ListTile(
              leading: const Icon(Icons.horizontal_rule),
              title: const Text('라인'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _activeDrawMode = 'line';
                  _isSelectMode = false;
                  _isPointMode = false;
                  _isDimensionMode = false;
                  _drawFirstPoint = null;
                  _selectedEntities.clear();
                  _showPropertyPanel = false;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.call_made),
              title: const Text('지시선'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _activeDrawMode = 'leader';
                  _isSelectMode = false;
                  _isPointMode = false;
                  _isDimensionMode = false;
                  _leaderPoints = [];
                  _selectedEntities.clear();
                  _showPropertyPanel = false;
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.text_fields),
              title: const Text('텍스트'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _activeDrawMode = 'text';
                  _isSelectMode = false;
                  _isPointMode = false;
                  _isDimensionMode = false;
                  _selectedEntities.clear();
                  _showPropertyPanel = false;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  // 속성 패널 탭 인덱스: 0=속성, 1=측점데이터
  int _propertyTabIndex = 0;

  // 기초라인/횡단 레이어 이름 (근접 측점 검색 대상)
  static const _baselineLineLayers = {
    '좌안기초라인', '우안기초라인',
    '좌안기초횡단', '우안기초횡단',
  };

  /// 선택된 엔티티에서 측점 데이터 찾기
  StationData? _findStationForEntity(Map<String, dynamic> entity) {
    final stationNo = entity['_stationNo'] as String?;
    final dist = (entity['_dist'] as num?)?.toDouble();
    if (stationNo != null) {
      final found = widget.stations.where((s) => s.no == stationNo).toList();
      if (found.isNotEmpty) return found.first;
    }
    if (dist != null) {
      // 거리로 매칭 (0.5m 이내)
      final found = widget.stations.where((s) =>
        s.distance != null && (s.distance! - dist).abs() < 0.5).toList();
      if (found.isNotEmpty) return found.first;
    }
    // TEXT 엔티티의 text 필드로 매칭
    if (entity['type'] == 'TEXT' && entity['text'] != null) {
      final text = entity['text'] as String;
      final found = widget.stations.where((s) => s.no == text).toList();
      if (found.isNotEmpty) return found.first;
    }
    // 기초라인/횡단 엔티티: 터치 지점에서 가장 가까운 기초측점의 측점 데이터 반환
    final layer = entity['layer'] as String?;
    if (layer != null && _baselineLineLayers.contains(layer) && _lastSelectDxfPoint != null) {
      final nearest = _findNearestBaselineStation(layer);
      if (nearest != null) return nearest;
    }
    return null;
  }

  /// 기초라인 레이어에서 터치 지점과 가장 가까운 측점 찾기
  StationData? _findNearestBaselineStation(String layer) {
    if (_lastSelectDxfPoint == null) return null;
    final tp = _lastSelectDxfPoint!;
    final isLeft = layer.startsWith('좌안');
    final pointLayer = isLeft ? '좌안기초측점' : '우안기초측점';
    final allEntities = _dxfData?['entities'] as List? ?? [];

    double bestDist = double.infinity;
    String? bestStationNo;
    for (final e in allEntities) {
      if (e['layer'] != pointLayer || e['type'] != 'CIRCLE') continue;
      final cx = (e['cx'] as num).toDouble();
      final cy = (e['cy'] as num).toDouble();
      final d = (tp.x - cx) * (tp.x - cx) + (tp.y - cy) * (tp.y - cy);
      if (d < bestDist) {
        bestDist = d;
        bestStationNo = e['_stationNo'] as String?;
      }
    }
    if (bestStationNo != null) {
      final found = widget.stations.where((s) => s.no == bestStationNo).toList();
      if (found.isNotEmpty) return found.first;
    }
    return null;
  }

  /// 기초라인의 기초측점 목록 수집 (거리순 정렬)
  List<({double cx, double cy, String stationNo, double dist})>? _getBaselineCircles(Map<String, dynamic> entity) {
    final layer = entity['layer'] as String?;
    if (layer == null || !_baselineLineLayers.contains(layer)) return null;
    final isLeft = layer.startsWith('좌안');
    final pointLayer = isLeft ? '좌안기초측점' : '우안기초측점';
    final allEntities = _dxfData?['entities'] as List? ?? [];

    final circles = <({double cx, double cy, String stationNo, double dist})>[];
    for (final e in allEntities) {
      if (e['layer'] != pointLayer || e['type'] != 'CIRCLE') continue;
      final sno = e['_stationNo'] as String?;
      final d = (e['_dist'] as num?)?.toDouble();
      if (sno == null || d == null) continue;
      circles.add((
        cx: (e['cx'] as num).toDouble(),
        cy: (e['cy'] as num).toDouble(),
        stationNo: sno,
        dist: d,
      ));
    }
    if (circles.length < 2) return null;
    circles.sort((a, b) => a.dist.compareTo(b.dist));
    return circles;
  }

  /// 터치 지점 기반 세그먼트 인덱스 결정
  int _findBaselineSegIndex(List<({double cx, double cy, String stationNo, double dist})> circles) {
    if (_baselineSegOverride != null) {
      return _baselineSegOverride!.clamp(0, circles.length - 2);
    }
    if (_lastSelectDxfPoint == null) return 0;
    final tp = _lastSelectDxfPoint!;
    double bestSegDist = double.infinity;
    int bestSegIdx = 0;
    for (int i = 0; i < circles.length - 1; i++) {
      final d = _distToSegment(tp.x, tp.y,
        circles[i].cx, circles[i].cy,
        circles[i + 1].cx, circles[i + 1].cy);
      if (d < bestSegDist) {
        bestSegDist = d;
        bestSegIdx = i;
      }
    }
    return bestSegIdx;
  }

  /// 세그먼트 인덱스로 보간 데이터 반환
  /// 반환: (segIdx, totalSegs, interpolList)
  (int, int, List<(String, double)>)? _findBaselineInterpolData(Map<String, dynamic> entity) {
    final circles = _getBaselineCircles(entity);
    if (circles == null) return null;
    if (_lastSelectDxfPoint == null && _baselineSegOverride == null) return null;

    final segIdx = _findBaselineSegIndex(circles);
    final totalSegs = circles.length - 1;

    final stA = circles[segIdx];
    final stB = circles[segIdx + 1];

    final sdA = widget.stations.where((s) => s.no == stA.stationNo).toList();
    final sdB = widget.stations.where((s) => s.no == stB.stationNo).toList();
    if (sdA.isEmpty || sdB.isEmpty) return null;
    final a = sdA.first;
    final b = sdB.first;

    final flA = a.foundationLevel;
    final flB = b.foundationLevel;
    if (flA == null || flB == null) return null;

    final distA = a.distance ?? stA.dist;
    final distB = b.distance ?? stB.dist;
    final span = distB - distA;
    if (span <= 0) return null;

    final result = <(String, double)>[];
    result.add((a.no, flA));

    const interval = 5.0;
    int chainIdx = 1;
    double d = distA + interval;
    while (d < distB - 0.1) {
      final t = (d - distA) / span;
      final fl = flA + (flB - flA) * t;
      result.add(('+${(chainIdx * interval).toInt()}', fl));
      chainIdx++;
      d += interval;
    }

    result.add((b.no, flB));
    return (segIdx, totalSegs, result);
  }

  /// 속성 편집 패널
  Widget _buildPropertyPanel() {
    if (!_showPropertyPanel || _selectedEntities.isEmpty) return const SizedBox.shrink();

    final count = _selectedEntities.length;
    final firstEntity = _selectedEntities.first;
    final currentColor = Color((firstEntity['resolvedColor'] as int?) ?? 0xFFFFFFFF);

    // 측점 데이터 매칭 시도
    final baselineResult = count == 1 ? _findBaselineInterpolData(firstEntity) : null;
    final segIdx = baselineResult?.$1;
    final totalSegs = baselineResult?.$2;
    final interpolList = baselineResult?.$3;

    // 세그먼트 오버라이드가 있으면 해당 세그먼트의 시작 측점으로 stationData 결정
    StationData? stationData;
    if (count == 1) {
      if (_baselineSegOverride != null && baselineResult != null) {
        final circles = _getBaselineCircles(firstEntity);
        if (circles != null && segIdx != null && segIdx < circles.length) {
          final sno = circles[segIdx].stationNo;
          final found = widget.stations.where((s) => s.no == sno).toList();
          if (found.isNotEmpty) stationData = found.first;
        }
      }
      stationData ??= _findStationForEntity(firstEntity);
    }
    final hasStationTab = stationData != null;

    final colors = [
      (0xFFFF0000, '빨강'),
      (0xFF00FF00, '초록'),
      (0xFF0000FF, '파랑'),
      (0xFFFFFF00, '노랑'),
      (0xFFFF00FF, '마젠타'),
      (0xFF00FFFF, '시안'),
      (0xFFFFFFFF, '흰색'),
      (0xFFFF8000, '주황'),
    ];

    return Positioned(
      bottom: _bottomBarHeight + 8,
      left: 8,
      right: 8,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[600]!),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 상태 메시지 + 버튼 행
            Text(
              '$count개 선택됨 (${firstEntity['type']}${count > 1 ? ' 외' : ''})',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            // 레이어 정보 + 레이어 관련 버튼
            if (firstEntity['layer'] != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Builder(builder: (context) {
                  final layerName = firstEntity['layer'] as String;
                  final layerEntityCount = (_dxfData!['entities'] as List)
                      .where((e) => e['layer'] == layerName).length;
                  final allSelected = _selectedEntities.length == layerEntityCount &&
                      _selectedEntities.every((e) => e['layer'] == layerName);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.layers, size: 14, color: Colors.grey[400]),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              '$layerName ($layerEntityCount개)',
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                      // 레이어 표시/숨기기
                      _buildPanelActionBtn(
                        _hiddenLayers.contains(layerName) ? Icons.visibility_off : Icons.visibility,
                        _hiddenLayers.contains(layerName) ? '표시' : '숨기기',
                        Colors.cyan,
                        () {
                          setState(() {
                            if (_hiddenLayers.contains(layerName)) {
                              _hiddenLayers.remove(layerName);
                            } else {
                              _hiddenLayers.add(layerName);
                            }
                            _dxfRepaintVersion++;
                          });
                        },
                      ),
                      const SizedBox(width: 4),
                      // 레이어 잠금
                      _buildPanelActionBtn(
                        _lockedLayers.contains(layerName) ? Icons.lock : Icons.lock_open,
                        _lockedLayers.contains(layerName) ? '잠금해제' : '잠금',
                        Colors.orange,
                        () {
                          setState(() {
                            if (_lockedLayers.contains(layerName)) {
                              _lockedLayers.remove(layerName);
                            } else {
                              _lockedLayers.add(layerName);
                            }
                          });
                        },
                      ),
                      const SizedBox(width: 4),
                      // 레이어 전체 선택/해제 토글
                      _buildPanelActionBtn(
                        allSelected ? Icons.deselect : Icons.checklist,
                        allSelected ? '선택해제' : '레이어 선택',
                        allSelected ? Colors.grey : Colors.green,
                        () {
                      if (allSelected) {
                        // 해제
                        setState(() {
                          _selectedEntities.clear();
                          _showPropertyPanel = false;
                        });
                        return;
                      }
                      final entities = _dxfData!['entities'] as List;
                      final layerEntities = entities.where((e) => e['layer'] == layerName).toList();
                      setState(() {
                        _selectedEntities.clear();
                        _selectedEntities.addAll(layerEntities.cast<Map<String, dynamic>>());
                        _showPropertyPanel = _selectedEntities.isNotEmpty;
                      });
                    }),
                  ],
                ),
                ],
                );
                }),
              ),
              const SizedBox(height: 4),
            ],
            Row(
              children: [
                _buildPanelActionBtn(Icons.select_all, '유사 선택', Colors.cyan, _selectSimilar),
                const SizedBox(width: 6),
                _buildPanelActionBtn(Icons.delete, '삭제', Colors.red, () {
                  setState(() {
                    final entities = _dxfData!['entities'] as List;
                    // 역순으로 삭제 (인덱스 밀림 방지)
                    final sortedSelected = _selectedEntities.toList();
                    for (final e in sortedSelected.reversed) {
                      final isUser = _userEntities.contains(e);
                      if (isUser) {
                        _userEntities.remove(e);
                      } else {
                        final idx = entities.indexOf(e);
                        if (idx >= 0 && _originalDxfBytes != null) {
                          // 원본 바이트에서도 제거
                          final result = DxfService.removeEntityFromBytes(
                            _dxfData!, _originalDxfBytes!, idx,
                          );
                          if (result != null) {
                            _originalDxfBytes = result;
                          }
                        } else {
                          entities.remove(e);
                        }
                        _dxfRepaintVersion++;
                      }
                      _pushUndo(_UndoAction(_UndoType.deleteEntity, {
                        'entity': e,
                        'source': isUser ? 'user' : 'dxf',
                      }));
                    }
                    _selectedEntities.clear();
                    _showPropertyPanel = false;
                  });
                }),
                const Spacer(),
                _buildPanelActionBtn(Icons.close, '닫기', Colors.white54, () => setState(() {
                  _selectedEntities.clear();
                  _showPropertyPanel = false;
                  _isSelectMode = false;
                })),
              ],
            ),
            // 탭 헤더 (측점 데이터가 있을 때만)
            if (hasStationTab) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  _buildTabButton('속성', 0),
                  const SizedBox(width: 4),
                  _buildTabButton('측점 데이터', 1),
                ],
              ),
            ],
            const SizedBox(height: 8),
            // 탭 내용
            if (!hasStationTab || _propertyTabIndex == 0) ...[
              // 모양 (색상 + 선 두께)
              _buildCollapsibleSection(
                title: '모양',
                expanded: _propExpandColor,
                onToggle: (v) => setState(() => _propExpandColor = v),
                children: [
                  const SizedBox(height: 4),
                  const Text('색상', style: TextStyle(color: Colors.white38, fontSize: 11)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: colors.map((c) {
                      final isSelected = currentColor.toARGB32() == c.$1;
                      return GestureDetector(
                        onTap: () => _changeSelectedColor(c.$1),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Color(c.$1),
                            border: Border.all(
                              color: isSelected ? Colors.white : Colors.transparent,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('선 두께', style: TextStyle(color: Colors.white38, fontSize: 11)),
                      const SizedBox(width: 8),
                      Text(
                        '${((firstEntity['lw'] as double?) ?? 0.5).toStringAsFixed(1)}px',
                        style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      activeTrackColor: Colors.cyan,
                      inactiveTrackColor: Colors.grey[700],
                      thumbColor: Colors.cyanAccent,
                    ),
                    child: Slider(
                      value: ((firstEntity['lw'] as double?) ?? 0.5).clamp(0.25, 5.0),
                      min: 0.25,
                      max: 5.0,
                      divisions: 19,
                      onChanged: (v) {
                        final rounded = (v * 4).round() / 4; // 0.25 단위
                        _changeSelectedLineWidth(rounded);
                      },
                    ),
                  ),
                ],
              ),
              // 기초바닥레벨 표시 (측점 데이터가 있을 때)
              if (hasStationTab && stationData.foundationLevel != null) ...[
                const SizedBox(height: 4),
                _buildCollapsibleSection(
                  title: '기초바닥레벨',
                  expanded: _propExpandFoundation,
                  onToggle: (v) => setState(() => _propExpandFoundation = v),
                  titleColor: Colors.cyanAccent,
                  children: [
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.cyan.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.cyan.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        children: [
                          Text(
                            stationData.foundationLevel!.toStringAsFixed(3),
                            style: const TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '(${stationData.no})',
                            style: const TextStyle(color: Colors.white38, fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
              // 기초라인 보간 데이터 (5m 단위 기초바닥레벨)
              if (interpolList != null && interpolList.length >= 2) ...[
                const SizedBox(height: 4),
                _buildCollapsibleSection(
                  title: '구간 기초바닥레벨 (5m 보간)  ${interpolList.length}점',
                  expanded: _propExpandInterpol,
                  onToggle: (v) => setState(() => _propExpandInterpol = v),
                  titleColor: Colors.orangeAccent,
                  children: [
                    const SizedBox(height: 4),
                    // 이전/다음 구간 버튼
                    if (totalSegs != null && totalSegs > 1)
                      Row(
                        children: [
                          GestureDetector(
                            onTap: segIdx != null && segIdx > 0 ? () => setState(() {
                              _baselineSegOverride = segIdx - 1;
                            }) : null,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: segIdx != null && segIdx > 0 ? Colors.orange.withValues(alpha: 0.3) : Colors.grey[800],
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('◀ 이전', style: TextStyle(
                                color: segIdx != null && segIdx > 0 ? Colors.orangeAccent : Colors.white24,
                                fontSize: 11, fontWeight: FontWeight.bold,
                              )),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text('${(segIdx ?? 0) + 1}/$totalSegs',
                            style: const TextStyle(color: Colors.white38, fontSize: 10)),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: segIdx != null && segIdx < totalSegs - 1 ? () => setState(() {
                              _baselineSegOverride = segIdx + 1;
                            }) : null,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: segIdx != null && segIdx < totalSegs - 1 ? Colors.orange.withValues(alpha: 0.3) : Colors.grey[800],
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('다음 ▶', style: TextStyle(
                                color: segIdx != null && segIdx < totalSegs - 1 ? Colors.orangeAccent : Colors.white24,
                                fontSize: 11, fontWeight: FontWeight.bold,
                              )),
                            ),
                          ),
                        ],
                      ),
                    if (totalSegs != null && totalSegs > 1)
                      const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: interpolList.map((item) {
                          final isStation = !item.$1.startsWith('+');
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1.5),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 80,
                                  child: Text(
                                    item.$1,
                                    style: TextStyle(
                                      color: isStation ? Colors.white : Colors.white54,
                                      fontSize: 11,
                                      fontWeight: isStation ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ),
                                Text(
                                  item.$2.toStringAsFixed(3),
                                  style: TextStyle(
                                    color: isStation ? Colors.orangeAccent : Colors.orange.withValues(alpha: 0.7),
                                    fontSize: 11,
                                    fontWeight: isStation ? FontWeight.bold : FontWeight.normal,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ],
            ] else if (_propertyTabIndex == 1) ...[
              // 측점 데이터 + 이전/다음 버튼
              if (totalSegs != null && totalSegs > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: segIdx != null && segIdx > 0 ? () => setState(() {
                          _baselineSegOverride = segIdx - 1;
                        }) : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: segIdx != null && segIdx > 0 ? Colors.cyan.withValues(alpha: 0.3) : Colors.grey[800],
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('◀ 이전', style: TextStyle(
                            color: segIdx != null && segIdx > 0 ? Colors.cyanAccent : Colors.white24,
                            fontSize: 11, fontWeight: FontWeight.bold,
                          )),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${(segIdx ?? 0) + 1}/$totalSegs',
                        style: const TextStyle(color: Colors.white38, fontSize: 10)),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: segIdx != null && segIdx < totalSegs - 1 ? () => setState(() {
                          _baselineSegOverride = segIdx + 1;
                        }) : null,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: segIdx != null && segIdx < totalSegs - 1 ? Colors.cyan.withValues(alpha: 0.3) : Colors.grey[800],
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('다음 ▶', style: TextStyle(
                            color: segIdx != null && segIdx < totalSegs - 1 ? Colors.cyanAccent : Colors.white24,
                            fontSize: 11, fontWeight: FontWeight.bold,
                          )),
                        ),
                      ),
                    ],
                  ),
                ),
              _buildStationDataView(stationData),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTabButton(String label, int index) {
    final isActive = _propertyTabIndex == index;
    return GestureDetector(
      onTap: () => setState(() => _propertyTabIndex = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: isActive ? Colors.cyan.withValues(alpha: 0.3) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isActive ? Colors.cyan : Colors.grey[600]!,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? Colors.cyanAccent : Colors.white54,
            fontSize: 12,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildStationDataView(StationData st) {
    String fmt(double? v) => v != null ? v.toStringAsFixed(3) : '-';

    final rows = <(String, String)>[
      ('측점', st.no),
      ('누가거리', fmt(st.distance)),
      ('지반고', fmt(st.gh)),
      ('최심하상고', fmt(st.deepestBedLevel)),
      ('계획하상고', fmt(st.ip)),
      ('계획홍수위', fmt(st.plannedFloodLevel)),
      ('좌안제방고', fmt(st.leftBankHeight)),
      ('우안제방고', fmt(st.rightBankHeight)),
      ('계획제방고(좌)', fmt(st.plannedBankLeft)),
      ('계획제방고(우)', fmt(st.plannedBankRight)),
      ('노체(좌)', fmt(st.roadbedLeft)),
      ('노체(우)', fmt(st.roadbedRight)),
      ('기초바닥레벨', fmt(st.foundationLevel)),
      ('옵셋(좌)', fmt(st.offsetLeft)),
      ('옵셋(우)', fmt(st.offsetRight)),
      ('Height', fmt(st.height)),
      ('단수', fmt(st.singleCount)),
      ('기울기', fmt(st.slope)),
      ('각도', fmt(st.angle)),
      ('터파기깊이', fmt(st.excavationDepth)),
      ('X', fmt(st.x)),
      ('Y', fmt(st.y)),
    ];

    // null이 아닌 값만 표시
    final filtered = rows.where((r) => r.$2 != '-' || r.$1 == '측점').toList();

    return SizedBox(
      height: 200,
      child: ListView.builder(
        itemCount: filtered.length,
        padding: EdgeInsets.zero,
        itemBuilder: (_, i) {
          final r = filtered[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(
                  width: 100,
                  child: Text(r.$1, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ),
                Expanded(
                  child: Text(r.$2, style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildPanelActionBtn(IconData icon, String label, Color color, VoidCallback onPressed) {
    return SizedBox(
      height: 30,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: color, size: 16),
        label: Text(label, style: TextStyle(color: color, fontSize: 11)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  /// 하단 툴바 (5슬롯, 레이어 버튼 포함)
  Widget _buildBottomBar() {
    return Container(
      height: _bottomBarHeight,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        border: Border(top: BorderSide(color: Colors.grey[700]!, width: 0.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 슬롯 1: 파일 열기
          _buildToolbarButton(
            icon: Icons.folder_open,
            label: '',
            onPressed: _openDxfFile,
          ),
          // 슬롯 2: GPS 정보 패널 토글
          _buildToolbarButton(
            icon: Icons.info_outline,
            label: '',
            isActive: _showInfoPanel,
            onPressed: () {
              setState(() => _showInfoPanel = !_showInfoPanel);
            },
          ),
          // 슬롯 3: 레이어
          _buildToolbarButton(
            icon: Icons.layers,
            label: '',
            isActive: _showLayerPanel,
            badge: _hiddenLayers.isNotEmpty ? '${_hiddenLayers.length}' : null,
            onPressed: () {
              setState(() => _showLayerPanel = !_showLayerPanel);
            },
          ),
          // 슬롯 4: 그리기 (롱프레스 → 타입 선택)
          _buildToolbarButton(
            icon: _activeDrawMode == 'point' ? Icons.location_on
                : _activeDrawMode == 'line' ? Icons.horizontal_rule
                : _activeDrawMode == 'leader' ? Icons.call_made
                : _activeDrawMode == 'text' ? Icons.text_fields
                : Icons.edit,
            label: '',
            isActive: _activeDrawMode != null,
            badge: _userEntities.isNotEmpty ? '${_userEntities.length}' : null,
            onPressed: () {
              if (_activeDrawMode != null) {
                setState(() {
                  _activeDrawMode = null;
                  _drawFirstPoint = null;
                  _leaderPoints = [];
                  _touchPoint = null;
                  _activeSnap = null;
                  _highlightEntity = null;
                  _cursorTipDxf = null;
                });
              } else {
                _showDrawMenu();
              }
            },
            onLongPress: _showDrawMenu,
          ),
          // 슬롯 5: 엔티티 선택 (롱프레스 → 모드 선택)
          _buildToolbarButton(
            icon: _getSelectModeIcon(),
            label: '',
            isActive: _isSelectMode,
            badge: _selectedEntities.isNotEmpty ? '${_selectedEntities.length}' : null,
            onPressed: () {
              setState(() {
                _isSelectMode = !_isSelectMode;
                if (_isSelectMode) {
                  _activeDrawMode = null;
                  _isPointMode = false;
                  _isDimensionMode = false;
                } else {
                  _selectedEntities.clear();
                  _showPropertyPanel = false;
                  _touchPoint = null;
                  _activeSnap = null;
                  _highlightEntity = null;
                  _areaSelectStart = null;
                  _areaSelectEnd = null;
                  _fencePoints.clear();
                }
              });
            },
            onLongPress: _showSelectModeMenu,
          ),
          // 슬롯 6: 치수 측정 (롱프레스 → 타입 선택)
          _buildToolbarButton(
            icon: _getDimTypeIcon(_activeDimType),
            label: '',
            isActive: _isDimensionMode,
            onPressed: () {
              setState(() {
                _isDimensionMode = !_isDimensionMode;
                if (_isDimensionMode) {
                  _isPointMode = false;
                  _activeDrawMode = null;
                  _isSelectMode = false;
                  _touchPoint = null;
                  _activeSnap = null;
                  _highlightEntity = null;
                  _showDimPanel = false;
                  _showDimStylePanel = false;
                }
                if (!_isDimensionMode) {
                  _dimFirstPoint = null;
                  _dimSecondPoint = null;
                  _dimPending = null;
                  _dimPlacementDxf = null;
                  _cursorTipDxf = null;
                  _touchPoint = null;
                  _activeSnap = null;
                  _highlightEntity = null;
                }
              });
            },
            onLongPress: _showDimTypeMenu,
          ),
          // 슬롯 7: 객체 목록 (치수+포인트+라인+텍스트+지시선)
          _buildToolbarButton(
            icon: Icons.list_alt,
            label: '',
            isActive: _showDimPanel,
            badge: (_dimResults.length + _userEntities.length) > 0 ? '${_dimResults.length + _userEntities.length}' : null,
            onPressed: () {
              setState(() {
                _showDimPanel = !_showDimPanel;
                if (_showDimPanel) {
                  _showLayerPanel = false;
                  _showDimStylePanel = false;
                }
              });
            },
          ),
          // 슬롯 8: 치수/그리기 설정
          _buildToolbarButton(
            icon: Icons.palette,
            label: '',
            isActive: _showDimStylePanel,
            onPressed: () {
              setState(() {
                _showDimStylePanel = !_showDimStylePanel;
                if (_showDimStylePanel) {
                  _showLayerPanel = false;
                  _showDimPanel = false;
                }
              });
            },
          ),
          // 슬롯 9: 더보기 메뉴
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
            color: Colors.grey[900],
            onSelected: (value) {
              switch (value) {
                case 'baseline_left':
                  _generateBaseline(isLeft: true);
                  break;
                case 'baseline_right':
                  _generateBaseline(isLeft: false);
                  break;
                case 'baseline_both':
                  _generateBaseline(isLeft: true);
                  _generateBaseline(isLeft: false);
                  break;
                case 'baseline_interpol':
                  _showBaselineInterpolDialog();
                  break;
                case 'levee_points':
                  _showLeveePointsDialog();
                  break;
                case 'levee_clear':
                  _clearLeveePoints();
                  break;
                case 'baseline_clear':
                  _clearBaselines();
                  break;
                case 'export_dxf':
                  _exportDxf();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'baseline_left', child: Text('좌안 기초라인 생성', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(value: 'baseline_right', child: Text('우안 기초라인 생성', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(value: 'baseline_both', child: Text('좌안+우안 생성', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(value: 'baseline_interpol', child: Text('기초라인 보간', style: TextStyle(color: Colors.white))),
              const PopupMenuItem(value: 'levee_points', child: Text('노체포인트 생성', style: TextStyle(color: Colors.white))),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'export_dxf', child: Text('DXF 저장', style: TextStyle(color: Colors.white))),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'baseline_clear', child: Text('기초라인 삭제', style: TextStyle(color: Colors.redAccent))),
              const PopupMenuItem(value: 'levee_clear', child: Text('노체포인트 삭제', style: TextStyle(color: Colors.redAccent))),
            ],
          ),
        ],
      ),
    );
  }

  // ── 기초라인 생성/삭제 ──

  static const _baselineLayerNames = [
    '좌안기초라인', '우안기초라인',
    '좌안기초측점', '우안기초측점',
    '기초측점텍스트',
    '센터라인측점', '센터라인측점텍스트',
    '좌안기초횡단', '우안기초횡단',
  ];

  /// 세그먼트 길이 (직선 또는 호)
  double _segLength(double x1, double y1, double x2, double y2, double bulge) {
    final d = sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));
    if (bulge.abs() < 1e-10) return d;
    final theta = 4.0 * atan(bulge);
    return d * theta.abs() / (2.0 * sin(theta / 2.0).abs());
  }

  /// 세그먼트 위 t(0~1) 위치의 (x, y, 접선각) 반환 (직선/호 모두 지원)
  ({double x, double y, double tang}) _ptOnSeg(
    double x1, double y1, double x2, double y2, double bulge, double t,
  ) {
    final d = sqrt(pow(x2 - x1, 2) + pow(y2 - y1, 2));

    if (bulge.abs() < 1e-10) {
      // 직선
      final px = x1 + t * (x2 - x1);
      final py = y1 + t * (y2 - y1);
      final tang = atan2(y2 - y1, x2 - x1);
      return (x: px, y: py, tang: tang);
    }

    // 호
    final theta = 4.0 * atan(bulge);
    final r = d / (2.0 * sin(theta / 2.0));
    final mx = (x1 + x2) / 2.0;
    final my = (y1 + y2) / 2.0;
    final ma = atan2(y2 - y1, x2 - x1);
    final cx = mx - r * cos(theta / 2.0) * sin(ma);
    final cy = my + r * cos(theta / 2.0) * cos(ma);
    final sa = atan2(y1 - cy, x1 - cx);
    var ea = atan2(y2 - cy, x2 - cx);

    double ang, tang;
    if (bulge > 0) {
      if (ea < sa) ea += 2.0 * pi;
      ang = sa + t * (ea - sa);
      tang = ang + pi / 2.0;
    } else {
      if (ea > sa) ea -= 2.0 * pi;
      ang = sa + t * (ea - sa);
      tang = ang - pi / 2.0;
    }

    final px = cx + r.abs() * cos(ang);
    final py = cy + r.abs() * sin(ang);
    return (x: px, y: py, tang: tang);
  }

  /// 중심선 폴리라인에서 누가거리 위치의 좌표와 수직 방향을 구함 (호 지원)
  ({double x, double y, double nx, double ny})? _pointOnCenterline(
    List<Map<String, dynamic>> clPoints, double targetDist,
  ) {
    double accumulated = 0.0;
    for (int i = 0; i < clPoints.length - 1; i++) {
      final x1 = (clPoints[i]['x'] as num).toDouble();
      final y1 = (clPoints[i]['y'] as num).toDouble();
      final b = ((clPoints[i]['bulge'] as num?) ?? 0.0).toDouble();
      final x2 = (clPoints[i + 1]['x'] as num).toDouble();
      final y2 = (clPoints[i + 1]['y'] as num).toDouble();

      final segLen = _segLength(x1, y1, x2, y2, b);
      if (segLen < 1e-10) continue;

      if (accumulated + segLen >= targetDist - 1e-6) {
        var t = (targetDist - accumulated) / segLen;
        if (t > 1.0) t = 1.0;
        if (t < 0.0) t = 0.0;

        final pt = _ptOnSeg(x1, y1, x2, y2, b, t);
        // 접선 + 90도 = 좌안 방향 (LISP과 동일)
        final perp = pt.tang + pi / 2.0;
        final nx = cos(perp);
        final ny = sin(perp);
        return (x: pt.x, y: pt.y, nx: nx, ny: ny);
      }
      accumulated += segLen;
    }
    return null;
  }

  /// 중심선 레이어에서 폴리라인 포인트 추출 + 0번 측점까지의 오프셋 거리
  ({List<Map<String, dynamic>> points, double startOffset})? _getCenterlineData() {
    if (_dxfData == null) return null;
    final entities = _dxfData!['entities'] as List;
    for (final e in entities) {
      if (e['type'] == 'LWPOLYLINE' && e['layer'] == '#중심선') {
        var points = (e['points'] as List).cast<Map<String, dynamic>>();
        if (points.length < 2) return null;

        // 0번 측점 좌표
        final st0 = widget.stations.firstWhere(
          (s) => s.distance != null && s.distance! < 1.0 && s.x != null,
          orElse: () => widget.stations.first,
        );
        if (st0.x == null || st0.y == null) {
          return (points: List.from(points), startOffset: 0.0);
        }

        // 방향 결정
        final first = points.first;
        final last = points.last;
        final distToFirst = pow((first['x'] as num).toDouble() - st0.x!, 2) +
            pow((first['y'] as num).toDouble() - st0.y!, 2);
        final distToLast = pow((last['x'] as num).toDouble() - st0.x!, 2) +
            pow((last['y'] as num).toDouble() - st0.y!, 2);
        if (distToLast < distToFirst) {
          points = points.reversed.toList();
        }

        // 폴리라인 시작점 → 0번 측점까지의 거리(오프셋) 계산
        // 가장 가까운 세그먼트 위 거리를 찾음
        double bestDist = double.infinity;
        double bestAccum = 0.0;
        double accumulated = 0.0;
        for (int i = 0; i < points.length - 1; i++) {
          final x1 = (points[i]['x'] as num).toDouble();
          final y1 = (points[i]['y'] as num).toDouble();
          final b = ((points[i]['bulge'] as num?) ?? 0.0).toDouble();
          final x2 = (points[i + 1]['x'] as num).toDouble();
          final y2 = (points[i + 1]['y'] as num).toDouble();
          final segLen = _segLength(x1, y1, x2, y2, b);

          // 이 세그먼트 위에서 0번 측점에 가장 가까운 점 찾기 (10분할)
          for (int k = 0; k <= 10; k++) {
            final t = k / 10.0;
            final pt = _ptOnSeg(x1, y1, x2, y2, b, t);
            final dd = (pt.x - st0.x!) * (pt.x - st0.x!) + (pt.y - st0.y!) * (pt.y - st0.y!);
            if (dd < bestDist) {
              bestDist = dd;
              bestAccum = accumulated + segLen * t;
            }
          }
          accumulated += segLen;
        }

        return (points: List.from(points), startOffset: bestAccum);
      }
    }
    return null;
  }

  /// DXF layers 리스트에 레이어 추가 (중복 무시)
  void _ensureDxfLayer(String layerName) {
    if (_dxfData == null) return;
    final layers = _dxfData!['layers'] as List;
    if (!layers.contains(layerName)) {
      layers.add(layerName);
    }
  }

  /// 옵셋 점 계산 (센터라인 위 해당 거리에서 법선 방향으로 offset만큼 이동)
  ({double x, double y})? _calcOffsetPoint(
    List<Map<String, dynamic>> clPoints, double dist, double offset, bool isLeft,
  ) {
    final pt = _pointOnCenterline(clPoints, dist);
    if (pt == null) return null;
    double sign = isLeft ? 1.0 : -1.0;
    return (x: pt.x + pt.nx * offset * sign, y: pt.y + pt.ny * offset * sign);
  }

  void _generateBaseline({required bool isLeft}) {
    final clData = _getCenterlineData();
    if (clData == null || clData.points.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('중심선 레이어를 찾을 수 없습니다')),
      );
      return;
    }
    final clPoints = clData.points;
    final clStartOffset = clData.startOffset;

    final stations = widget.stations;
    if (stations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('측점 데이터가 없습니다')),
      );
      return;
    }

    final lineLayer = isLeft ? '좌안기초라인' : '우안기초라인';
    final pointLayer = isLeft ? '좌안기초측점' : '우안기초측점';
    final crossLayer = isLeft ? '좌안기초횡단' : '우안기초횡단';
    const textLayer = '기초측점텍스트';
    // 좌안: 하늘색, 우안: 주황색
    final colorInt = isLeft ? 0xFF00BFFF : 0xFFFF8C00;

    final entities = _dxfData!['entities'] as List;

    // 기존 해당 레이어 엔티티 제거
    entities.removeWhere((e) =>
      e['layer'] == lineLayer || e['layer'] == pointLayer || e['layer'] == crossLayer);
    entities.removeWhere((e) =>
      e['layer'] == textLayer && e['_side'] == (isLeft ? 'L' : 'R'));

    // 레이어 등록
    for (final l in [lineLayer, pointLayer, crossLayer, textLayer]) {
      _ensureDxfLayer(l);
    }

    // 측점 정렬 (누가거리 순)
    final sorted = stations
        .where((s) => s.distance != null && (isLeft ? s.offsetLeft : s.offsetRight) != null)
        .toList()
      ..sort((a, b) => a.distance!.compareTo(b.distance!));

    if (sorted.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${isLeft ? "좌안" : "우안"} 옵셋 데이터가 없습니다')),
      );
      return;
    }

    // 연속 구간별로 폴리라인 분리 (25m 초과 간격이면 끊기)
    final segments = <List<({double x, double y, String label})>>[];
    var currentSeg = <({double x, double y, String label})>[];

    for (int i = 0; i < sorted.length; i++) {
      final st = sorted[i];
      final offset = isLeft ? st.offsetLeft! : st.offsetRight!;
      final actualDist = st.distance! + clStartOffset;
      final op = _calcOffsetPoint(clPoints, actualDist, offset, isLeft);
      if (op == null) continue;

      // 25m 초과 간격이면 새 구간
      if (currentSeg.isNotEmpty && i > 0) {
        final prevDist = sorted[i - 1].distance!;
        if (st.distance! - prevDist > 25.0) {
          segments.add(currentSeg);
          currentSeg = [];
        }
      }

      currentSeg.add((x: op.x, y: op.y, label: st.no));

      // 서클 (반지름 0.2m) - 좌안/우안 기초측점
      entities.add({
        'type': 'CIRCLE',
        'cx': op.x, 'cy': op.y,
        'radius': 0.2,
        'layer': pointLayer,
        'resolvedColor': colorInt,
        '_stationNo': st.no,
        '_dist': st.distance,
      });

      // 측점 텍스트 (아래쪽)
      entities.add({
        'type': 'TEXT',
        'x': op.x, 'y': op.y - 0.5,
        'text': st.no,
        'height': 0.8,
        'layer': textLayer,
        'resolvedColor': colorInt,
        '_side': isLeft ? 'L' : 'R',
      });

      // 횡단선: 센터라인측점에서 법선 방향으로 옵셋 거리만큼 직각선
      final clPt = _pointOnCenterline(clPoints, actualDist);
      if (clPt != null) {
        final s = isLeft ? 1.0 : -1.0;
        final crossX = clPt.x + clPt.nx * offset * s;
        final crossY = clPt.y + clPt.ny * offset * s;
        entities.add({
          'type': 'LINE',
          'x1': clPt.x, 'y1': clPt.y,
          'x2': crossX, 'y2': crossY,
          'layer': crossLayer,
          'resolvedColor': colorInt,
        });
      }
    }
    if (currentSeg.isNotEmpty) segments.add(currentSeg);

    // 각 연속 구간을 LWPOLYLINE으로
    int totalPoints = 0;
    for (final seg in segments) {
      if (seg.length < 2) continue;
      final polyPoints = seg
          .map((p) => <String, dynamic>{'x': p.x, 'y': p.y, 'bulge': 0.0})
          .toList();
      entities.add({
        'type': 'LWPOLYLINE',
        'points': polyPoints,
        'closed': false,
        'layer': lineLayer,
        'resolvedColor': colorInt,
      });
      totalPoints += seg.length;
    }

    // 센터라인측점 생성 (이 side의 측점들에 대해)
    _generateCenterlineStations(clPoints, clStartOffset, sorted);

    setState(() {
      _dxfRepaintVersion++;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(
        '${isLeft ? "좌안" : "우안"} 기초라인 생성 ($totalPoints점, ${segments.length}구간)')),
    );
  }

  /// 센터라인 위에 측점 서클 + 텍스트 생성
  void _generateCenterlineStations(
    List<Map<String, dynamic>> clPoints,
    double startOffset,
    List<StationData> stationsToMark,
  ) {
    final entities = _dxfData!['entities'] as List;
    const clPointLayer = '센터라인측점';
    const clTextLayer = '센터라인측점텍스트';
    const clColor = 0xFFFFFF00; // 노란색

    _ensureDxfLayer(clPointLayer);
    _ensureDxfLayer(clTextLayer);

    // 이미 추가된 센터라인측점의 거리 추적 (중복 방지)
    final existingDists = <double>{};
    for (final e in entities) {
      if (e['layer'] == clPointLayer && e['_dist'] != null) {
        existingDists.add((e['_dist'] as num).toDouble());
      }
    }

    for (final st in stationsToMark) {
      if (st.distance == null) continue;
      if (existingDists.contains(st.distance!)) continue;

      final pt = _pointOnCenterline(clPoints, st.distance! + startOffset);
      if (pt == null) continue;

      existingDists.add(st.distance!);

      // 서클 0.5m
      entities.add({
        'type': 'CIRCLE',
        'cx': pt.x, 'cy': pt.y,
        'radius': 0.5,
        'layer': clPointLayer,
        'resolvedColor': clColor,
        '_dist': st.distance,
        '_stationNo': st.no,
      });

      // 측점번호 텍스트
      entities.add({
        'type': 'TEXT',
        'x': pt.x, 'y': pt.y - 1.0,
        'text': st.no,
        'height': 0.8,
        'layer': clTextLayer,
        'resolvedColor': clColor,
        '_dist': st.distance,
      });
    }
  }

  /// 기초라인 보간 다이얼로그 표시
  void _showBaselineInterpolDialog() {
    // offsetLeft 또는 offsetRight가 있는 기본측점만 필터
    final validStations = widget.stations
        .where((s) => s.distance != null && (s.offsetLeft != null || s.offsetRight != null))
        .toList()
      ..sort((a, b) => a.distance!.compareTo(b.distance!));

    if (validStations.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('보간할 측점이 부족합니다 (최소 2개)')),
      );
      return;
    }

    StationData? startStation = validStations.first;
    StationData? endStation = validStations.length > 1 ? validStations[1] : null;
    double interval = 5.0;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          final startIdx = validStations.indexOf(startStation!);
          // 끝 측점 후보: 시작 이후 측점들
          final endCandidates = validStations.sublist(startIdx + 1);

          return AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('기초라인 보간', style: TextStyle(color: Colors.white)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('시작 측점', style: TextStyle(color: Colors.white70, fontSize: 12)),
                DropdownButton<StationData>(
                  value: startStation,
                  isExpanded: true,
                  dropdownColor: Colors.grey[800],
                  style: const TextStyle(color: Colors.white),
                  items: validStations.map((s) => DropdownMenuItem(
                    value: s,
                    child: Text('${s.no} (${s.distance!.toStringAsFixed(1)}m)'),
                  )).toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setDlgState(() {
                      startStation = v;
                      final newIdx = validStations.indexOf(v);
                      final newEnd = validStations.sublist(newIdx + 1);
                      if (newEnd.isNotEmpty) {
                        endStation = newEnd.first;
                      } else {
                        endStation = null;
                      }
                    });
                  },
                ),
                const SizedBox(height: 12),
                const Text('끝 측점', style: TextStyle(color: Colors.white70, fontSize: 12)),
                DropdownButton<StationData>(
                  value: endCandidates.contains(endStation) ? endStation : (endCandidates.isNotEmpty ? endCandidates.first : null),
                  isExpanded: true,
                  dropdownColor: Colors.grey[800],
                  style: const TextStyle(color: Colors.white),
                  items: endCandidates.map((s) => DropdownMenuItem(
                    value: s,
                    child: Text('${s.no} (${s.distance!.toStringAsFixed(1)}m)'),
                  )).toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setDlgState(() {
                      endStation = v;
                    });
                  },
                ),
                const SizedBox(height: 12),
                const Text('보간 간격 (m)', style: TextStyle(color: Colors.white70, fontSize: 12)),
                DropdownButton<double>(
                  value: interval,
                  isExpanded: true,
                  dropdownColor: Colors.grey[800],
                  style: const TextStyle(color: Colors.white),
                  items: const [
                    DropdownMenuItem(value: 2.0, child: Text('2m')),
                    DropdownMenuItem(value: 5.0, child: Text('5m')),
                    DropdownMenuItem(value: 10.0, child: Text('10m')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setDlgState(() { interval = v; });
                  },
                ),
                if (startStation != null && endStation != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '구간: ${(endStation!.distance! - startStation!.distance!).toStringAsFixed(1)}m, '
                      '보간점: ${((endStation!.distance! - startStation!.distance!) / interval).floor()}개',
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 12),
                    ),
                  ),
                // 기존 보간 구간 표시
                if (_baselineInterpolRanges.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('적용된 보간 구간:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  ..._baselineInterpolRanges.map((r) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${r.startDist.toStringAsFixed(1)}m ~ ${r.endDist.toStringAsFixed(1)}m (${r.interval.toStringAsFixed(0)}m)',
                            style: const TextStyle(color: Colors.amber, fontSize: 12),
                          ),
                        ),
                        GestureDetector(
                          onTap: () {
                            setDlgState(() {
                              _baselineInterpolRanges.remove(r);
                            });
                          },
                          child: const Icon(Icons.close, color: Colors.redAccent, size: 16),
                        ),
                      ],
                    ),
                  )),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              ElevatedButton(
                onPressed: (endStation != null && endCandidates.contains(endStation))
                    ? () {
                        Navigator.pop(ctx);
                        _applyBaselineInterpol(startStation!, endStation!, interval);
                      }
                    : null,
                child: const Text('보간 적용'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 기초라인 보간 적용: 구간 추가 후 기초라인 재생성
  void _applyBaselineInterpol(StationData start, StationData end, double interval) {
    final startDist = start.distance!;
    final endDist = end.distance!;

    // 이미 같은 구간이 있으면 제거 후 재등록
    _baselineInterpolRanges.removeWhere((r) =>
      r.startDist == startDist && r.endDist == endDist);
    _baselineInterpolRanges.add((startDist: startDist, endDist: endDist, interval: interval));

    // 기초라인 재생성 (보간 포함)
    _generateBaselineWithInterpol(isLeft: true);
    _generateBaselineWithInterpol(isLeft: false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(
        '보간 적용: ${startDist.toStringAsFixed(1)}m ~ ${endDist.toStringAsFixed(1)}m (${interval.toStringAsFixed(0)}m 간격)')),
    );
  }

  /// 보간을 포함한 기초라인 생성
  void _generateBaselineWithInterpol({required bool isLeft}) {
    final clData = _getCenterlineData();
    if (clData == null || clData.points.length < 2) return;
    final clPoints = clData.points;
    final clStartOffset = clData.startOffset;

    final stations = widget.stations;
    if (stations.isEmpty) return;

    final lineLayer = isLeft ? '좌안기초라인' : '우안기초라인';
    final pointLayer = isLeft ? '좌안기초측점' : '우안기초측점';
    final crossLayer = isLeft ? '좌안기초횡단' : '우안기초횡단';
    const textLayer = '기초측점텍스트';
    final colorInt = isLeft ? 0xFF00BFFF : 0xFFFF8C00;
    const interpolColor = 0xFF00FF80; // 보간점: 연두색

    final entities = _dxfData!['entities'] as List;

    // 기존 해당 레이어 엔티티 제거
    entities.removeWhere((e) =>
      e['layer'] == lineLayer || e['layer'] == pointLayer || e['layer'] == crossLayer);
    entities.removeWhere((e) =>
      e['layer'] == textLayer && e['_side'] == (isLeft ? 'L' : 'R'));

    for (final l in [lineLayer, pointLayer, crossLayer, textLayer]) {
      _ensureDxfLayer(l);
    }

    // 원본 측점 (offset 있는 것만)
    final sorted = stations
        .where((s) => s.distance != null && (isLeft ? s.offsetLeft : s.offsetRight) != null)
        .toList()
      ..sort((a, b) => a.distance!.compareTo(b.distance!));

    if (sorted.isEmpty) return;

    // 보간점 생성
    final interpolPoints = <({double dist, double offset, String label})>[];
    for (final range in _baselineInterpolRanges) {
      // 이 구간의 시작/끝 측점 찾기
      StationData? rangeStart, rangeEnd;
      for (final s in sorted) {
        if ((s.distance! - range.startDist).abs() < 0.01) rangeStart = s;
        if ((s.distance! - range.endDist).abs() < 0.01) rangeEnd = s;
      }
      if (rangeStart == null || rangeEnd == null) continue;

      final startOffset = isLeft ? rangeStart.offsetLeft : rangeStart.offsetRight;
      final endOffset = isLeft ? rangeEnd.offsetLeft : rangeEnd.offsetRight;
      if (startOffset == null || endOffset == null) continue;

      // 구간 내 기존 측점 수집 (보간 앵커로 사용)
      final anchors = sorted.where((s) =>
        s.distance! >= range.startDist - 0.01 && s.distance! <= range.endDist + 0.01
      ).toList();

      // 간격별 보간점 생성
      final totalLen = range.endDist - range.startDist;
      final step = range.interval;
      int count = (totalLen / step).floor();

      for (int i = 1; i <= count; i++) {
        final targetDist = range.startDist + step * i;
        if ((targetDist - range.endDist).abs() < 0.01) continue; // 끝점과 겹치면 스킵

        // 기존 측점과 겹치면 스킵
        bool exists = sorted.any((s) => (s.distance! - targetDist).abs() < 0.5);
        if (exists) continue;

        // 가장 가까운 앵커 사이에서 선형 보간
        StationData? before, after;
        for (final a in anchors) {
          if (a.distance! <= targetDist + 0.01) before = a;
        }
        for (final a in anchors.reversed) {
          if (a.distance! >= targetDist - 0.01) after = a;
        }
        if (before == null || after == null) continue;

        final bOff = isLeft ? before.offsetLeft! : before.offsetRight!;
        final aOff = isLeft ? after.offsetLeft! : after.offsetRight!;
        final ratio = (before.distance! == after.distance!)
            ? 0.0
            : (targetDist - before.distance!) / (after.distance! - before.distance!);
        final interpOffset = bOff + (aOff - bOff) * ratio;

        // 측점명: "No.X+Y.YY" 형식
        final baseNo = (targetDist ~/ 20) * 20;
        final plus = targetDist - baseNo.toDouble();
        final label = 'No.${baseNo ~/ 20}+${plus.toStringAsFixed(2)}';

        interpolPoints.add((dist: targetDist, offset: interpOffset, label: label));
      }
    }

    // 원본 + 보간점 합쳐서 정렬
    final allPoints = <({double dist, double offset, String label, bool isInterpol})>[];
    for (final st in sorted) {
      final off = isLeft ? st.offsetLeft! : st.offsetRight!;
      allPoints.add((dist: st.distance!, offset: off, label: st.no, isInterpol: false));
    }
    for (final ip in interpolPoints) {
      allPoints.add((dist: ip.dist, offset: ip.offset, label: ip.label, isInterpol: true));
    }
    allPoints.sort((a, b) => a.dist.compareTo(b.dist));

    // 연속 구간별 폴리라인 분리 (25m 초과 간격이면 끊기)
    final segments = <List<({double x, double y, String label, bool isInterpol})>>[];
    var currentSeg = <({double x, double y, String label, bool isInterpol})>[];

    for (int i = 0; i < allPoints.length; i++) {
      final p = allPoints[i];
      final actualDist = p.dist + clStartOffset;
      final op = _calcOffsetPoint(clPoints, actualDist, p.offset, isLeft);
      if (op == null) continue;

      if (currentSeg.isNotEmpty && i > 0) {
        final prevDist = allPoints[i - 1].dist;
        if (p.dist - prevDist > 25.0) {
          segments.add(currentSeg);
          currentSeg = [];
        }
      }

      currentSeg.add((x: op.x, y: op.y, label: p.label, isInterpol: p.isInterpol));

      // 서클
      entities.add({
        'type': 'CIRCLE',
        'cx': op.x, 'cy': op.y,
        'radius': p.isInterpol ? 0.15 : 0.2,
        'layer': pointLayer,
        'resolvedColor': p.isInterpol ? interpolColor : colorInt,
        '_stationNo': p.label,
        '_dist': p.dist,
      });

      // 텍스트 (보간점은 더 작게)
      entities.add({
        'type': 'TEXT',
        'x': op.x, 'y': op.y - 0.5,
        'text': p.label,
        'height': p.isInterpol ? 0.5 : 0.8,
        'layer': textLayer,
        'resolvedColor': p.isInterpol ? interpolColor : colorInt,
        '_side': isLeft ? 'L' : 'R',
      });

      // 횡단선
      final clPt = _pointOnCenterline(clPoints, actualDist);
      if (clPt != null) {
        entities.add({
          'type': 'LINE',
          'x1': clPt.x, 'y1': clPt.y,
          'x2': op.x, 'y2': op.y,
          'layer': crossLayer,
          'resolvedColor': p.isInterpol ? interpolColor : colorInt,
        });
      }
    }
    if (currentSeg.isNotEmpty) segments.add(currentSeg);

    // 폴리라인 생성
    for (final seg in segments) {
      if (seg.length < 2) continue;
      final polyPoints = seg
          .map((p) => <String, dynamic>{'x': p.x, 'y': p.y, 'bulge': 0.0})
          .toList();
      entities.add({
        'type': 'LWPOLYLINE',
        'points': polyPoints,
        'closed': false,
        'layer': lineLayer,
        'resolvedColor': colorInt,
      });
    }

    // 센터라인측점
    _generateCenterlineStations(clPoints, clStartOffset, sorted);

    setState(() {
      _dxfRepaintVersion++;
    });
  }

  // ── 노체포인트 생성 ──

  /// 직선 세그먼트와 레이(반직선)의 교차점
  /// ray: origin + t * dir (t >= 0)
  /// segment: p1 → p2
  /// 교차하면 교차점 반환, 아니면 null
  ({double x, double y, double t})? _raySegmentIntersect(
    double ox, double oy, double dx, double dy,
    double p1x, double p1y, double p2x, double p2y,
  ) {
    final ex = p2x - p1x;
    final ey = p2y - p1y;
    final denom = dx * ey - dy * ex;
    if (denom.abs() < 1e-12) return null; // 평행

    final t = ((p1x - ox) * ey - (p1y - oy) * ex) / denom;
    final s = ((p1x - ox) * dy - (p1y - oy) * dx) / denom;

    if (t < 0 || s < 0 || s > 1) return null;
    return (x: ox + t * dx, y: oy + t * dy, t: t);
  }

  /// 호(arc) 세그먼트와 레이의 교차점들
  List<({double x, double y, double t})> _rayArcIntersect(
    double ox, double oy, double dx, double dy,
    double p1x, double p1y, double p2x, double p2y, double bulge,
  ) {
    // bulge가 작으면 직선으로 처리 (arc 판별 오류 방지)
    if (bulge.abs() < 0.05) {
      final r = _raySegmentIntersect(ox, oy, dx, dy, p1x, p1y, p2x, p2y);
      return r != null ? [r] : [];
    }

    // 호 파라미터 계산
    final d = sqrt(pow(p2x - p1x, 2) + pow(p2y - p1y, 2));
    if (d < 1e-10) return [];
    final theta = 4.0 * atan(bulge);
    final r = (d / (2.0 * sin(theta / 2.0))).abs();
    final mx = (p1x + p2x) / 2.0;
    final my = (p1y + p2y) / 2.0;
    final ma = atan2(p2y - p1y, p2x - p1x);
    final cx = mx - r * cos(theta / 2.0) * sin(ma);
    final cy = my + r * cos(theta / 2.0) * cos(ma);

    // 레이-원 교차: |origin + t*dir - center|^2 = r^2
    final fx = ox - cx;
    final fy = oy - cy;
    final a = dx * dx + dy * dy;
    final b = 2.0 * (fx * dx + fy * dy);
    final c = fx * fx + fy * fy - r * r;
    final disc = b * b - 4.0 * a * c;
    if (disc < 0) return [];

    final results = <({double x, double y, double t})>[];
    final sqrtDisc = sqrt(disc);

    for (final sign in [-1.0, 1.0]) {
      final t = (-b + sign * sqrtDisc) / (2.0 * a);
      if (t < 0) continue;
      final ix = ox + t * dx;
      final iy = oy + t * dy;

      // 교차점이 호 범위 내인지 확인
      final ia = atan2(iy - cy, ix - cx);
      final sa = atan2(p1y - cy, p1x - cx);
      var ea = atan2(p2y - cy, p2x - cx);

      bool onArc;
      if (bulge > 0) {
        if (ea < sa) ea += 2.0 * pi;
        var nia = ia;
        if (nia < sa) nia += 2.0 * pi;
        onArc = nia >= sa - 1e-6 && nia <= ea + 1e-6;
      } else {
        if (ea > sa) ea -= 2.0 * pi;
        var nia = ia;
        if (nia > sa) nia -= 2.0 * pi;
        onArc = nia <= sa + 1e-6 && nia >= ea - 1e-6;
      }

      if (onArc) {
        results.add((x: ix, y: iy, t: t));
      }
    }
    return results;
  }

  /// 레이와 DXF 엔티티(LINE, LWPOLYLINE)의 교차점들
  List<({double x, double y, double t})> _rayEntityIntersections(
    double ox, double oy, double dx, double dy,
    Map<String, dynamic> entity,
  ) {
    final type = entity['type'] as String?;
    final results = <({double x, double y, double t})>[];

    if (type == 'LINE') {
      final x1 = (entity['x1'] as num).toDouble();
      final y1 = (entity['y1'] as num).toDouble();
      final x2 = (entity['x2'] as num).toDouble();
      final y2 = (entity['y2'] as num).toDouble();
      final r = _raySegmentIntersect(ox, oy, dx, dy, x1, y1, x2, y2);
      if (r != null) results.add(r);
    } else if (type == 'LWPOLYLINE') {
      final points = entity['points'] as List;
      final closed = entity['closed'] == true;
      final count = closed ? points.length : points.length - 1;
      for (int i = 0; i < count; i++) {
        final p1 = points[i] as Map<String, dynamic>;
        final p2 = points[(i + 1) % points.length] as Map<String, dynamic>;
        final bulge = ((p1['bulge'] as num?) ?? 0.0).toDouble();
        final x1 = (p1['x'] as num).toDouble();
        final y1 = (p1['y'] as num).toDouble();
        final x2 = (p2['x'] as num).toDouble();
        final y2 = (p2['y'] as num).toDouble();
        results.addAll(_rayArcIntersect(ox, oy, dx, dy, x1, y1, x2, y2, bulge));
      }
    }
    return results;
  }

  /// 노체포인트 생성 다이얼로그
  void _showLeveePointsDialog() {
    if (_dxfData == null) return;
    final allLayers = (_dxfData!['layers'] as List).cast<String>()
      ..sort();

    // 기본 선택: 제방상단 관련 레이어만 자동 선택 (제방하단 제외)
    final targetLayers = <String>{};
    for (final l in allLayers) {
      if ((l.contains('제방') || l.contains('LEVEE') || l.contains('BANK')) &&
          !l.contains('하단') && !l.contains('BOTTOM') && !l.contains('LOWER')) {
        targetLayers.add(l);
      }
    }

    final validStations = widget.stations
        .where((s) => s.distance != null)
        .toList()
      ..sort((a, b) => a.distance!.compareTo(b.distance!));
    if (validStations.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('측점 데이터가 부족합니다')),
      );
      return;
    }

    StationData startStation = validStations.first;
    StationData endStation = validStations.last;
    double nocheOffset = 0.6; // 노체 오프셋 (m)
    double minDist = 5.0; // 최소 교차 거리 (센터라인에서, m)
    bool connectLines = true;
    bool showCircles = true;
    bool showCrossLines = false; // 노체횡단라인
    int interpolInterval = 0; // 0=없음, 1=1m, 5=5m
    int color = 0xFFFF00FF; // 마젠타
    double lineWidth = 1.0;
    String outputLayer = '노체포인트';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) {
          return AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('노체포인트 생성', style: TextStyle(color: Colors.white, fontSize: 16)),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 교차 대상 레이어
                    const Text('교차 대상 레이어', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    const SizedBox(height: 4),
                    Container(
                      height: 120,
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey[700]!),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: ListView(
                        padding: EdgeInsets.zero,
                        children: allLayers.map((l) => CheckboxListTile(
                          dense: true,
                          visualDensity: VisualDensity.compact,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                          title: Text(l, style: const TextStyle(color: Colors.white, fontSize: 11)),
                          value: targetLayers.contains(l),
                          onChanged: (v) => setDlgState(() {
                            if (v == true) targetLayers.add(l);
                            else targetLayers.remove(l);
                          }),
                          activeColor: Colors.cyan,
                        )).toList(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // 시작/끝 측점
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('시작', style: TextStyle(color: Colors.white70, fontSize: 11)),
                              DropdownButton<StationData>(
                                value: startStation,
                                isExpanded: true,
                                dropdownColor: Colors.grey[800],
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                                items: validStations.map((s) => DropdownMenuItem(
                                  value: s, child: Text(s.no),
                                )).toList(),
                                onChanged: (v) { if (v != null) setDlgState(() => startStation = v); },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('끝', style: TextStyle(color: Colors.white70, fontSize: 11)),
                              DropdownButton<StationData>(
                                value: endStation,
                                isExpanded: true,
                                dropdownColor: Colors.grey[800],
                                style: const TextStyle(color: Colors.white, fontSize: 12),
                                items: validStations.map((s) => DropdownMenuItem(
                                  value: s, child: Text(s.no),
                                )).toList(),
                                onChanged: (v) { if (v != null) setDlgState(() => endStation = v); },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 최소 교차 거리
                    Row(
                      children: [
                        const Text('최소 거리', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        const SizedBox(width: 8),
                        Text('${minDist.toStringAsFixed(1)}m',
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                        const SizedBox(width: 8),
                        const Text('(가까운 엔티티 무시)', style: TextStyle(color: Colors.white38, fontSize: 10)),
                      ],
                    ),
                    Slider(
                      value: minDist,
                      min: 1.0, max: 30.0, divisions: 29,
                      onChanged: (v) => setDlgState(() => minDist = (v * 10).round() / 10.0),
                    ),
                    // 노체 오프셋
                    Row(
                      children: [
                        const Text('노체 오프셋', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        const SizedBox(width: 8),
                        Text('${nocheOffset.toStringAsFixed(2)}m',
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      value: nocheOffset,
                      min: 0.1, max: 2.0, divisions: 19,
                      onChanged: (v) => setDlgState(() => nocheOffset = (v * 100).round() / 100.0),
                    ),
                    const SizedBox(height: 8),
                    // 보간 간격
                    const Text('보간', style: TextStyle(color: Colors.white70, fontSize: 11)),
                    Row(
                      children: [
                        for (final iv in [(0, '없음'), (1, '1m'), (5, '5m')])
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(iv.$2, style: const TextStyle(fontSize: 11)),
                              selected: interpolInterval == iv.$1,
                              selectedColor: Colors.cyan,
                              onSelected: (_) => setDlgState(() => interpolInterval = iv.$1),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // 옵션 토글
                    Row(
                      children: [
                        Expanded(
                          child: CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('라인 연결', style: TextStyle(color: Colors.white, fontSize: 11)),
                            value: connectLines,
                            onChanged: (v) => setDlgState(() => connectLines = v ?? true),
                            activeColor: Colors.cyan,
                          ),
                        ),
                        Expanded(
                          child: CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text('서클 표시', style: TextStyle(color: Colors.white, fontSize: 11)),
                            value: showCircles,
                            onChanged: (v) => setDlgState(() => showCircles = v ?? true),
                            activeColor: Colors.cyan,
                          ),
                        ),
                      ],
                    ),
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('노체횡단라인 (센터→노체)', style: TextStyle(color: Colors.white, fontSize: 11)),
                      value: showCrossLines,
                      onChanged: (v) => setDlgState(() => showCrossLines = v ?? false),
                      activeColor: Colors.cyan,
                    ),
                    const SizedBox(height: 8),
                    // 색상
                    const Text('색상', style: TextStyle(color: Colors.white70, fontSize: 11)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        (0xFFFF0000, '빨강'), (0xFF00FF00, '초록'), (0xFF00FFFF, '시안'),
                        (0xFFFFFF00, '노랑'), (0xFFFF00FF, '마젠타'), (0xFFFF8000, '주황'),
                        (0xFFFFFFFF, '흰색'), (0xFF00FF80, '연두'),
                      ].map((c) => GestureDetector(
                        onTap: () => setDlgState(() => color = c.$1),
                        child: Container(
                          width: 24, height: 24,
                          decoration: BoxDecoration(
                            color: Color(c.$1),
                            border: Border.all(
                              color: color == c.$1 ? Colors.white : Colors.transparent, width: 2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      )).toList(),
                    ),
                    const SizedBox(height: 8),
                    // 선 두께
                    Row(
                      children: [
                        const Text('선 두께', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        const SizedBox(width: 8),
                        Text('${lineWidth.toStringAsFixed(1)}',
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                      ],
                    ),
                    Slider(
                      value: lineWidth, min: 0.5, max: 3.0, divisions: 10,
                      onChanged: (v) => setDlgState(() => lineWidth = (v * 4).round() / 4.0),
                    ),
                    // 레이어명
                    Row(
                      children: [
                        const Text('생성 레이어: ', style: TextStyle(color: Colors.white70, fontSize: 11)),
                        Expanded(
                          child: TextField(
                            controller: TextEditingController(text: outputLayer),
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) => outputLayer = v,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              ElevatedButton(
                onPressed: targetLayers.isEmpty ? null : () {
                  Navigator.pop(ctx);
                  _generateLeveePoints(
                    targetLayers: targetLayers,
                    startDist: startStation.distance!,
                    endDist: endStation.distance!,
                    nocheOffset: nocheOffset,
                    minDist: minDist,
                    connectLines: connectLines,
                    showCircles: showCircles,
                    showCrossLines: showCrossLines,
                    interpolInterval: interpolInterval,
                    color: color,
                    lineWidth: lineWidth,
                    outputLayer: outputLayer,
                  );
                },
                child: const Text('생성'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 노체포인트 생성 실행
  void _generateLeveePoints({
    required Set<String> targetLayers,
    required double startDist,
    required double endDist,
    required double nocheOffset,
    required double minDist,
    required bool connectLines,
    required bool showCircles,
    required bool showCrossLines,
    required int interpolInterval,
    required int color,
    required double lineWidth,
    required String outputLayer,
  }) {
    final clData = _getCenterlineData();
    if (clData == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('중심선을 찾을 수 없습니다')),
      );
      return;
    }
    final clPoints = clData.points;
    final clStartOffset = clData.startOffset;

    // 교차 대상 엔티티 수집
    final entities = _dxfData!['entities'] as List;
    final targetEntities = entities.where((e) {
      final layer = e['layer'] as String? ?? '';
      final type = e['type'] as String? ?? '';
      return targetLayers.contains(layer) &&
             (type == 'LINE' || type == 'LWPOLYLINE');
    }).toList();

    debugPrint('[노체] 대상 엔티티: ${targetEntities.length}개 (${targetEntities.map((e) => "${e['type']}:${(e['points'] as List?)?.length ?? 'line'}").join(", ")})');

    if (targetEntities.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('선택된 레이어에 LINE/POLYLINE이 없습니다')),
      );
      return;
    }

    // 처리할 거리 목록 생성
    final dMin = min(startDist, endDist);
    final dMax = max(startDist, endDist);
    final distances = <double>[];

    // 기본 측점 거리
    for (final st in widget.stations) {
      if (st.distance != null && st.distance! >= dMin - 0.01 && st.distance! <= dMax + 0.01) {
        distances.add(st.distance!);
      }
    }

    // 보간 거리 추가
    if (interpolInterval > 0) {
      final step = interpolInterval.toDouble();
      double d = (dMin / step).ceil() * step;
      while (d <= dMax + 0.01) {
        if (!distances.any((existing) => (existing - d).abs() < 0.5)) {
          distances.add(d);
        }
        d += step;
      }
    }
    distances.sort();

    if (distances.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('범위 내 측점이 없습니다')),
      );
      return;
    }

    // 레이어 등록
    _ensureDxfLayer(outputLayer);
    // 기존 해당 레이어 제거
    entities.removeWhere((e) => e['layer'] == outputLayer);

    // 각 측점에서 교차점 계산 (1번=안쪽, 2번=바깥쪽 제방상단)
    // 좌/우 × 1번/2번 = 4개 포인트 리스트
    final leftPts1 = <({double x, double y})>[];  // 좌안 1번(안쪽)
    final leftPts2 = <({double x, double y})>[];  // 좌안 2번(바깥쪽)
    final rightPts1 = <({double x, double y})>[]; // 우안 1번(안쪽)
    final rightPts2 = <({double x, double y})>[]; // 우안 2번(바깥쪽)

    int pointCount = 0;

    if (showCrossLines) _ensureDxfLayer('노체횡단라인');

    for (final dist in distances) {
      final actualDist = dist + clStartOffset;
      final clPt = _pointOnCenterline(clPoints, actualDist);
      if (clPt == null) continue;

      for (final isLeft in [true, false]) {
        final dirX = isLeft ? clPt.nx : -clPt.nx;
        final dirY = isLeft ? clPt.ny : -clPt.ny;

        // 모든 대상 엔티티와 교차점 구하기 (최소 거리 이상만)
        final hits = <({double x, double y, double t})>[];
        for (final ent in targetEntities) {
          for (final h in _rayEntityIntersections(clPt.x, clPt.y, dirX, dirY, ent)) {
            if (h.t >= minDist && h.t <= 30.0) hits.add(h);
          }
        }
        if (hits.isEmpty) continue;

        // t 기준 정렬 후 그룹핑 (2m 이내는 같은 제방상단으로 간주)
        hits.sort((a, b) => a.t.compareTo(b.t));
        final groups = <({double x, double y, double t})>[];
        for (final h in hits) {
          if (groups.isEmpty || (h.t - groups.last.t) > 2.0) {
            groups.add(h);
          }
        }

        debugPrint('[노체] dist=$dist ${isLeft?"좌":"우"} hits=${hits.length}→groups=${groups.length} t=[${groups.map((h)=>"${h.t.toStringAsFixed(2)}").join(", ")}]');

        // 1번 교차점 (안쪽 제방상단)
        if (groups.isEmpty) continue;
        final hit1 = groups[0];
        final noche1 = (x: hit1.x - dirX * nocheOffset,
                        y: hit1.y - dirY * nocheOffset);
        if (isLeft) { leftPts1.add(noche1); } else { rightPts1.add(noche1); }

        if (showCircles) {
          entities.add({
            'type': 'CIRCLE', 'cx': noche1.x, 'cy': noche1.y,
            'radius': 0.15, 'layer': outputLayer, 'resolvedColor': color,
          });
        }
        if (showCrossLines) {
          entities.add({
            'type': 'LINE',
            'x1': clPt.x, 'y1': clPt.y,
            'x2': noche1.x, 'y2': noche1.y,
            'layer': '노체횡단라인', 'resolvedColor': color, 'lw': lineWidth,
          });
        }
        pointCount++;

        // 2번 교차점 (바깥쪽 제방상단) — 그룹이 2개 이상일 때만
        if (groups.length >= 2) {
          final hit2 = groups[1];
          final noche2 = (x: hit2.x + dirX * nocheOffset,
                          y: hit2.y + dirY * nocheOffset);
          if (isLeft) { leftPts2.add(noche2); } else { rightPts2.add(noche2); }

          if (showCircles) {
            entities.add({
              'type': 'CIRCLE', 'cx': noche2.x, 'cy': noche2.y,
              'radius': 0.15, 'layer': outputLayer, 'resolvedColor': color,
            });
          }
          if (showCrossLines) {
            entities.add({
              'type': 'LINE',
              'x1': clPt.x, 'y1': clPt.y,
              'x2': noche2.x, 'y2': noche2.y,
              'layer': '노체횡단라인', 'resolvedColor': color, 'lw': lineWidth,
            });
          }
          pointCount++;
        }
      }
    }

    // 라인 연결 (1번끼리, 2번끼리 별도)
    if (connectLines) {
      for (final ptList in [leftPts1, leftPts2, rightPts1, rightPts2]) {
        if (ptList.length < 2) continue;
        final polyPoints = ptList
            .map((p) => <String, dynamic>{'x': p.x, 'y': p.y, 'bulge': 0.0})
            .toList();
        entities.add({
          'type': 'LWPOLYLINE',
          'points': polyPoints,
          'closed': false,
          'layer': outputLayer,
          'resolvedColor': color,
          'lw': lineWidth,
        });
      }
    }

    setState(() {
      _dxfRepaintVersion++;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('노체포인트 생성 완료 ($pointCount개)')),
    );
  }

  Future<void> _exportDxf() async {
    if (_dxfData == null) return;
    try {
      final bytes = await DxfService.exportDxfBytes(_dxfData!, _originalDxfBytes);
      if (bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('DXF 내보내기 실패')),
          );
        }
        return;
      }
      final dir = Directory('/storage/emulated/0/Download');
      if (!await dir.exists()) await dir.create(recursive: true);
      final timestamp = DateTime.now().toString().replaceAll(RegExp(r'[: ]'), '_').substring(0, 19);
      final filePath = '${dir.path}/export_$timestamp.dxf';
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      if (mounted) {
        // 저장 완료 후 선택: 공유 or 앱에서 열기
        final action = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.grey[850],
            title: const Text('DXF 저장 완료', style: TextStyle(color: Colors.white, fontSize: 16)),
            content: Text(filePath.split('/').last, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'open'),
                child: const Text('앱에서 열기'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'share'),
                child: const Text('공유'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('닫기', style: TextStyle(color: Colors.white54)),
              ),
            ],
          ),
        );
        if (action == 'share' && mounted) {
          await Share.shareXFiles(
            [XFile(filePath, mimeType: 'application/dxf')],
          );
        } else if (action == 'open' && mounted) {
          final rawBytes = await File(filePath).readAsBytes();
          final rawContent = DxfService.decodeDxfBytes(rawBytes);
          final data = DxfService.parseDxfContent(rawContent);
          if (data != null) {
            data['_originalEntityCount'] = (data['entities'] as List).length;
            setState(() {
              _dxfData = data;
              _originalDxfBytes = rawBytes;
              _hiddenLayers.clear();
              _applyDefaultHiddenLayers();
              _dxfRepaintVersion++;
            });
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('DXF 저장 오류: $e')),
        );
      }
    }
  }

  /// 레이어 삭제 확인 다이얼로그
  void _confirmDeleteLayer(String layerName, int entityCount) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('레이어 삭제', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          '"$layerName" 레이어와\n엔티티 ${entityCount}개를 삭제하시겠습니까?\n\n삭제 후 DXF 저장하면 원본에서도 제거됩니다.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteLayer(layerName);
            },
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  /// 레이어 삭제 실행
  void _deleteLayer(String layerName) {
    if (_dxfData == null || _originalDxfBytes == null) return;

    final result = DxfService.removeLayerFromBytes(_dxfData!, _originalDxfBytes!, layerName);
    if (result != null) {
      setState(() {
        _originalDxfBytes = result;
        _hiddenLayers.remove(layerName);
        _dxfRepaintVersion++;
      });
      _showStatusMessage('"$layerName" 레이어 삭제됨', Colors.orangeAccent);
    } else {
      _showStatusMessage('레이어 삭제 실패', Colors.red);
    }
  }

  /// 엔티티 삭제 (인덱스 기반)
  void _deleteEntity(int entityIndex) {
    if (_dxfData == null || _originalDxfBytes == null) return;

    final result = DxfService.removeEntityFromBytes(_dxfData!, _originalDxfBytes!, entityIndex);
    if (result != null) {
      setState(() {
        _originalDxfBytes = result;
        _dxfRepaintVersion++;
      });
      _showStatusMessage('엔티티 삭제됨', Colors.orangeAccent);
    } else {
      _showStatusMessage('엔티티 삭제 실패', Colors.red);
    }
  }

  /// 선택된 엔티티 삭제 확인
  void _confirmDeleteEntity(int entityIndex) {
    if (_dxfData == null) return;
    final entities = _dxfData!['entities'] as List;
    if (entityIndex < 0 || entityIndex >= entities.length) return;

    final entity = entities[entityIndex];
    final type = entity['type'] ?? '?';
    final layer = entity['layer'] ?? '?';

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[850],
        title: const Text('엔티티 삭제', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          '타입: $type\n레이어: $layer\n\n이 엔티티를 삭제하시겠습니까?',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _deleteEntity(entityIndex);
            },
            child: const Text('삭제', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  void _clearLeveePoints() {
    if (_dxfData == null) return;
    final entities = _dxfData!['entities'] as List;
    final layers = _dxfData!['layers'] as List;
    // 노체포인트 레이어 및 노체횡단라인 레이어 제거
    final leveeLayerNames = ['노체포인트', '노체횡단라인'];
    entities.removeWhere((e) => leveeLayerNames.contains(e['layer']));
    layers.removeWhere((l) => leveeLayerNames.contains(l));
    setState(() => _dxfRepaintVersion++);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('노체포인트 삭제 완료')),
    );
  }

  void _clearBaselines() {
    if (_dxfData == null) return;
    final entities = _dxfData!['entities'] as List;
    final layers = _dxfData!['layers'] as List;

    entities.removeWhere((e) => _baselineLayerNames.contains(e['layer']));
    layers.removeWhere((l) => _baselineLayerNames.contains(l));
    _baselineInterpolRanges.clear();

    setState(() {
      _dxfRepaintVersion++;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('기초라인 삭제 완료')),
    );
  }

  Widget _buildToolbarButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    VoidCallback? onLongPress,
    bool isActive = false,
    bool enabled = true,
    String? badge,
  }) {
    return Expanded(
      child: InkWell(
        onTap: enabled ? onPressed : null,
        onLongPress: enabled ? onLongPress : null,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: !enabled
                      ? Colors.grey[700]
                      : isActive
                          ? Colors.cyan
                          : Colors.white70,
                ),
                if (label.isNotEmpty)
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      color: !enabled
                          ? Colors.grey[700]
                          : isActive
                              ? Colors.cyan
                              : Colors.white60,
                    ),
                  ),
              ],
            ),
            if (badge != null)
              Positioned(
                top: 4,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.orange,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// DXF 도면 뷰 (레이어 패널 포함)
  Widget _buildDxfView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasSize = Size(constraints.maxWidth, constraints.maxHeight);

        // 화면 크기 변경 감지 (폴드 접기/펼치기 등)
        // 이전 화면 중앙의 DXF 좌표를 유지하도록 offset 재계산
        if (_lastCanvasSize != null &&
            _dxfData != null &&
            (_lastCanvasSize!.width - canvasSize.width).abs() > 1.0) {
          final oldSize = _lastCanvasSize!;
          final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
          final minX = bounds['minX'] as double;
          final minY = bounds['minY'] as double;
          final maxX = bounds['maxX'] as double;
          final maxY = bounds['maxY'] as double;
          final dxfW = maxX - minX;
          final dxfH = maxY - minY;
          if (dxfW > 0 && dxfH > 0) {
            // 이전 화면 중앙의 DXF 좌표
            final oldSX = oldSize.width * 0.9 / dxfW;
            final oldSY = oldSize.height * 0.9 / dxfH;
            final oldBase = oldSX < oldSY ? oldSX : oldSY;
            final oldScale = oldBase * _zoom;
            final oldCOffX = (oldSize.width - dxfW * oldScale) / 2;
            final oldCOffY = (oldSize.height - dxfH * oldScale) / 2;
            final cx = oldSize.width / 2;
            final cy = oldSize.height / 2;
            final dxfX = (cx - oldCOffX - _offset.dx) / oldScale + minX;
            final dxfY = (oldSize.height - cy - oldCOffY - _offset.dy) / oldScale + minY;

            // 새 화면에서 같은 DXF 좌표가 중앙에 오도록 offset 계산
            final newSX = canvasSize.width * 0.9 / dxfW;
            final newSY = canvasSize.height * 0.9 / dxfH;
            final newBase = newSX < newSY ? newSX : newSY;
            final newScale = newBase * _zoom;
            final newCOffX = (canvasSize.width - dxfW * newScale) / 2;
            final newCOffY = (canvasSize.height - dxfH * newScale) / 2;
            final newCx = canvasSize.width / 2;
            final newCy = canvasSize.height / 2;
            _offset = Offset(
              newCx - (dxfX - minX) * newScale - newCOffX,
              canvasSize.height - newCy - (dxfY - minY) * newScale - newCOffY,
            );
          }
          // 화면 크기 변경 시 제스처 상태 초기화
          _lastZoom = _zoom;
          _lastFocalPoint = Offset.zero;
          _isZoomWindowMode = false;
          _zoomWindowStart = null;
          _zoomWindowEnd = null;
        }

        _lastCanvasSize = canvasSize;

        return Stack(
          children: [
            // 도면 캔버스
            GestureDetector(
              onScaleStart: (details) {
                // 열린 패널 닫기
                if (_showLayerPanel || _showStationPanel) {
                  setState(() {
                    _showLayerPanel = false;
                    _showStationPanel = false;
                  });
                  return;
                }
                if (_activeDrawMode != null) {
                  _handleDrawTouch(details.localFocalPoint, canvasSize);
                } else if (_isSelectMode) {
                  if (_selectModeType == 'area') {
                    // 영역 선택: 시작점 설정
                    final dxf = _screenToDxf(SnapOverlayPainter.getCursorTip(details.localFocalPoint), canvasSize);
                    if (dxf != null) {
                      setState(() {
                        _areaSelectStart = dxf;
                        _areaSelectEnd = dxf;
                      });
                    }
                  } else if (_selectModeType == 'fence') {
                    // 펜스 선택: 터치로 꼭짓점 추가
                    _handleSelectTouch(details.localFocalPoint, canvasSize);
                  } else {
                    _handleSelectTouch(details.localFocalPoint, canvasSize);
                  }
                } else if (_isDimensionMode && _dimPending != null) {
                  // 치수 배치 단계: 스냅 없이 드래그
                  _handleDimPlacement(details.localFocalPoint, canvasSize);
                } else if (_isPointMode || _isDimensionMode) {
                  _handlePointTouch(details.localFocalPoint, canvasSize);
                } else if (_isZoomWindowMode) {
                  setState(() {
                    _zoomWindowStart = details.localFocalPoint;
                    _zoomWindowEnd = null;
                  });
                } else {
                  _lastFocalPoint = details.focalPoint;
                  _lastZoom = _zoom;
                }
              },
              onScaleUpdate: (details) {
                if (_activeDrawMode != null) {
                  _handleDrawTouch(details.localFocalPoint, canvasSize);
                } else if (_isSelectMode) {
                  if (_selectModeType == 'area' && _areaSelectStart != null) {
                    // 영역 선택: 드래그로 영역 업데이트
                    final dxf = _screenToDxf(SnapOverlayPainter.getCursorTip(details.localFocalPoint), canvasSize);
                    if (dxf != null) {
                      setState(() => _areaSelectEnd = dxf);
                    }
                  } else {
                    _handleSelectTouch(details.localFocalPoint, canvasSize);
                  }
                } else if (_isDimensionMode && _dimPending != null) {
                  // 치수 배치 단계: 드래그로 위치 조절
                  _handleDimPlacement(details.localFocalPoint, canvasSize);
                } else if (_isPointMode || _isDimensionMode) {
                  _handlePointTouch(details.localFocalPoint, canvasSize);
                } else if (_isZoomWindowMode) {
                  setState(() {
                    _zoomWindowEnd = details.localFocalPoint;
                  });
                } else {
                  setState(() {
                    // 팬 처리
                    final delta = details.focalPoint - _lastFocalPoint;
                    _offset += Offset(delta.dx, -delta.dy);
                    _lastFocalPoint = details.focalPoint;

                    // 핀치 줌 - 손가락 중심 기준
                    if (details.scale != 1.0) {
                      final newZoom = _lastZoom * details.scale;
                      final focalLocal = details.localFocalPoint;

                      // 현재 focal point의 DXF 좌표 계산
                      final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
                      final minX = bounds['minX'] as double;
                      final minY = bounds['minY'] as double;
                      final maxX = bounds['maxX'] as double;
                      final maxY = bounds['maxY'] as double;
                      final dxfW = maxX - minX;
                      final dxfH = maxY - minY;
                      final sX = canvasSize.width * 0.9 / dxfW;
                      final sY = canvasSize.height * 0.9 / dxfH;
                      final baseScale = sX < sY ? sX : sY;

                      final oldScale = baseScale * _zoom;
                      final cOffX = (canvasSize.width - dxfW * oldScale) / 2;
                      final cOffY = (canvasSize.height - dxfH * oldScale) / 2;
                      final dxfX = (focalLocal.dx - cOffX - _offset.dx) / oldScale + minX;
                      final dxfY = (canvasSize.height - focalLocal.dy - cOffY - _offset.dy) / oldScale + minY;

                      // 새 줌에서 같은 DXF 좌표가 같은 화면 위치에 오도록 오프셋 조정
                      final newScale = baseScale * newZoom;
                      final newCOffX = (canvasSize.width - dxfW * newScale) / 2;
                      final newCOffY = (canvasSize.height - dxfH * newScale) / 2;
                      _offset = Offset(
                        focalLocal.dx - (dxfX - minX) * newScale - newCOffX,
                        canvasSize.height - focalLocal.dy - (dxfY - minY) * newScale - newCOffY,
                      );
                      _zoom = newZoom;
                    }
                  });
                }
              },
              onScaleEnd: (details) {
                _edgePanDone = false; // 자동패닝 플래그 리셋
                if (_activeDrawMode != null) {
                  _handleDrawConfirm(canvasSize);
                } else if (_isSelectMode) {
                  if (_selectModeType == 'fence') {
                    // 펜스: 스냅 위치를 꼭짓점으로 추가
                    final snap = _activeSnap;
                    if (snap != null) {
                      setState(() {
                        _fencePoints.add((x: snap.dxfX, y: snap.dxfY));
                        _touchPoint = null;
                        _activeSnap = null;
                        _highlightEntity = null;
                      });
                    }
                  } else {
                    _handleSelectConfirm();
                  }
                } else if (_isDimensionMode) {
                  setState(() {
                    if (_dimPending != null) {
                      // 배치 확정 → 결과에 추가
                      final p = _dimPending!;
                      final dimResult = DimensionResult(
                        id: DimensionResult.generateId(),
                        type: p.type,
                        x1: p.x1, y1: p.y1,
                        x2: p.x2, y2: p.y2,
                        x3: p.x3, y3: p.y3,
                        value: p.value,
                        offsetX: _dimPlacementDxf!.dx,
                        offsetY: _dimPlacementDxf!.dy,
                        style: _dimStyle,
                      );
                      _dimResults.add(dimResult);
                      _pushUndo(_UndoAction(_UndoType.addDimension, dimResult));
                      _dimPending = null;
                      _dimPlacementDxf = null;
                      _dimFirstPoint = null;
                      _dimSecondPoint = null;
                      _isDimensionMode = false;
                    } else if (_activeSnap != null) {
                      _handleDimSnapConfirm();
                    } else {
                      // 스냅 없이 손 뗌 → 취소: 중간 상태 초기화, 모드 비활성
                      _dimPending = null;
                      _dimPlacementDxf = null;
                      _dimFirstPoint = null;
                      _dimSecondPoint = null;
                      _isDimensionMode = false;
                    }
                    _touchPoint = null;
                    _activeSnap = null;
                    _highlightEntity = null;
                    _cursorTipDxf = null;
                  });
                } else if (_isPointMode) {
                  // 포인트 모드: 스냅 성공 시 포인트 확정 + 측설 진입
                  setState(() {
                    if (_activeSnap != null) {
                      final pt = (
                        type: _activeSnap!.type,
                        dxfX: _activeSnap!.dxfX,
                        dxfY: _activeSnap!.dxfY,
                      );
                      _confirmedPoints.add(pt);
                      _pushUndo(_UndoAction(_UndoType.addPoint, pt));
                      // 측설 대상으로 설정 (GPS 연결 여부 무관)
                      final snapName = _activeSnap!.entity['text'] as String? ??
                          'P${_confirmedPoints.length}';
                      _stakeoutTarget = (dxfX: _activeSnap!.dxfX, dxfY: _activeSnap!.dxfY, name: snapName);
                      // GPS 연결 시 GPS위치와 포인트위치가 도면뷰에 가득 차도록 줌
                      if (_gnssService.position != null) {
                        _zoomToFitGpsAndPoint(_activeSnap!.dxfX, _activeSnap!.dxfY);
                      }
                    }
                    _isPointMode = false;
                    _touchPoint = null;
                    _activeSnap = null;
                    _highlightEntity = null;
                    _cursorTipDxf = null;
                  });
                } else if (_isZoomWindowMode && _zoomWindowStart != null && _zoomWindowEnd != null) {
                  _applyZoomWindow();
              
                } else {
                  // 팬/줌 끝 → 가장 가까운 측점 싱크 + Picture 캐시 빌드
                  _syncNearestStation(canvasSize);
              
                }
              },
              child: Stack(
                children: [
                  RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: DxfPainter(
                        entities: _dxfData!['entities'],
                        bounds: _dxfData!['bounds'],
                        zoom: _zoom,
                        offset: _offset,
                        hiddenLayers: Set.of(_hiddenLayers),
                        repaintVersion: _dxfRepaintVersion,
                      ),
                    ),
                  ),
                  // 영역 확대 사각형
                  if (_isZoomWindowMode && _zoomWindowStart != null && _zoomWindowEnd != null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: ZoomWindowPainter(
                        start: _zoomWindowStart!,
                        end: _zoomWindowEnd!,
                      ),
                    ),
                  // 다중 선택 모드: 선택 개수 + 속성 열기 버튼
                  if (_isSelectMode && _selectModeType == 'multi' && _selectedEntities.isNotEmpty)
                    Positioned(
                      top: 8,
                      left: 60,
                      right: 60,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '${_selectedEntities.length}개 선택됨',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: () => setState(() => _showPropertyPanel = true),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.cyan,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text('속성', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                              ),
                            ),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () => setState(() {
                                _showPropertyPanel = true;
                                _selectModeType = 'single';
                              }),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.green,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text('완료', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                              ),
                            ),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () => setState(() {
                                _selectedEntities.clear();
                                _showPropertyPanel = false;
                              }),
                              child: const Icon(Icons.clear_all, color: Colors.white54, size: 18),
                            ),
                          ],
                        ),
                      ),
                    ),
                  // 선택 모드 안내 + 펜스 확정 버튼
                  if (_isSelectMode && (_selectModeType == 'area' || _selectModeType == 'fence'))
                    Positioned(
                      top: 8,
                      left: 60,
                      right: 60,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              _selectModeType == 'area' ? Icons.crop_square : Icons.polyline,
                              color: Colors.white70, size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _selectModeType == 'area'
                                  ? '드래그하여 영역 선택'
                                  : '펜스 꼭짓점: ${_fencePoints.length}개',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                            if (_selectModeType == 'fence' && _fencePoints.length >= 2) ...[
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => _handleFenceSelectConfirm(),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.orange,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text('확정', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ],
                            if (_selectModeType == 'fence' && _fencePoints.isNotEmpty) ...[
                              const SizedBox(width: 4),
                              GestureDetector(
                                onTap: () => setState(() => _fencePoints.clear()),
                                child: const Icon(Icons.undo, color: Colors.white54, size: 16),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  // 영역 선택 사각형
                  if (_selectModeType == 'area' && _areaSelectStart != null && _areaSelectEnd != null && _getTransformPoint(canvasSize) != null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: _AreaSelectPainter(
                        start: _areaSelectStart!,
                        end: _areaSelectEnd!,
                        transformPoint: _getTransformPoint(canvasSize)!,
                      ),
                    ),
                  // 펜스 선택 라인
                  if (_selectModeType == 'fence' && _fencePoints.isNotEmpty && _getTransformPoint(canvasSize) != null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: _FenceSelectPainter(
                        points: _fencePoints,
                        transformPoint: _getTransformPoint(canvasSize)!,
                      ),
                    ),
                  // 사용자 추가 엔티티 (LINE, LEADER, TEXT)
                  if (_userEntities.isNotEmpty && _getTransformPoint(canvasSize) != null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: UserEntityPainter(
                        userEntities: _userEntities,
                        transformPoint: _getTransformPoint(canvasSize)!,
                      ),
                    ),
                  // 선택된 엔티티 하이라이트
                  if (_selectedEntities.isNotEmpty && _getTransformPoint(canvasSize) != null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: SelectionHighlightPainter(
                        selectedEntities: _selectedEntities,
                        transformPoint: _getTransformPoint(canvasSize)!,
                        scale: _getCurrentScale(canvasSize),
                      ),
                    ),
                  // 확정된 포인트 표식 (DXF 좌표 기반 → 줌/팬 유지)
                  if (_confirmedPoints.isNotEmpty)
                    CustomPaint(
                      size: Size.infinite,
                      painter: ConfirmedPointsPainter(
                        points: _confirmedPoints,
                        transformPoint: _getTransformPoint(canvasSize),
                      ),
                    ),
                  // GPS 위치 마커 + 측설 타겟
                  if (_gnssService.position != null && _getTransformPoint(canvasSize) != null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: GpsPositionPainter(
                        tmX: _gnssService.position!.tmX,
                        tmY: _gnssService.position!.tmY,
                        fixQuality: _gnssService.position!.fixQuality,
                        transformPoint: _getTransformPoint(canvasSize)!,
                        targetDxfX: _stakeoutTarget?.dxfX,
                        targetDxfY: _stakeoutTarget?.dxfY,
                      ),
                    ),
                  // 치수 측정 결과 (치수선 + 거리 + 보조선)
                  if (_dimResults.isNotEmpty || _dimFirstPoint != null || _dimPending != null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: DimensionPainter(
                        results: _dimResults,
                        firstPoint: _dimFirstPoint,
                        secondPoint: _dimSecondPoint,
                        pending: _dimPending,
                        placementDxf: _dimPlacementDxf,
                        transformPoint: _getTransformPoint(canvasSize),
                        defaultStyle: _dimStyle,
                        selectedDimIndex: _selectedDimIndex,
                      ),
                    ),
                  // 포인트/치수/그리기/선택 모드 커서 + 스냅 오버레이 (배치 단계에서는 숨김)
                  if ((_isPointMode || _isDimensionMode || _activeDrawMode != null || _isSelectMode) && _touchPoint != null && _dimPending == null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: SnapOverlayPainter(
                        touchPoint: _touchPoint,
                        activeSnap: _activeSnap,
                        highlightEntity: _highlightEntity,
                        transformPoint: _getTransformPoint(canvasSize),
                        scale: _getCurrentScale(canvasSize),
                      ),
                    ),
                  // 하이라이트 엔티티 정보 표시
                  if (_isSelectMode && _highlightEntity != null && _touchPoint != null)
                    Positioned(
                      left: 8,
                      top: _selectModeType == 'multi' || _selectModeType == 'area' || _selectModeType == 'fence' ? 44 : 8,
                      child: IgnorePointer(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.cyan.withValues(alpha: 0.5)),
                          ),
                          child: Text(
                            _getEntityInfoText(_highlightEntity!),
                            style: const TextStyle(color: Colors.white, fontSize: 11, height: 1.3),
                          ),
                        ),
                      ),
                    ),
                  // 확대 원 (치수/포인트/그리기/선택 모드 터치 중, 배치 단계 제외)
                  if ((_isDimensionMode || _isPointMode || _activeDrawMode != null || _isSelectMode) && _touchPoint != null && _cursorTipDxf != null && _cursorTipScreen != null && _dimPending == null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: MagnificationPainter(
                        cursorTipDxf: _cursorTipDxf!,
                        cursorTipScreen: _cursorTipScreen!,
                        entities: _dxfData!['entities'] as List,
                        bounds: _dxfData!['bounds'] as Map<String, dynamic>,
                        hiddenLayers: Set.of(_hiddenLayers),
                        zoom: _zoom,
                        viewScale: _getCurrentScale(MediaQuery.of(context).size),
                        activeSnap: _activeSnap,
                      ),
                    ),
                ],
              ),
            ),
            // GPS 연결 상태 오버레이 (토글)
            if (_showInfoPanel && _gnssService.connectionState != GnssConnectionState.disconnected)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 10, color: _getGpsIconColor()),
                          const SizedBox(width: 6),
                          Text(
                            _gnssService.connectionState == GnssConnectionState.connecting
                                ? '연결 중...'
                                : _gnssService.connectionState == GnssConnectionState.error
                                    ? '연결 오류'
                                    : '${_getFixStatusText()}  위성 ${_gnssService.satellites}',
                            style: TextStyle(
                              color: _getGpsIconColor(),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      if (_gnssService.position != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          '중부원점  X ${_gnssService.position!.tmX.toStringAsFixed(4)}',
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '중부원점  Y ${_gnssService.position!.tmY.toStringAsFixed(4)}',
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'WGS  ${_gnssService.position!.latitude.toStringAsFixed(7)},  ${_gnssService.position!.longitude.toStringAsFixed(7)}',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        if (_gnssService.position!.altitude != null)
                          Text(
                            'H  ${_gnssService.position!.altitude!.toStringAsFixed(4)} m',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                      ],
                      // NTRIP 상태
                      if (_ntripService.isConnected || _ntripService.state == NtripState.connecting || _ntripService.state == NtripState.error) ...[
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.cell_tower,
                              size: 10,
                              color: _ntripService.isConnected ? Colors.greenAccent : Colors.orange,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _ntripService.state == NtripState.connecting
                                  ? 'NTRIP 연결중...'
                                  : _ntripService.state == NtripState.error
                                      ? 'NTRIP 오류'
                                      : 'NTRIP ${(_ntripService.bytesReceived / 1024).toStringAsFixed(1)}KB→BT${(_gnssService.rtcmBytesSent / 1024).toStringAsFixed(1)}KB${_ntripService.hasReceivedMsm ? " MSM✓" : _ntripService.bytesReceived > 0 ? " MSM✗" : ""}${_gnssService.rtcmFlushErrors > 0 ? " E${_gnssService.rtcmFlushErrors}" : ""}',
                              style: TextStyle(
                                color: _ntripService.isConnected ? Colors.greenAccent : Colors.orange,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            // 상단 HUD (안테나높이, 포인트명, 거리, 방향) — GPS 연결 시만 표시
            if (_gnssService.connectionState != GnssConnectionState.disconnected)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _buildStakeoutTopPanel(),
              ),
            // 하단 HUD (좌표, 높이, PDOP, 시간지연, 거리) — 인포 패널 토글
            if (_showInfoPanel)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildStakeoutBottomPanel(),
              ),
            // 포인트/치수 모드 안내 표시
            if (_isPointMode || _isDimensionMode)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: (_isDimensionMode ? Colors.orange : Colors.cyan).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _isDimensionMode
                          ? _getDimensionBannerText()
                          : _activeSnap != null
                              ? '${_snapTypeName(_activeSnap!.type)}  (${_activeSnap!.dxfX.toStringAsFixed(3)}, ${_activeSnap!.dxfY.toStringAsFixed(3)})'
                              : '포인트 지정 모드 - 도면을 터치하세요',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
            // 그리기/선택 모드 안내 배너
            if (_activeDrawMode != null || _isSelectMode)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: (_isSelectMode ? Colors.purple : Colors.green).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _isSelectMode
                          ? '선택 모드 - 엔티티를 터치하세요 (${_selectedEntities.length}개 선택)'
                          : _activeDrawMode == 'point'
                              ? '포인트 - 위치를 터치하세요'
                              : _activeDrawMode == 'line'
                                  ? _drawFirstPoint == null ? '라인 - 시작점을 터치하세요' : '라인 - 끝점을 터치하세요'
                                  : _activeDrawMode == 'leader'
                                      ? _leaderPoints.isEmpty ? '지시선 - 화살촉 위치를 터치하세요' : '지시선 - 끝점을 터치하세요 (${_leaderPoints.length}점)'
                                      : '텍스트 - 위치를 터치하세요',
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ),
            // 속성 편집 패널
            _buildPropertyPanel(),
            // 레이어 패널 (하단에서 슬라이드 업)
            if (_showLayerPanel) _buildLayerPanel(),
            // 치수 관리 패널
            if (_showDimPanel) _buildDimListPanel(),
            // 치수 스타일 설정 패널
            if (_showDimStylePanel) _buildDimStylePanel(),
          ],
        );
      },
    );
  }

  String _snapTypeName(SnapType type) {
    switch (type) {
      case SnapType.endpoint:      return 'END';
      case SnapType.midpoint:      return 'MID';
      case SnapType.center:        return 'CEN';
      case SnapType.node:          return 'NOD';
      case SnapType.quadrant:      return 'QUA';
      case SnapType.intersection:  return 'INT';
      case SnapType.insertion:     return 'INS';
      case SnapType.perpendicular: return 'PER';
      case SnapType.tangent:       return 'TAN';
      case SnapType.nearest:       return 'NEA';
    }
  }

  String _getDimensionBannerText() {
    final typeName = _getDimTypeLabel(_activeDimType);

    if (_dimPending != null) {
      final pendingTypeName = _getDimTypeLabel(_dimPending!.type);
      return '$pendingTypeName 배치 - 드래그하여 위치를 지정하세요';
    }

    if (_activeDimType == DimensionType.angular) {
      if (_activeSnap != null) {
        String prefix;
        if (_dimFirstPoint == null) {
          prefix = '방향점1';
        } else if (_dimSecondPoint == null) {
          prefix = '꼭짓점';
        } else {
          prefix = '방향점2';
        }
        return '$typeName $prefix ${_snapTypeName(_activeSnap!.type)}  (${_activeSnap!.dxfX.toStringAsFixed(3)}, ${_activeSnap!.dxfY.toStringAsFixed(3)})';
      }
      if (_dimFirstPoint == null) return '$typeName - 방향점1을 터치하세요';
      if (_dimSecondPoint == null) return '$typeName - 꼭짓점을 터치하세요';
      return '$typeName - 방향점2를 터치하세요';
    }

    if (_activeSnap != null) {
      final prefix = _dimFirstPoint == null ? '1점' : '2점';
      return '$typeName $prefix ${_snapTypeName(_activeSnap!.type)}  (${_activeSnap!.dxfX.toStringAsFixed(3)}, ${_activeSnap!.dxfY.toStringAsFixed(3)})';
    }
    if (_dimFirstPoint == null) return '$typeName - 첫번째 점을 터치하세요';
    return '$typeName - 두번째 점을 터치하세요';
  }

  /// 측설 상단 HUD — 안테나높이, 측점선택, 포인트명, 거리, N/S E/W 방향
  Widget _buildStakeoutTopPanel() {
    final pos = _gnssService.position;
    final target = _stakeoutTarget;
    final isFixed = _gnssService.fixQuality == 4;
    final hasData = pos != null && target != null && isFixed;
    final dE = hasData ? target.dxfX - pos.tmX : 0.0;
    final dN = hasData ? target.dxfY - pos.tmY : 0.0;
    final distance = hasData ? sqrt(dE * dE + dN * dN) : 0.0;

    // 두 방향 성분 (타겟까지 남은 거리의 N/S, E/W)
    final nsLabel = dN >= 0 ? '북(N)' : '남(S)';
    final ewLabel = dE >= 0 ? '동(E)' : '서(W)';

    // Fix 상태 텍스트
    String fixStatusText() {
      if (pos == null) return 'GPS 미연결';
      switch (_gnssService.fixQuality) {
        case 4: return '';
        case 5: return 'Float - 픽스 대기중...';
        case 2: return 'DGPS - 픽스 대기중...';
        case 1: return '단독측위 - 픽스 대기중...';
        default: return '위성 탐색중...';
      }
    }

    const dp = 4;
    const labelStyle = TextStyle(color: Colors.black, fontSize: 18, fontWeight: FontWeight.bold);
    const valueStyle = TextStyle(color: Colors.black, fontSize: 18);
    return SafeArea(
      bottom: false,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1줄: 안테나높이 + 측점선택 + 포인트명
            Row(
              children: [
                Text(
                  '안테나높이 ${_antennaHeight.toStringAsFixed(dp)}M',
                  style: labelStyle,
                ),
                if (_stationsWithCoords.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  _buildStationDropdown(),
                ],
                const Spacer(),
                Text(
                  target?.name ?? '포인트 미선택',
                  style: labelStyle,
                ),
              ],
            ),
            // GPS 높이 표시 (해발고도 + 안테나높이)
            if (pos != null && pos.altitude != null)
              Row(
                children: [
                  Text(
                    '지반고 ${(pos.altitude! + _antennaHeight).toStringAsFixed(3)}m',
                    style: valueStyle,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '(해발 ${pos.altitude!.toStringAsFixed(3)}m + 안테나 ${_antennaHeight}m)',
                    style: TextStyle(color: Colors.black54, fontSize: 13),
                  ),
                ],
              ),
            const SizedBox(height: 2),
            // 2줄: 포인트+Fix → 거리+방향, 포인트+미Fix → 상태, GPS만 → 좌표, 없음 → 미연결
            if (target != null && hasData) Row(
              children: [
                Text(
                  '거리 ${distance.toStringAsFixed(dp)}',
                  style: labelStyle,
                ),
                const SizedBox(width: 16),
                Text(
                  '$nsLabel ${dN.abs().toStringAsFixed(dp)}',
                  style: valueStyle,
                ),
                const SizedBox(width: 16),
                Text(
                  '$ewLabel ${dE.abs().toStringAsFixed(dp)}',
                  style: valueStyle,
                ),
              ],
            ) else if (target != null && !isFixed) Row(
              children: [
                Text(
                  fixStatusText(),
                  style: TextStyle(color: Colors.red, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ) else if (pos != null && isFixed) Row(
              children: [
                Text(
                  'N ${pos.tmY.toStringAsFixed(dp)}',
                  style: valueStyle,
                ),
                const SizedBox(width: 16),
                Text(
                  'E ${pos.tmX.toStringAsFixed(dp)}',
                  style: valueStyle,
                ),
              ],
            ) else Row(
              children: [
                Text(
                  fixStatusText(),
                  style: TextStyle(color: pos != null ? Colors.orange : Colors.grey, fontSize: 18),
                ),
              ],
            ),
            // 3줄: 위성수, Fix상태, PDOP (GPS 연결 시 항상 표시)
            if (_gnssService.connectionState == GnssConnectionState.connected)
              Row(
                children: [
                  Icon(
                    Icons.satellite_alt,
                    size: 16,
                    color: isFixed ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${_gnssService.satellites}위성',
                    style: TextStyle(fontSize: 14, color: Colors.black87),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: isFixed ? Colors.green : (_gnssService.fixQuality == 5 ? Colors.orange : Colors.red),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isFixed ? 'RTK Fix' : (_gnssService.fixQuality == 5 ? 'Float' : _gnssService.fixQuality == 2 ? 'DGPS' : _gnssService.fixQuality >= 1 ? 'GPS' : 'No Fix'),
                      style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (_gnssService.pdop != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      'PDOP ${_gnssService.pdop!.toStringAsFixed(1)}',
                      style: TextStyle(fontSize: 14, color: _gnssService.pdop! <= 2.0 ? Colors.green : _gnssService.pdop! <= 4.0 ? Colors.orange : Colors.red),
                    ),
                  ],
                  if (pos?.hdop != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      'HDOP ${pos!.hdop!.toStringAsFixed(1)}',
                      style: TextStyle(fontSize: 14, color: pos.hdop! <= 1.5 ? Colors.green : pos.hdop! <= 3.0 ? Colors.orange : Colors.red),
                    ),
                  ],
                ],
              ),
            // 측점 패널 (펼침 시)
            if (_showStationPanel)
              Container(
                constraints: const BoxConstraints(maxHeight: 160),
                padding: const EdgeInsets.only(top: 6),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _baseStationsWithCoords.map((station) {
                      final isSelected = _selectedStation?.no == station.no;
                      final label = _shortStationNo(station.no);
                      return GestureDetector(
                        onTap: () {
                          _goToStation(station);
                          setState(() => _showStationPanel = false);
                        },
                        child: Container(
                          width: 40,
                          height: 32,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isSelected ? Colors.cyan : Colors.grey[300],
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 12,
                              color: isSelected ? Colors.white : Colors.black87,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 측점 드롭다운 버튼 (상단 HUD 내)
  Widget _buildStationDropdown() {
    return GestureDetector(
      onTap: () => setState(() => _showStationPanel = !_showStationPanel),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey[400]!),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_on, color: Colors.cyan, size: 16),
            const SizedBox(width: 4),
            Text(
              _selectedStation != null
                  ? _shortStationNo(_selectedStation!.no)
                  : '측점',
              style: const TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.bold),
            ),
            Icon(
              _showStationPanel ? Icons.expand_less : Icons.expand_more,
              color: Colors.black54,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }

  /// 하단 HUD — GPS 좌표, 높이, PDOP, 시간지연, 거리
  Widget _buildStakeoutBottomPanel() {
    final pos = _gnssService.position;
    final target = _stakeoutTarget;
    final hasPos = pos != null;
    final hasData = hasPos && target != null;
    final dE = hasData ? target.dxfX - pos.tmX : 0.0;
    final dN = hasData ? target.dxfY - pos.tmY : 0.0;
    final distance = hasData ? sqrt(dE * dE + dN * dN) : 0.0;

    const dp = 4;
    final dash = '-.----';
    const s = TextStyle(color: Colors.black, fontSize: 13);

    // 현재 GPS TM 좌표 (Northing, Easting)
    final northing = pos?.tmY;
    final easting = pos?.tmX;
    final altitude = pos?.altitude;
    final pdop = _gnssService.pdop;
    final diffAge = pos?.diffAge;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1줄: N(북) 좌표, E(동) 좌표
            Row(
              children: [
                Text(
                  '북(N) ${northing?.toStringAsFixed(dp) ?? dash}',
                  style: s,
                ),
                const SizedBox(width: 12),
                Text(
                  '동(E) ${easting?.toStringAsFixed(dp) ?? dash}',
                  style: s,
                ),
              ],
            ),
            const SizedBox(height: 2),
            // 2줄: 높이, PDOP, 시간지연, 거리
            Row(
              children: [
                Text(
                  '높이 ${altitude?.toStringAsFixed(dp) ?? dash}',
                  style: s,
                ),
                const SizedBox(width: 8),
                Text(
                  'PDOP ${pdop?.toStringAsFixed(dp) ?? dash}',
                  style: s,
                ),
                const SizedBox(width: 8),
                Text(
                  '시간지연 ${diffAge?.toStringAsFixed(dp) ?? dash}',
                  style: s,
                ),
                const SizedBox(width: 8),
                Text(
                  '거리 ${hasData ? distance.toStringAsFixed(dp) : dash}',
                  style: s,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 레이어 설정 다이얼로그 (색상, 선 굵기)
  void _showLayerSettingsDialog(String layer) {
    final style = _layerStyles[layer] ?? {};
    double lw = (style['lw'] as double?) ?? 1.0;
    int? colorVal = style['color'] as int?;

    final presetColors = [
      (0xFFFFFFFF, '흰색'),
      (0xFFFF0000, '빨강'),
      (0xFFFF8C00, '주황'),
      (0xFFFFFF00, '노랑'),
      (0xFF7CFC00, '연두'),
      (0xFF00FF00, '초록'),
      (0xFF00BFFF, '하늘'),
      (0xFF0000FF, '파랑'),
      (0xFFFF00FF, '보라'),
      (0xFFFF69B4, '분홍'),
    ];

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.grey[850],
              title: Text(layer, style: const TextStyle(color: Colors.white, fontSize: 14)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('색상', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // 기본값 (원래 색상)
                      GestureDetector(
                        onTap: () => setDialogState(() => colorVal = null),
                        child: Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: colorVal == null ? Colors.cyan : Colors.grey,
                              width: colorVal == null ? 2 : 1,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Center(
                            child: Text('원본', style: TextStyle(color: Colors.white54, fontSize: 8)),
                          ),
                        ),
                      ),
                      ...presetColors.map((c) => GestureDetector(
                        onTap: () => setDialogState(() => colorVal = c.$1),
                        child: Container(
                          width: 28, height: 28,
                          decoration: BoxDecoration(
                            color: Color(c.$1),
                            border: Border.all(
                              color: colorVal == c.$1 ? Colors.cyan : Colors.transparent,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      )),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('선 굵기: ${lw.toStringAsFixed(1)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  Slider(
                    value: lw,
                    min: 0.5,
                    max: 5.0,
                    divisions: 9,
                    onChanged: (v) => setDialogState(() => lw = v),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    // 스타일 초기화
                    setState(() {
                      _layerStyles.remove(layer);
                      _dxfRepaintVersion++;
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text('초기화'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('취소'),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _layerStyles[layer] = {
                        if (colorVal != null) 'color': colorVal,
                        'lw': lw,
                      };
                      _dxfRepaintVersion++;
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text('적용'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 레이어 제어 패널 (하단에서 올라오는 패널)
  Widget _buildLayerPanel() {
    final layers = _layers;
    final visibleCount = layers.length - _hiddenLayers.length;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.4,
        ),
        decoration: BoxDecoration(
          color: Colors.grey[900]!.withValues(alpha: 0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey[700]!, width: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.layers, color: Colors.cyan, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '레이어 ($visibleCount/${layers.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  // 전체 켜기
                  TextButton(
                    onPressed: _hiddenLayers.isEmpty
                        ? null
                        : () {

                            setState(() => _hiddenLayers.clear());
                        
                          },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('전체 ON', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 4),
                  // 전체 끄기
                  TextButton(
                    onPressed: _hiddenLayers.length == layers.length
                        ? null
                        : () {

                            setState(() => _hiddenLayers.addAll(layers));
                        
                          },
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('전체 OFF', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 8),
                  // 닫기
                  IconButton(
                    onPressed: () => setState(() => _showLayerPanel = false),
                    icon: const Icon(Icons.close, color: Colors.white54, size: 20),
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  ),
                ],
              ),
            ),
            // 레이어 리스트
            Flexible(
              child: layers.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('레이어 없음', style: TextStyle(color: Colors.white54)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: layers.length,
                      itemBuilder: (context, index) {
                        final layer = layers[index];
                        final isVisible = !_hiddenLayers.contains(layer);
                        final entityCount = (_dxfData!['entities'] as List)
                            .where((e) => e['layer'] == layer)
                            .length;

                        return Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          child: Row(
                            children: [
                              // 눈 아이콘 → 표시/비표시 토글
                              IconButton(
                                onPressed: () {
                                  setState(() {
                                    if (isVisible) {
                                      _hiddenLayers.add(layer);
                                    } else {
                                      _hiddenLayers.remove(layer);
                                    }
                                  });
                                },
                                icon: Icon(
                                  isVisible ? Icons.visibility : Icons.visibility_off,
                                  size: 18,
                                  color: isVisible ? Colors.cyan : Colors.grey[600],
                                ),
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                              ),
                              // 레이어 이름 → 설정 다이얼로그
                              Expanded(
                                child: InkWell(
                                  onTap: () => _showLayerSettingsDialog(layer),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 8),
                                    child: Text(
                                      layer,
                                      style: TextStyle(
                                        color: isVisible ? Colors.white : Colors.grey[600],
                                        fontSize: 13,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ),
                              Text(
                                '$entityCount',
                                style: TextStyle(
                                  color: Colors.grey[500],
                                  fontSize: 11,
                                ),
                              ),
                              // 레이어 삭제 버튼
                              IconButton(
                                onPressed: () => _confirmDeleteLayer(layer, entityCount),
                                icon: Icon(Icons.delete_outline, size: 16, color: Colors.grey[600]),
                                padding: const EdgeInsets.all(8),
                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 객체 관리 패널 (치수 + 사용자 엔티티)
  Widget _buildDimListPanel() {
    final totalCount = _dimResults.length + _userEntities.length;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.4,
        ),
        decoration: BoxDecoration(
          color: Colors.grey[900]!.withValues(alpha: 0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey[700]!, width: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.layers, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '객체 목록 ($totalCount개)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (totalCount > 0)
                    TextButton(
                      onPressed: _deleteAllUserObjects,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('전체 삭제', style: TextStyle(fontSize: 12, color: Colors.red)),
                    ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _showDimPanel = false),
                    child: const Icon(Icons.close, color: Colors.white54, size: 20),
                  ),
                ],
              ),
            ),
            // 객체 리스트
            Flexible(
              child: totalCount == 0
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('객체 없음', style: TextStyle(color: Colors.white54)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: [
                        // 치수 항목들
                        for (int i = 0; i < _dimResults.length; i++)
                          _buildDimListItem(i),
                        // 사용자 엔티티 항목들
                        for (int i = 0; i < _userEntities.length; i++)
                          _buildUserEntityListItem(i),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDimListItem(int index) {
    final dim = _dimResults[index];
    final isSelected = _selectedDimIndex == index;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () {
            setState(() {
              _selectedDimIndex = isSelected ? null : index;
            });
          },
          child: Container(
            color: isSelected ? Colors.cyan.withValues(alpha: 0.15) : null,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(
                  _getDimTypeIcon(dim.type),
                  size: 18,
                  color: dim.style.color,
                ),
                const SizedBox(width: 10),
                Text(
                  _getDimTypeLabel(dim.type),
                  style: TextStyle(color: Colors.grey[400], fontSize: 11),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    dim.type == DimensionType.angular
                        ? '${dim.value.toStringAsFixed(dim.style.decimalPlaces)}\u00B0'
                        : dim.value.toStringAsFixed(dim.style.decimalPlaces),
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                ),
                GestureDetector(
                  onTap: () => _deleteDimension(index),
                  child: Icon(Icons.delete_outline, size: 18, color: Colors.red[300]),
                ),
              ],
            ),
          ),
        ),
        // 선택된 치수: 보조선 크기 조절 슬라이더
        if (isSelected)
          Container(
            color: Colors.grey[850],
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                Row(
                  children: [
                    Text('보조선', style: TextStyle(color: Colors.grey[400], fontSize: 11)),
                    Expanded(
                      child: Slider(
                        value: dim.style.extensionOvershoot,
                        min: 0,
                        max: 30,
                        onChanged: (v) {
                          setState(() {
                            _dimResults[index] = dim.copyWith(
                              style: dim.style.copyWith(extensionOvershoot: v),
                            );
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      child: Text(
                        dim.style.extensionOvershoot.toStringAsFixed(0),
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Text('간격', style: TextStyle(color: Colors.grey[400], fontSize: 11)),
                    Expanded(
                      child: Slider(
                        value: dim.style.extensionGap,
                        min: 0,
                        max: 20,
                        onChanged: (v) {
                          setState(() {
                            _dimResults[index] = dim.copyWith(
                              style: dim.style.copyWith(extensionGap: v),
                            );
                          });
                        },
                      ),
                    ),
                    SizedBox(
                      width: 32,
                      child: Text(
                        dim.style.extensionGap.toStringAsFixed(0),
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildUserEntityListItem(int index) {
    final entity = _userEntities[index];
    final type = entity['type'] as String;
    final isSelected = _selectedEntities.contains(entity);

    IconData icon;
    String label;
    String detail;
    Color color;

    switch (type) {
      case 'POINT':
        icon = Icons.location_on;
        label = '포인트';
        detail = '(${(entity['x'] as double).toStringAsFixed(2)}, ${(entity['y'] as double).toStringAsFixed(2)})';
        color = Color(entity['color'] as int);
        break;
      case 'LINE':
        icon = Icons.horizontal_rule;
        label = '라인';
        detail = '(${(entity['x1'] as double).toStringAsFixed(1)},${(entity['y1'] as double).toStringAsFixed(1)})→(${(entity['x2'] as double).toStringAsFixed(1)},${(entity['y2'] as double).toStringAsFixed(1)})';
        color = Color(entity['color'] as int);
        break;
      case 'TEXT':
        icon = Icons.text_fields;
        label = '텍스트';
        detail = entity['text'] as String? ?? '';
        color = Color(entity['color'] as int);
        break;
      case 'LEADER':
        icon = Icons.call_made;
        label = '지시선';
        detail = entity['text'] as String? ?? '';
        color = Color(entity['color'] as int);
        break;
      default:
        icon = Icons.help_outline;
        label = type;
        detail = '';
        color = Colors.white;
    }

    return InkWell(
      onTap: () {
        setState(() {
          if (isSelected) {
            _selectedEntities.remove(entity);
          } else {
            _selectedEntities.clear();
            _selectedEntities.add(entity);
            _selectedDimIndex = null;
          }
          _showPropertyPanel = _selectedEntities.isNotEmpty;
        });
      },
      child: Container(
        color: isSelected ? Colors.cyan.withValues(alpha: 0.15) : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(color: Colors.grey[400], fontSize: 11)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                detail,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            GestureDetector(
              onTap: () => _deleteUserEntity(index),
              child: Icon(Icons.delete_outline, size: 18, color: Colors.red[300]),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteUserEntity(int index) {
    setState(() {
      final entity = _userEntities[index];
      _selectedEntities.remove(entity);
      _userEntities.removeAt(index);
      if (_selectedEntities.isEmpty) _showPropertyPanel = false;
    });
  }

  void _deleteAllUserObjects() {
    final totalCount = _dimResults.length + _userEntities.length;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('모든 객체 삭제'),
        content: Text('$totalCount개의 객체를 모두 삭제하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
            onPressed: () {
              setState(() {
                _dimResults.clear();
                _selectedDimIndex = null;
                _userEntities.clear();
                _selectedEntities.clear();
                _showPropertyPanel = false;
              });
              Navigator.pop(ctx);
            },
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  /// 치수 스타일 설정 패널
  Widget _buildDimStylePanel() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900]!.withValues(alpha: 0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey[700]!, width: 0.5)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.palette, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    '치수 스타일 설정',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _showDimStylePanel = false),
                    child: const Icon(Icons.close, color: Colors.white54, size: 20),
                  ),
                ],
              ),
            ),
            // 색상 선택
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Text('색상', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(width: 12),
                  ..._buildColorChips(),
                ],
              ),
            ),
            // 폰트 크기
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Text('크기', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  Expanded(
                    child: Slider(
                      value: _dimStyle.fontSize,
                      min: 8,
                      max: 24,
                      divisions: 16,
                      label: _dimStyle.fontSize.toInt().toString(),
                      onChanged: (v) => setState(() => _dimStyle = _dimStyle.copyWith(fontSize: v)),
                    ),
                  ),
                  Text(
                    '${_dimStyle.fontSize.toInt()}',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            // 소수점 자릿수
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  const Text('소수점', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(width: 12),
                  ...List.generate(4, (i) {
                    final isActive = _dimStyle.decimalPlaces == i;
                    return Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: GestureDetector(
                        onTap: () => setState(() => _dimStyle = _dimStyle.copyWith(decimalPlaces: i)),
                        child: Container(
                          width: 32,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: isActive ? Colors.cyan : Colors.grey[700],
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '$i',
                            style: TextStyle(
                              color: isActive ? Colors.black : Colors.white70,
                              fontSize: 12,
                              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            // 화살표 스타일
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Text('화살표', style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(width: 12),
                  ..._buildArrowStyleChips(),
                ],
              ),
            ),
            // 구분선
            Divider(color: Colors.grey[700], height: 1),
            // 측설 자동 줌 배율 설정
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.zoom_in, color: Colors.cyan, size: 18),
                  const SizedBox(width: 6),
                  const Text(
                    '측설 자동 줌 배율',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            ..._buildAutoZoomSettings(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildColorChips() {
    const colors = [
      (Color(0xFFFFFF00), '노랑'),
      (Color(0xFFFF0000), '빨강'),
      (Color(0xFF00FF00), '초록'),
      (Color(0xFF00FFFF), '청록'),
      (Color(0xFFFFFFFF), '흰색'),
      (Color(0xFFFF8000), '주황'),
    ];
    return colors.map((entry) {
      final isActive = _dimStyle.color.toARGB32() == entry.$1.toARGB32();
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () => setState(() => _dimStyle = _dimStyle.copyWith(color: entry.$1)),
          child: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: entry.$1,
              shape: BoxShape.circle,
              border: Border.all(
                color: isActive ? Colors.white : Colors.transparent,
                width: 2,
              ),
            ),
            child: isActive
                ? const Icon(Icons.check, size: 14, color: Colors.black)
                : null,
          ),
        ),
      );
    }).toList();
  }

  List<Widget> _buildArrowStyleChips() {
    const styles = [
      (ArrowStyle.filled, '▶'),
      (ArrowStyle.open, '▷'),
      (ArrowStyle.tick, '╱'),
      (ArrowStyle.dot, '●'),
      (ArrowStyle.none, '—'),
    ];
    return styles.map((entry) {
      final isActive = _dimStyle.arrowStyle == entry.$1;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () => setState(() => _dimStyle = _dimStyle.copyWith(arrowStyle: entry.$1)),
          child: Container(
            width: 32,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isActive ? Colors.cyan : Colors.grey[700],
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.$2,
              style: TextStyle(
                color: isActive ? Colors.black : Colors.white70,
                fontSize: 14,
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  /// 측설 자동 줌 배율 설정 위젯 목록
  List<Widget> _buildAutoZoomSettings() {
    final labels = ['10m', '5m', '2m', '1m', '50cm', '30cm', '10cm', '5cm'];
    return List.generate(_autoZoomLevels.length, (i) {
      final level = _autoZoomLevels[i];
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        child: Row(
          children: [
            GestureDetector(
              onTap: () => _enterZoomPreview(level.$2, labels[i]),
              child: SizedBox(
                width: 48,
                child: Text(
                  labels[i],
                  style: const TextStyle(color: Colors.cyanAccent, fontSize: 12, decoration: TextDecoration.underline),
                ),
              ),
            ),
            Expanded(
              child: Slider(
                value: level.$2,
                min: 5,
                max: 1500,
                divisions: 299,
                onChanged: (v) {
                  setState(() {
                    _autoZoomLevels[i] = (level.$1, (v / 5).round() * 5.0);
                  });
                  _saveAutoZoomLevels();
                },
              ),
            ),
            SizedBox(
              width: 48,
              child: GestureDetector(
                onTap: () => _editAutoZoomValue(i),
                child: Text(
                  'x${level.$2.toInt()}',
                  style: const TextStyle(color: Colors.cyanAccent, fontSize: 12),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  /// 줌 배율 프리뷰 진입
  void _enterZoomPreview(double zoom, String label) {
    // 기준점: 마지막 확정 포인트 또는 측설 타겟
    double? cx, cy;
    if (_confirmedPoints.isNotEmpty) {
      cx = _confirmedPoints.last.dxfX;
      cy = _confirmedPoints.last.dxfY;
    } else if (_stakeoutTarget != null) {
      cx = _stakeoutTarget!.dxfX;
      cy = _stakeoutTarget!.dxfY;
    }

    // 기준점 없으면 현재 뷰 중앙 유지
    final savedZoom = _zoom;
    final savedOffset = _offset;

    setState(() {
      _zoomPreviewMode = true;
      _previewZoom = zoom;
      _previewLabel = label;
      _showDimStylePanel = false;
      _zoom = zoom;
    });

    // 기준점이 있으면 중앙 정렬
    if (cx != null && cy != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _centerOnDxfPoint(cx!, cy!, targetZoom: zoom);
      });
    }

    // 복원용 저장
    _savedZoom = savedZoom;
    _savedOffset = savedOffset;
  }

  double _savedZoom = 1.0;
  Offset _savedOffset = Offset.zero;

  /// 줌 배율 프리뷰 종료
  void _exitZoomPreview() {
    setState(() {
      _zoomPreviewMode = false;
      _zoom = _savedZoom;
      _offset = _savedOffset;
      _showDimStylePanel = true;
    });
  }

  /// 자동 줌 값 직접 입력
  void _editAutoZoomValue(int index) {
    final level = _autoZoomLevels[index];
    final labels = ['10m', '5m', '2m', '1m', '50cm', '30cm', '10cm', '5cm'];
    final controller = TextEditingController(text: level.$2.toInt().toString());
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${labels[index]} 이내 줌 배율'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '줌 배율',
            suffixText: 'x',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              final v = double.tryParse(controller.text);
              if (v != null && v >= 5 && v <= 1500) {
                setState(() => _autoZoomLevels[index] = (level.$1, v));
                _saveAutoZoomLevels();
              }
              Navigator.pop(ctx);
            },
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }
}

/// PDMODE 프리뷰 페인터
class _PdmodePreviewPainter extends CustomPainter {
  final int pdmode;
  _PdmodePreviewPainter(this.pdmode);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.35;
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final base = pdmode & 7; // 하위 3비트: 기본 형상
    final shape = pdmode & ~7; // 상위 비트: 외형 (32=circle, 64=square)

    // 외형
    if (shape & 32 != 0) {
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }
    if (shape & 64 != 0) {
      canvas.drawRect(Rect.fromCenter(center: Offset(cx, cy), width: r * 2, height: r * 2), paint);
    }

    // 기본 형상
    final s = r * 0.7;
    switch (base) {
      case 0: // dot
        canvas.drawCircle(Offset(cx, cy), 2, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
        break;
      case 2: // + cross
        canvas.drawLine(Offset(cx - s, cy), Offset(cx + s, cy), paint);
        canvas.drawLine(Offset(cx, cy - s), Offset(cx, cy + s), paint);
        break;
      case 3: // X cross
        canvas.drawLine(Offset(cx - s, cy - s), Offset(cx + s, cy + s), paint);
        canvas.drawLine(Offset(cx - s, cy + s), Offset(cx + s, cy - s), paint);
        break;
      case 4: // short line up
        canvas.drawLine(Offset(cx, cy), Offset(cx, cy - s), paint);
        break;
      case 1: // dot (same as 0 for user entities)
        canvas.drawCircle(Offset(cx, cy), 2, paint..style = PaintingStyle.fill);
        paint.style = PaintingStyle.stroke;
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _PdmodePreviewPainter old) => old.pdmode != pdmode;
}

/// 영역 확대 사각형을 그리는 Painter
class ZoomWindowPainter extends CustomPainter {
  final Offset start;
  final Offset end;

  ZoomWindowPainter({required this.start, required this.end});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final rect = Rect.fromPoints(start, end);
    canvas.drawRect(rect, paint);
    canvas.drawRect(rect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant ZoomWindowPainter oldDelegate) {
    return oldDelegate.start != start || oldDelegate.end != end;
  }
}

/// 영역 선택 사각형 painter (DXF 좌표)
class _AreaSelectPainter extends CustomPainter {
  final ({double x, double y}) start;
  final ({double x, double y}) end;
  final Offset Function(double, double) transformPoint;

  _AreaSelectPainter({required this.start, required this.end, required this.transformPoint});

  @override
  void paint(Canvas canvas, Size size) {
    final p1 = transformPoint(start.x, start.y);
    final p2 = transformPoint(end.x, end.y);

    final fill = Paint()
      ..color = const Color(0x2200AAFF)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = const Color(0xCC00AAFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final rect = Rect.fromPoints(p1, p2);
    canvas.drawRect(rect, fill);
    canvas.drawRect(rect, border);
  }

  @override
  bool shouldRepaint(covariant _AreaSelectPainter old) => true;
}

/// 펜스 선택 라인 painter (DXF 좌표)
class _FenceSelectPainter extends CustomPainter {
  final List<({double x, double y})> points;
  final Offset Function(double, double) transformPoint;

  _FenceSelectPainter({required this.points, required this.transformPoint});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final linePaint = Paint()
      ..color = const Color(0xCCFF8800)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    final dotPaint = Paint()
      ..color = const Color(0xFFFF8800)
      ..style = PaintingStyle.fill;

    final path = Path();
    for (int i = 0; i < points.length; i++) {
      final sp = transformPoint(points[i].x, points[i].y);
      if (i == 0) {
        path.moveTo(sp.dx, sp.dy);
      } else {
        path.lineTo(sp.dx, sp.dy);
      }
      canvas.drawCircle(sp, 4, dotPaint);
    }
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _FenceSelectPainter old) => true;
}
