import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/dimension_data.dart';
import '../models/station_data.dart';
import '../services/bluetooth_gnss_service.dart';
import '../services/dxf_service.dart';
import '../services/snap_service.dart';
import '../widgets/dxf_painter.dart';
import '../widgets/dimension_painter.dart';
import '../widgets/gps_position_painter.dart';
import '../widgets/magnification_painter.dart';
import '../widgets/snap_overlay_painter.dart';

/// DXF 뷰어 화면
class DxfViewerScreen extends StatefulWidget {
  final List<StationData> stations;

  const DxfViewerScreen({super.key, this.stations = const []});

  @override
  State<DxfViewerScreen> createState() => _DxfViewerScreenState();
}

class _DxfViewerScreenState extends State<DxfViewerScreen> {
  Map<String, dynamic>? _dxfData;
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
  bool _showLayerPanel = false;

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

  bool _edgePanDone = false; // 가장자리 자동패닝 1회 제한

  // Picture 캐시 (패닝 고속화: offset=0으로 녹화, 패닝 시 translate+drawPicture)
  ui.Picture? _cachedPicture;
  double _pictureZoom = -1;

  // GPS
  final BluetoothGnssService _gnssService = BluetoothGnssService();
  bool _showGpsOverlay = false; // GPS 상태 오버레이

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

  @override
  void initState() {
    super.initState();
    _loadSampleDxf();
    _gnssService.addListener(_onGnssUpdate);
  }

  @override
  void dispose() {
    _cachedPicture?.dispose();
    _gnssService.removeListener(_onGnssUpdate);
    _gnssService.dispose();
    super.dispose();
  }

  /// Picture 캐시 빌드 (offset=0으로 전체 엔티티 녹화, 컬링 없음)
  void _rebuildPictureCache(Size canvasSize) {
    if (_dxfData == null) return;
    final recorder = ui.PictureRecorder();
    final cacheCanvas = Canvas(recorder);

    final painter = DxfPainter(
      entities: _dxfData!['entities'],
      bounds: _dxfData!['bounds'],
      zoom: _zoom,
      offset: Offset.zero,
      hiddenLayers: _hiddenLayers,
    );
    painter.paintEntities(cacheCanvas, canvasSize, enableCulling: false);

    _cachedPicture?.dispose();
    _cachedPicture = recorder.endRecording();
    _pictureZoom = _zoom;
  }

  /// Picture 캐시 무효화 (줌 변경 중 등)
  void _invalidatePictureCache() {
    _cachedPicture?.dispose();
    _cachedPicture = null;
    _pictureZoom = -1;
  }

