import 'package:flutter/material.dart';
import '../models/station_data.dart';
import '../services/dxf_service.dart';
import '../services/snap_service.dart';
import '../widgets/dxf_painter.dart';
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

  // 영역 확대 모드
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
      setState(() {
        _zoomWindowStart = null;
        _zoomWindowEnd = null;
        _isZoomWindowMode = false;
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
      _isZoomWindowMode = false;
    });
  }

  /// 샘플 DXF 파일 로드
  Future<void> _loadSampleDxf() async {
    setState(() => _isLoading = true);

    try {
      final data = await DxfService.loadDxfFromAssets('assets/sample_data/test.dxf');

      if (data != null) {
        setState(() {
          _dxfData = data;
          _isLoading = false;
          _hiddenLayers.clear();
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      print('[DXF Viewer] 로드 오류: $e');
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
          setState(() {
            _dxfData = data;
            _isLoading = false;
            _zoom = 1.0;
            _offset = Offset.zero;
            _selectedStation = null;
            _hiddenLayers.clear();
            _showLayerPanel = false;
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
      print('[DXF Viewer] 파일 열기 오류: $e');
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류: $e')),
        );
      }
    }
  }

  /// 선택된 측점의 DXF 좌표로 뷰 이동
  void _goToStation(StationData station) {
    if (_dxfData == null || station.x == null || station.y == null) return;

    final bounds = _dxfData!['bounds'] as Map<String, dynamic>;
    final minX = bounds['minX'] as double;
    final minY = bounds['minY'] as double;
    final maxX = bounds['maxX'] as double;
    final maxY = bounds['maxY'] as double;
    final dxfWidth = maxX - minX;
    final dxfHeight = maxY - minY;

    if (dxfWidth <= 0 || dxfHeight <= 0) return;

    final screenSize = MediaQuery.of(context).size;
    final appBarHeight = AppBar().preferredSize.height +
        MediaQuery.of(context).padding.top +
        48; // 드롭다운 영역 높이
    final canvasWidth = screenSize.width;
    final canvasHeight = screenSize.height - appBarHeight - _bottomBarHeight;

    final scaleX = canvasWidth * 0.9 / dxfWidth;
    final scaleY = canvasHeight * 0.9 / dxfHeight;
    final baseScale = scaleX < scaleY ? scaleX : scaleY;

    final newZoom = _stationZoomLevel;
    final scale = baseScale * newZoom;

    final centerOffsetX = (canvasWidth - dxfWidth * scale) / 2;
    final centerOffsetY = (canvasHeight - dxfHeight * scale) / 2;

    final stationScreenX = (station.x! - minX) * scale + centerOffsetX;
    final stationScreenY = canvasHeight - ((station.y! - minY) * scale + centerOffsetY);

    final targetOffsetDx = canvasWidth / 2 - stationScreenX;
    final targetOffsetDy = -(canvasHeight / 2 - stationScreenY);

    setState(() {
      _zoom = newZoom;
      _offset = Offset(targetOffsetDx, targetOffsetDy);
      _selectedStation = station;
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

  /// 포인트 모드에서 터치 시 스냅 계산
  void _handlePointTouch(Offset touchPoint, Size canvasSize) {
    final transformPoint = _getTransformPoint(canvasSize);
    if (transformPoint == null || _dxfData == null) return;

    final cursorTip = SnapOverlayPainter.getCursorTip(touchPoint);
    final scale = _getCurrentScale(canvasSize);

    final result = SnapService.findSnap(
      cursorTip: cursorTip,
      entities: _dxfData!['entities'] as List,
      hiddenLayers: _hiddenLayers,
      transformPoint: transformPoint,
      inverseTransform: transformPoint, // 역변환은 스냅 계산에서 미사용
      scale: scale,
      zoom: _zoom,
    );

    setState(() {
      _touchPoint = touchPoint;
      _highlightEntity = result.entity;
      _activeSnap = result.snap;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DXF 도면'),
        actions: [
          IconButton(
            icon: Icon(
              Icons.crop_free,
              color: _isZoomWindowMode ? Colors.blue : null,
            ),
            tooltip: '영역 확대',
            onPressed: () {
              setState(() {
                _isZoomWindowMode = !_isZoomWindowMode;
                _zoomWindowStart = null;
                _zoomWindowEnd = null;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            onPressed: () {
              setState(() {
                final oldZoom = _zoom;
                _zoom *= 1.5;
                _offset *= _zoom / oldZoom;
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.zoom_out),
            onPressed: () {
              setState(() {
                final oldZoom = _zoom;
                _zoom /= 1.5;
                _offset *= _zoom / oldZoom;
              });
            },
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
                    if (_stationsWithCoords.isNotEmpty) _buildStationSelector(),
                    Expanded(child: _buildDxfView()),
                    _buildBottomBar(),
                  ],
                )
              : const Center(child: Text('DXF 파일을 불러올 수 없습니다')),
      floatingActionButton: _dxfData != null
          ? FloatingActionButton(
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
            )
          : null,
    );
  }

  /// 측점 선택 드롭다운 바
  Widget _buildStationSelector() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: Colors.grey[850],
      child: Row(
        children: [
          const Icon(Icons.location_on, color: Colors.cyan, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedStation?.no,
                hint: Text(
                  '측점 선택 (${_stationsWithCoords.length}개)',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                isExpanded: true,
                dropdownColor: Colors.grey[800],
                style: const TextStyle(color: Colors.white, fontSize: 14),
                icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                menuMaxHeight: 400,
                items: _stationsWithCoords.map((station) {
                  return DropdownMenuItem<String>(
                    value: station.no,
                    child: Text(
                      '${station.no}  (${station.x!.toStringAsFixed(1)}, ${station.y!.toStringAsFixed(1)})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (stationNo) {
                  if (stationNo == null) return;
                  final station = _stationsWithCoords.firstWhere((s) => s.no == stationNo);
                  _goToStation(station);
                },
              ),
            ),
          ),
          if (_selectedStation != null)
            IconButton(
              icon: const Icon(Icons.clear, color: Colors.white70, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () {
                setState(() {
                  _selectedStation = null;
                  _zoom = 1.0;
                  _offset = Offset.zero;
                });
              },
            ),
        ],
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
          // 슬롯 3: 빈 슬롯
          _buildToolbarButton(
            icon: Icons.more_horiz,
            label: '',
            enabled: false,
            onPressed: () {},
          ),
          // 슬롯 4: 빈 슬롯
          _buildToolbarButton(
            icon: Icons.more_horiz,
            label: '',
            enabled: false,
            onPressed: () {},
          ),
          // 슬롯 5: 빈 슬롯
          _buildToolbarButton(
            icon: Icons.more_horiz,
            label: '',
            enabled: false,
            onPressed: () {},
          ),
        ],
      ),
    );
  }

  Widget _buildToolbarButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool isActive = false,
    bool enabled = true,
    String? badge,
  }) {
    return Expanded(
      child: InkWell(
        onTap: enabled ? onPressed : null,
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
        _lastCanvasSize = canvasSize;

        return Stack(
          children: [
            // 도면 캔버스
            GestureDetector(
              onScaleStart: (details) {
                if (_isPointMode) {
                  _handlePointTouch(details.localFocalPoint, canvasSize);
                } else if (_isZoomWindowMode) {
                  setState(() {
                    _zoomWindowStart = details.localFocalPoint;
                    _zoomWindowEnd = null;
                  });
                } else {
                  _lastFocalPoint = details.focalPoint;
                }
              },
              onScaleUpdate: (details) {
                if (_isPointMode) {
                  _handlePointTouch(details.localFocalPoint, canvasSize);
                } else if (_isZoomWindowMode) {
                  setState(() {
                    _zoomWindowEnd = details.localFocalPoint;
                  });
                } else {
                  setState(() {
                    if (details.scale != 1.0) {
                      _zoom *= details.scale;
                    }
                    final delta = details.focalPoint - _lastFocalPoint;
                    _offset += Offset(delta.dx, -delta.dy);
                    _lastFocalPoint = details.focalPoint;
                  });
                }
              },
              onScaleEnd: (details) {
                if (_isPointMode) {
                  // 터치 뗐을 때 스냅이 있으면 확정
                  if (_activeSnap != null) {
                    setState(() {
                      _confirmedPoints.add((
                        type: _activeSnap!.type,
                        dxfX: _activeSnap!.dxfX,
                        dxfY: _activeSnap!.dxfY,
                      ));
                      // 포인트 모드 해제 + 커서 숨기기
                      _isPointMode = false;
                      _touchPoint = null;
                      _activeSnap = null;
                      _highlightEntity = null;
                    });
                  }
                } else if (_isZoomWindowMode && _zoomWindowStart != null && _zoomWindowEnd != null) {
                  _applyZoomWindow();
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
                  // 포인트 지정 커서 + 스냅 오버레이
                  if (_isPointMode && _touchPoint != null)
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
                ],
              ),
            ),
            // 포인트 모드 안내 표시
            if (_isPointMode)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.cyan.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      _activeSnap != null
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
          color: Colors.grey[900]!.withOpacity(0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
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
                        : () => setState(() => _hiddenLayers.clear()),
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
                        : () => setState(() => _hiddenLayers.addAll(layers)),
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
                            setState(() {
                              if (isVisible) {
                                _hiddenLayers.add(layer);
                              } else {
                                _hiddenLayers.remove(layer);
                              }
                            });
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
}

/// 영역 확대 사각형을 그리는 Painter
class ZoomWindowPainter extends CustomPainter {
  final Offset start;
  final Offset end;

  ZoomWindowPainter({required this.start, required this.end});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue.withOpacity(0.3)
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