  /// 다음 프레임 이후 Picture 캐시 재빌드 스케줄 (UI 블로킹 방지)
  void _schedulePictureCacheRebuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dxfData == null || _lastCanvasSize == null) return;
      _rebuildPictureCache(_lastCanvasSize!);
      setState(() {});
    });
  }

  void _onGnssUpdate() {
    if (mounted) setState(() {});
  }

  /// GPS 아이콘 색상
  Color _getGpsIconColor() {
    switch (_gnssService.connectionState) {
      case GnssConnectionState.connected:
        final fix = _gnssService.position?.fixQuality ?? 0;
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
    final fix = _gnssService.position?.fixQuality ?? 0;
    switch (fix) {
      case 4: return 'RTK 고정';
      case 5: return '보정신호 수신중...';
      case 2: return 'DGPS';
      case 1: return '단독측위';
      default: return '위성 탐색중...';
    }
  }

  /// GPS 토글 (연결/해제)
  void _toggleGps() async {
    if (_gnssService.connectionState == GnssConnectionState.connected ||
        _gnssService.connectionState == GnssConnectionState.connecting) {
      _gnssService.disconnect();
    } else {
      // Android 12+ 블루투스 런타임 권한 요청
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
  }

  /// 페어링된 블루투스 기기 선택 다이얼로그
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
                      },
                    )),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// GPS 현재 위치로 이동 (롱프레스)
  void _goToGpsPosition() {
    final pos = _gnssService.position;
    if (pos == null || _dxfData == null || _lastCanvasSize == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('GPS 위치 없음: pos=${pos != null}, dxf=${_dxfData != null}, canvas=${_lastCanvasSize != null}')),
        );
      }
      return;
    }

    // 디버그: GPS TM 좌표와 도면 범위 비교
    final debugBounds = _dxfData!['bounds'] as Map<String, dynamic>;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'GPS TM: (${pos.tmX.toStringAsFixed(1)}, ${pos.tmY.toStringAsFixed(1)})\n'
            'DXF: X(${(debugBounds["minX"] as double).toStringAsFixed(1)}~${(debugBounds["maxX"] as double).toStringAsFixed(1)}) '
            'Y(${(debugBounds["minY"] as double).toStringAsFixed(1)}~${(debugBounds["maxY"] as double).toStringAsFixed(1)})',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    }

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

    // 적절한 줌 레벨로 설정
    const targetZoom = 8.0;
    final scale = baseScale * targetZoom;
    final centerOffsetX = (canvasSize.width - dxfWidth * scale) / 2;
    final centerOffsetY = (canvasSize.height - dxfHeight * scale) / 2;

    // GPS TM 좌표가 화면 중앙에 오도록 오프셋 계산
    final screenX = (pos.tmX - minX) * scale + centerOffsetX;
    final screenY = canvasSize.height - ((pos.tmY - minY) * scale + centerOffsetY);

    setState(() {
      _zoom = targetZoom;
      _offset = Offset(
        canvasSize.width / 2 - screenX,
        -(screenY - canvasSize.height / 2),
      );
    });
    _schedulePictureCacheRebuild();
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
    _schedulePictureCacheRebuild();

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
    _schedulePictureCacheRebuild();

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

  /// 전체 치수 삭제
  void _deleteAllDimensions() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('모든 치수 삭제'),
        content: Text('${_dimResults.length}개의 치수를 모두 삭제하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
            onPressed: () {
              setState(() {
                _dimResults.clear();
                _selectedDimIndex = null;
              });
              Navigator.pop(ctx);
            },
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
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
      final data = await DxfService.loadDxfFromAssets('assets/sample_data/test.dxf');

      if (data != null) {
        _invalidatePictureCache();
        setState(() {
          _dxfData = data;
          _isLoading = false;
          _hiddenLayers.clear();
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
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_lastCanvasSize != null) {
            _rebuildPictureCache(_lastCanvasSize!);
            if (mounted) setState(() {});
          }
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[DXF Viewer] 로드 오류: $e');
      setState(() => _isLoading = false);
    }
  }

  /// 파일에서 DXF 열기
  Future<void> _openDxfFile() async {
    try {
      final filePath = await DxfService.pickDxfFile();

      if (filePath != null) {
        setState(() => _isLoading = true);

        final data = await DxfService.loadDxfFile(filePath);

        if (data != null) {
          _invalidatePictureCache();
          setState(() {
            _dxfData = data;
            _isLoading = false;
            _zoom = 1.0;
            _offset = Offset.zero;
            _selectedStation = null;
            _hiddenLayers.clear();
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
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_lastCanvasSize != null) {
              _rebuildPictureCache(_lastCanvasSize!);
              if (mounted) setState(() {});
            }
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
      _schedulePictureCacheRebuild();
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
      hiddenLayers: _hiddenLayers,
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
    });
  }

  /// 치수 배치 단계: 터치 위치를 DXF 좌표로 변환하여 치수선 위치 결정
  void _handleDimPlacement(Offset touchPoint, Size canvasSize) {
    if (_dxfData == null) return;

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
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DXF 도면'),
        actions: [
          // GPS 연결 버튼
          GestureDetector(
            onLongPress: _goToGpsPosition,
            child: IconButton(
              icon: Icon(
                _gnssService.connectionState == GnssConnectionState.connected
                    ? Icons.gps_fixed
                    : Icons.gps_off,
                color: _getGpsIconColor(),
              ),
              onPressed: _toggleGps,
            ),
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
              _schedulePictureCacheRebuild();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _dxfData != null
              ? Column(
                  children: [
                    if (_stationsWithCoords.isNotEmpty) _buildStationSelector(),
                    Expanded(child: _buildDxfView()),
                    _buildBottomBar(),
                  ],
                )
              : const Center(child: Text('DXF 파일을 불러올 수 없습니다')),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: _dxfData != null && !_isDimensionMode
          ? Padding(
              padding: const EdgeInsets.only(bottom: 80),
              child: FloatingActionButton(
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

  /// 측점 선택 버튼 + 토글 패널
  Widget _buildStationSelector() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 토글 버튼 바
        GestureDetector(
          onTap: () => setState(() => _showStationPanel = !_showStationPanel),
          child: Container(
            height: 36,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: Colors.grey[850],
            child: Row(
              children: [
                const Icon(Icons.location_on, color: Colors.cyan, size: 18),
                const SizedBox(width: 6),
                Text(
                  _selectedStation != null
                      ? '측점 ${_shortStationNo(_selectedStation!.no)}'
                      : '측점 선택',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const Spacer(),
                Icon(
                  _showStationPanel ? Icons.expand_less : Icons.expand_more,
                  color: Colors.white54,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
        // 바둑판 패널
        if (_showStationPanel)
          Container(
            constraints: const BoxConstraints(maxHeight: 160),
            padding: const EdgeInsets.all(8),
            color: Colors.grey[900],
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
                        color: isSelected ? Colors.cyan : Colors.grey[700],
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          color: isSelected ? Colors.black : Colors.white70,
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
            label: '열기',
            onPressed: _openDxfFile,
          ),
          // 슬롯 2: 레이어
          _buildToolbarButton(
            icon: Icons.layers,
            label: '레이어',
            isActive: _showLayerPanel,
            badge: _hiddenLayers.isNotEmpty ? '${_hiddenLayers.length}' : null,
            onPressed: () {
              setState(() => _showLayerPanel = !_showLayerPanel);
            },
          ),
          // 슬롯 3: 치수 측정 (롱프레스 → 타입 선택)
          _buildToolbarButton(
            icon: _getDimTypeIcon(_activeDimType),
            label: _getDimTypeLabel(_activeDimType),
            isActive: _isDimensionMode,
            onPressed: () {
              setState(() {
                _isDimensionMode = !_isDimensionMode;
                if (_isDimensionMode) {
                  _isPointMode = false;
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
          // 슬롯 4: 치수 목록
          _buildToolbarButton(
            icon: Icons.list_alt,
            label: '목록',
            isActive: _showDimPanel,
            badge: _dimResults.isNotEmpty ? '${_dimResults.length}' : null,
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
          // 슬롯 5: 치수 설정
          _buildToolbarButton(
            icon: Icons.palette,
            label: '설정',
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
        ],
      ),
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
          // 화면 크기 변경 → Picture 캐시 무효화 후 재빌드
          _invalidatePictureCache();
        }

        _lastCanvasSize = canvasSize;
        // 캐시 없으면 빌드 (화면 크기 변경 또는 초기 로드 시)
        if (_cachedPicture == null && _dxfData != null) {
          _schedulePictureCacheRebuild();
        }

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
                if (_isDimensionMode && _dimPending != null) {
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
                if (_isDimensionMode && _dimPending != null) {
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
                if (_isDimensionMode) {
                  setState(() {
                    if (_dimPending != null) {
                      // 배치 확정 → 결과에 추가
                      final p = _dimPending!;
                      _dimResults.add(DimensionResult(
                        id: DimensionResult.generateId(),
                        type: p.type,
                        x1: p.x1, y1: p.y1,
                        x2: p.x2, y2: p.y2,
                        x3: p.x3, y3: p.y3,
                        value: p.value,
                        offsetX: _dimPlacementDxf!.dx,
                        offsetY: _dimPlacementDxf!.dy,
                        style: _dimStyle,
                      ));
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
                  // 포인트 모드: 스냅 성공이든 취소든 모드 비활성
                  setState(() {
                    if (_activeSnap != null) {
                      _confirmedPoints.add((
                        type: _activeSnap!.type,
                        dxfX: _activeSnap!.dxfX,
                        dxfY: _activeSnap!.dxfY,
                      ));
                    }
                    _isPointMode = false;
                    _touchPoint = null;
                    _activeSnap = null;
                    _highlightEntity = null;
                    _cursorTipDxf = null;
                  });
                } else if (_isZoomWindowMode && _zoomWindowStart != null && _zoomWindowEnd != null) {
                  _applyZoomWindow();
                  _schedulePictureCacheRebuild();
                } else {
                  // 팬/줌 끝 → 가장 가까운 측점 싱크 + Picture 캐시 빌드
                  _syncNearestStation(canvasSize);
                  _schedulePictureCacheRebuild();
                }
              },
              child: Stack(
                children: [
                  CustomPaint(
                    size: Size.infinite,
                    painter: DxfPainter(
                      entities: _dxfData!['entities'],
                      bounds: _dxfData!['bounds'],
                      zoom: _zoom,
                      offset: _offset,
                      hiddenLayers: _hiddenLayers,
                      cachedPicture: _cachedPicture,
                      cacheZoom: _pictureZoom,
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
                  // 확정된 포인트 표식 (DXF 좌표 기반 → 줌/팬 유지)
                  if (_confirmedPoints.isNotEmpty)
                    CustomPaint(
                      size: Size.infinite,
                      painter: ConfirmedPointsPainter(
                        points: _confirmedPoints,
                        transformPoint: _getTransformPoint(canvasSize),
                      ),
                    ),
                  // GPS 위치 마커
                  if (_gnssService.position != null && _getTransformPoint(canvasSize) != null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: GpsPositionPainter(
                        tmX: _gnssService.position!.tmX,
                        tmY: _gnssService.position!.tmY,
                        fixQuality: _gnssService.position!.fixQuality,
                        transformPoint: _getTransformPoint(canvasSize)!,
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
                  // 포인트/치수 모드 커서 + 스냅 오버레이 (배치 단계에서는 숨김)
                  if ((_isPointMode || _isDimensionMode) && _touchPoint != null && _dimPending == null)
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
                  // 확대 원 (치수/포인트 모드 터치 중, 배치 단계 제외)
                  if ((_isDimensionMode || _isPointMode) && _touchPoint != null && _cursorTipDxf != null && _dimPending == null)
                    CustomPaint(
                      size: Size.infinite,
                      painter: MagnificationPainter(
                        cursorTipDxf: _cursorTipDxf!,
                        entities: _dxfData!['entities'] as List,
                        bounds: _dxfData!['bounds'] as Map<String, dynamic>,
                        hiddenLayers: _hiddenLayers,
                        zoom: _zoom,
                        viewScale: _getCurrentScale(MediaQuery.of(context).size),
                        activeSnap: _activeSnap,
                      ),
                    ),
                ],
              ),
            ),
            // GPS 연결 상태 오버레이
            if (_gnssService.connectionState != GnssConnectionState.disconnected)
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
                                    : '${_getFixStatusText()}  위성 ${_gnssService.position?.satellites ?? 0}',
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
                          '중부원점  X ${_gnssService.position!.tmX.toStringAsFixed(3)}',
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          '중부원점  Y ${_gnssService.position!.tmY.toStringAsFixed(3)}',
                          style: const TextStyle(color: Colors.cyanAccent, fontSize: 15, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'WGS  ${_gnssService.position!.latitude.toStringAsFixed(7)},  ${_gnssService.position!.longitude.toStringAsFixed(7)}',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        if (_gnssService.position!.altitude != null)
                          Text(
                            'H  ${_gnssService.position!.altitude!.toStringAsFixed(2)} m',
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                      ],
                    ],
                  ),
                ),
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
      case SnapType.endpoint:
        return 'END';
      case SnapType.center:
        return 'CEN';
      case SnapType.intersection:
        return 'INT';
      case SnapType.node:
        return 'NOD';
    }
  }

  String _getDimensionBannerText() {
    final typeName = _getDimTypeLabel(_activeDimType);

    if (_dimPending != null) {
      return '$typeName 배치 - 드래그하여 위치를 지정하세요';
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
                            _invalidatePictureCache();
                            setState(() => _hiddenLayers.clear());
                            _schedulePictureCacheRebuild();
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
                            _invalidatePictureCache();
                            setState(() => _hiddenLayers.addAll(layers));
                            _schedulePictureCacheRebuild();
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
                  GestureDetector(
                    onTap: () => setState(() => _showLayerPanel = false),
                    child: const Icon(Icons.close, color: Colors.white54, size: 20),
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
                        // 해당 레이어의 엔티티 수
                        final entityCount = (_dxfData!['entities'] as List)
                            .where((e) => e['layer'] == layer)
                            .length;

                        return InkWell(
                          onTap: () {
                            _invalidatePictureCache();
                            setState(() {
                              if (isVisible) {
                                _hiddenLayers.add(layer);
                              } else {
                                _hiddenLayers.remove(layer);
                              }
                            });
                            _schedulePictureCacheRebuild();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: Row(
                              children: [
                                Icon(
                                  isVisible ? Icons.visibility : Icons.visibility_off,
                                  size: 18,
                                  color: isVisible ? Colors.cyan : Colors.grey[600],
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    layer,
                                    style: TextStyle(
                                      color: isVisible ? Colors.white : Colors.grey[600],
                                      fontSize: 13,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '$entityCount',
                                  style: TextStyle(
                                    color: Colors.grey[500],
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
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

  /// 치수 관리 패널
  Widget _buildDimListPanel() {
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
                  const Icon(Icons.straighten, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '치수 목록 (${_dimResults.length}개)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (_dimResults.isNotEmpty)
                    TextButton(
                      onPressed: _deleteAllDimensions,
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
            // 치수 리스트
            Flexible(
              child: _dimResults.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('치수 없음', style: TextStyle(color: Colors.white54)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: _dimResults.length,
                      itemBuilder: (context, index) {
                        final dim = _dimResults[index];
                        final isSelected = _selectedDimIndex == index;
                        return InkWell(
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
                                  style: TextStyle(
                                    color: Colors.grey[400],
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    dim.type == DimensionType.angular
                                        ? '${dim.value.toStringAsFixed(dim.style.decimalPlaces)}\u00B0'
                                        : dim.value.toStringAsFixed(dim.style.decimalPlaces),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                                GestureDetector(
                                  onTap: () => _deleteDimension(index),
                                  child: Icon(Icons.delete_outline, size: 18, color: Colors.red[300]),
                                ),
                              ],
                            ),
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
