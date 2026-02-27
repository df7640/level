import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import '../models/station_data.dart';
import '../models/measurement_session.dart';
import '../services/level_calculation_service.dart';
import '../services/interpolation_service.dart';
import '../services/database_service.dart';

/// 야장(레벨북) 표시용 행 데이터
class _LevelBookRow {
  final String stationNo;
  final double? ih;
  final double? reading;
  final double? groundHeight;
  final double? cutFill;
  final String? cutFillStatus;
  final bool isTurningPoint;
  final bool isFirstRecord;
  final String remark;

  _LevelBookRow({
    required this.stationNo,
    this.ih,
    this.reading,
    this.groundHeight,
    this.cutFill,
    this.cutFillStatus,
    this.isTurningPoint = false,
    this.isFirstRecord = false,
    this.remark = '',
  });
}

/// 기초레벨 산정 결과
class _FoundationResult {
  final String stationNo;
  final double? baseValue;    // 기준 컬럼 값 (선택한 계획고)
  final double? foundationL;  // 기초레벨(좌안)
  final double? foundationR;  // 기초레벨(우안)
  final bool isInterpolated;

  _FoundationResult({
    required this.stationNo,
    this.baseValue,
    this.foundationL,
    this.foundationR,
    this.isInterpolated = false,
  });
}

/// 레벨 패널 화면
/// 현장 측량용 계산기
/// 상단: 입력/계산, 하단: 측량 기록 그리드
class LevelPanelScreen extends StatefulWidget {
  final List<StationData> stations;
  final int? projectId;
  final void Function(List<StationData>)? onStationsChanged;
  final int decimalPlaces;
  final int fontSizeDelta;

  const LevelPanelScreen({
    super.key,
    this.stations = const [],
    this.projectId,
    this.onStationsChanged,
    this.decimalPlaces = 3,
    this.fontSizeDelta = 0,
  });

  @override
  State<LevelPanelScreen> createState() => _LevelPanelScreenState();
}

class _LevelPanelScreenState extends State<LevelPanelScreen> {
  final TextEditingController _ihController = TextEditingController();
  final TextEditingController _actualReadingController = TextEditingController();
  final TextEditingController _offsetController = TextEditingController(text: '0');
  bool _offsetPositive = true; // true: +, false: -
  String _selectedPlanLevelColumn = 'GH';
  int? _selectedStationIndex;
  double? _targetReading;
  double? _cutFill;
  String? _cutFillStatus;

  // 측량 세션
  int? _currentSessionId;
  List<String> _sessionStationNos = []; // 이 세션에서 측량한 측점 번호들
  bool _sampleGenerated = false; // 샘플 생성 완료 플래그

  // 야장 뷰
  bool _isLevelBookView = false;
  List<MeasurementRecord> _sessionRecords = [];

  StationData? get _selectedStation {
    if (_selectedStationIndex == null) return null;
    if (_selectedStationIndex! >= widget.stations.length) return null;
    return widget.stations[_selectedStationIndex!];
  }

  /// 현재 세션에서 측량한 측점 목록
  List<StationData> get _measuredStations {
    if (_sessionStationNos.isEmpty) return [];
    final noSet = _sessionStationNos.toSet();
    return widget.stations
        .where((s) => noSet.contains(s.no) && s.actualReading != null)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    if (widget.stations.isNotEmpty) {
      _selectedStationIndex = 0;
    }
    _initSession();
  }

  /// 오늘 날짜의 세션이 있으면 재사용, 없으면 새로 생성
  Future<void> _initSession() async {
    if (widget.projectId == null) return;
    final db = DatabaseService.instance;
    var sessions = await db.getSessions(widget.projectId!);

    final today = DateTime.now();
    final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    // 샘플 세션이 5개 미만이면 기존 세션 모두 삭제 후 샘플 데이터 생성
    debugPrint('[LevelPanel] _initSession: sessions=${sessions.length}, stations=${widget.stations.length}, sampleGenerated=$_sampleGenerated');
    if (!_sampleGenerated && sessions.length < 5 && widget.stations.isNotEmpty) {
      _sampleGenerated = true;
      for (final s in sessions) {
        await db.deleteSession(s.id!);
      }
      await _generateSampleSessions();
      sessions = await db.getSessions(widget.projectId!);
    }

    // 오늘 생성된 세션 찾기 (세션 ID만 연결, 데이터는 복원하지 않음)
    for (final s in sessions) {
      final created = s.createdAt;
      final createdStr = '${created.year}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')}';
      if (createdStr == todayStr) {
        _currentSessionId = s.id;
        return;
      }
    }

    // 오늘 세션이 없으면 새로 생성
    final sessionId = await db.createSession(
      widget.projectId!,
      '$todayStr 측량',
    );
    _currentSessionId = sessionId;
  }

  @override
  void didUpdateWidget(covariant LevelPanelScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stations.isEmpty && widget.stations.isNotEmpty) {
      if (_selectedStationIndex == null) {
        setState(() => _selectedStationIndex = 0);
      }
      // stations가 나중에 로드되면 세션 초기화 재시도
      _initSession();
    }
  }

  @override
  void dispose() {
    _ihController.dispose();
    _actualReadingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('레벨 계산', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.layers),
            onPressed: _showFoundationLevelDialog,
            tooltip: '기초레벨 산정',
          ),
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: _showSessionHistory,
            tooltip: '측량 이력',
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showHelp,
            tooltip: '도움말',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          children: [
            // 1행: 측점 선택 + 이전/다음
            _buildStationRow(),
            const SizedBox(height: 12),

            // 2행: IH 입력 + 계획고 컬럼
            _buildInputRow(),
            const SizedBox(height: 12),

            // 3행: 읽을 값 + 보정값 + 읽은 값 + 저장
            _buildReadingRow(),
            const SizedBox(height: 12),

            // 4행: 절/성토 결과 (컴팩트)
            _buildCutFillBar(),
            const SizedBox(height: 14),

            // 구분선 + 뷰 모드 토글
            Row(
              children: [
                Icon(Icons.list_alt, size: 16, color: Colors.grey[500]),
                const SizedBox(width: 4),
                Text(
                  '측량 기록 (${_isLevelBookView ? _sessionRecords.length : _measuredStations.length}건)',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500], fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Expanded(child: Divider(color: Colors.grey[300])),
                const SizedBox(width: 8),
                _buildViewModeToggle(),
              ],
            ),
            const SizedBox(height: 4),

            // 5행: 측량 기록 그리드 (Expanded)
            Expanded(
              child: _isLevelBookView
                  ? _buildLevelBookGrid()
                  : _buildMeasurementGrid(),
            ),
          ],
        ),
      ),
    );
  }

  /// 1행: 측점 선택 + 이전/다음 버튼
  Widget _buildStationRow() {
    final hasPrev = _selectedStationIndex != null && _selectedStationIndex! > 0;
    final hasNext = _selectedStationIndex != null &&
        _selectedStationIndex! < widget.stations.length - 1;

    return Row(
      children: [
        Expanded(
          flex: 2,
          child: Material(
            color: hasPrev ? Colors.blue : Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: hasPrev
                  ? () => setState(() {
                        _selectedStationIndex = _selectedStationIndex! - 1;
                        _loadStationData();
                      })
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 44,
                child: Icon(Icons.chevron_left, color: hasPrev ? Colors.white : Colors.grey[400]),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 5,
          child: InkWell(
            onTap: _selectStation,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: Row(
                children: [
                  const Icon(Icons.location_on, size: 18, color: Colors.blue),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _selectedStation?.no ?? '측점 선택',
                      style: TextStyle(
                        fontSize: 15 + widget.fontSizeDelta.toDouble(),
                        fontWeight: FontWeight.bold,
                        color: _selectedStation != null ? null : Colors.grey,
                      ),
                    ),
                  ),
                  const Icon(Icons.unfold_more, size: 16, color: Colors.grey),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: Material(
            color: hasNext ? Colors.blue : Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              onTap: hasNext
                  ? () => setState(() {
                        _selectedStationIndex = _selectedStationIndex! + 1;
                        _loadStationData();
                      })
                  : null,
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 44,
                child: Icon(Icons.chevron_right, color: hasNext ? Colors.white : Colors.grey[400]),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static const double _rowHeight = 48.0;

  /// 2행: IH + 계획고 컬럼 (한 줄)
  Widget _buildInputRow() {
    return SizedBox(
      height: _rowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: _ihController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'IH (기계고)',
                border: OutlineInputBorder(),
                suffixText: 'm',
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 0),
              ),
              onChanged: (_) => _calculate(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 6,
            child: InkWell(
              onTap: _selectPlanLevelColumn,
              borderRadius: BorderRadius.circular(4),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: _planLevelColumnLabel(_selectedPlanLevelColumn),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  suffixText: _getPlanLevel()?.toStringAsFixed(widget.decimalPlaces),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _planLevelColumnLabel(_selectedPlanLevelColumn),
                        style: const TextStyle(fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.unfold_more, size: 16, color: Colors.grey),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 계획고 컬럼 선택 바텀시트
  void _selectPlanLevelColumn() {
    const columns = [
      {'value': 'GH', 'label': '지반고'},
      {'value': 'IP', 'label': '계획하상고'},
      {'value': 'deepestBedLevel', 'label': '최심하상고'},
      {'value': 'plannedFloodLevel', 'label': '계획홍수위'},
      {'value': 'leftBankHeight', 'label': '좌안제방고'},
      {'value': 'rightBankHeight', 'label': '우안제방고'},
      {'value': 'plannedBankLeft', 'label': '계획제방고(L)'},
      {'value': 'plannedBankRight', 'label': '계획제방고(R)'},
      {'value': 'roadbedLeft', 'label': '노체(L)'},
      {'value': 'roadbedRight', 'label': '노체(R)'},
    ];

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.calculate, size: 20),
                  const SizedBox(width: 8),
                  const Text(
                    '계획고 컬럼 선택',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: columns.map((col) {
                  final value = col['value']!;
                  final label = col['label']!;
                  final isSelected = _selectedPlanLevelColumn == value;
                  // 현재 측점의 해당 컬럼 값
                  double? colValue;
                  if (_selectedStation != null) {
                    final saved = _selectedPlanLevelColumn;
                    _selectedPlanLevelColumn = value;
                    colValue = _getPlanLevel();
                    _selectedPlanLevelColumn = saved;
                  }

                  return ListTile(
                    dense: true,
                    selected: isSelected,
                    selectedTileColor: Colors.blue[50],
                    leading: Icon(
                      isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      size: 20,
                      color: isSelected ? Colors.blue : Colors.grey,
                    ),
                    title: Text(
                      label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isSelected ? FontWeight.bold : null,
                      ),
                    ),
                    trailing: Text(
                      colValue?.toStringAsFixed(widget.decimalPlaces) ?? '-',
                      style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      setState(() => _selectedPlanLevelColumn = value);
                      _calculate();
                    },
                  );
                }).toList(),
              ),
            ),
            SizedBox(height: 8 + bottomPadding),
          ],
        );
      },
    );
  }

  /// 3행: 읽을 값 + 읽은 값 + 저장
  Widget _buildReadingRow() {
    return SizedBox(
      height: _rowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 읽을 값 (계산 결과)
          Expanded(
            flex: 2,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.blue[200]!),
              ),
              child: Text(
                _targetReading?.toStringAsFixed(widget.decimalPlaces) ?? '---',
                style: TextStyle(
                  fontSize: 18 + widget.fontSizeDelta.toDouble(),
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // 보정 +/- 토글 버튼
          SizedBox(
            width: _rowHeight,
            child: Material(
              color: _offsetPositive ? Colors.green[100] : Colors.red[100],
              borderRadius: BorderRadius.circular(4),
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () {
                  setState(() => _offsetPositive = !_offsetPositive);
                  _calculate();
                },
                child: Center(
                  child: Text(
                    _offsetPositive ? '+' : '−',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: _offsetPositive ? Colors.green[800] : Colors.red[800],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 보정값 입력
          Expanded(
            flex: 2,
            child: TextField(
              controller: _offsetController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '보정',
                border: OutlineInputBorder(),
                suffixText: 'm',
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              style: const TextStyle(fontSize: 14),
              onChanged: (_) => _calculate(),
            ),
          ),
          const SizedBox(width: 6),
          // 읽은 값 입력
          Expanded(
            flex: 2,
            child: TextField(
              controller: _actualReadingController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: '읽은 값',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 0),
              ),
              onChanged: (_) => _calculate(),
            ),
          ),
        ],
      ),
    );
  }

  /// 4행: 절/성토 결과 (컴팩트 바) + 저장 버튼
  Widget _buildCutFillBar() {
    Color statusColor = Colors.grey;
    String statusText = '대기 중';
    IconData statusIcon = Icons.remove;

    if (_cutFillStatus != null) {
      switch (_cutFillStatus) {
        case 'CUT':
          statusColor = Colors.red;
          statusText = '절토';
          statusIcon = Icons.arrow_downward;
          break;
        case 'FILL':
          statusColor = Colors.green;
          statusText = '성토';
          statusIcon = Icons.arrow_upward;
          break;
        case 'ON_GRADE':
          statusColor = Colors.blue;
          statusText = 'OK';
          statusIcon = Icons.check;
          break;
      }
    }

    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: statusColor.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(statusIcon, size: 24, color: statusColor),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 16 + widget.fontSizeDelta.toDouble(),
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _cutFill != null ? '${_cutFill!.toStringAsFixed(widget.decimalPlaces)} m' : '---',
                  style: TextStyle(
                    fontSize: 22 + widget.fontSizeDelta.toDouble(),
                    fontWeight: FontWeight.bold,
                    color: _cutFill != null ? statusColor : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 52,
          height: 48,
          child: ElevatedButton(
            onPressed: _canSave ? _saveReading : null,
            style: ElevatedButton.styleFrom(
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Icon(Icons.save, size: 24),
          ),
        ),
      ],
    );
  }

  /// 5행: 측량 기록 그리드
  Widget _buildMeasurementGrid() {
    final measured = _measuredStations;

    if (measured.isEmpty) {
      return Center(
        child: Text(
          '측량 기록이 없습니다\n측점을 선택하고 읽은 값을 입력하세요',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[400], fontSize: 14),
        ),
      );
    }

    return Column(
      children: [
        // 그리드 헤더
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          ),
          child: Row(
            children: [
              SizedBox(width: 72, child: Text('측점', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
              Expanded(child: Text('읽을값', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
              Expanded(child: Text('읽은값', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
              Expanded(child: Text('차이', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
              SizedBox(width: 40, child: Text('판정', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
            ],
          ),
        ),
        // 그리드 데이터
        Expanded(
          child: ListView.builder(
            itemCount: measured.length,
            itemExtent: 48,
            itemBuilder: (context, index) {
              final s = measured[index];
              final isCurrentStation = _selectedStation?.no == s.no;

              Color? statusColor;
              String statusLabel = '';
              if (s.cutFillStatus == 'CUT') {
                statusColor = Colors.red;
                statusLabel = 'C';
              } else if (s.cutFillStatus == 'FILL') {
                statusColor = Colors.green;
                statusLabel = 'F';
              } else if (s.cutFillStatus == 'ON_GRADE') {
                statusColor = Colors.blue;
                statusLabel = 'OK';
              }

              return InkWell(
                onTap: () {
                  // 그리드 항목 탭하면 해당 측점으로 이동 + 읽은값 복원
                  final idx = widget.stations.indexWhere((st) => st.no == s.no);
                  if (idx >= 0) {
                    setState(() {
                      _selectedStationIndex = idx;
                      _loadStationData(actualReading: s.actualReading);
                    });
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: isCurrentStation ? Colors.blue.withValues(alpha: 0.08) : null,
                    border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 72,
                        child: Text(
                          s.no,
                          style: TextStyle(
                            fontSize: 13 + widget.fontSizeDelta.toDouble(),
                            fontWeight: isCurrentStation ? FontWeight.bold : null,
                          ),
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          s.targetReading?.toStringAsFixed(widget.decimalPlaces) ?? '-',
                          style: TextStyle(fontSize: 13 + widget.fontSizeDelta.toDouble()),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          s.actualReading?.toStringAsFixed(widget.decimalPlaces) ?? '-',
                          style: TextStyle(fontSize: 13 + widget.fontSizeDelta.toDouble()),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          s.cutFill?.toStringAsFixed(widget.decimalPlaces) ?? '-',
                          style: TextStyle(
                            fontSize: 13 + widget.fontSizeDelta.toDouble(),
                            color: statusColor,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: statusLabel.isNotEmpty
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                decoration: BoxDecoration(
                                  color: statusColor?.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  statusLabel,
                                  style: TextStyle(
                                    fontSize: 12 + widget.fontSizeDelta.toDouble(),
                                    fontWeight: FontWeight.bold,
                                    color: statusColor,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  bool get _canSave =>
      _selectedStation != null &&
      _targetReading != null &&
      _actualReadingController.text.isNotEmpty;

  /// 측점 선택 다이얼로그
  void _selectStation() {
    if (widget.stations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('측점 데이터가 없습니다. 데이터 탭에서 데이터를 불러오세요.')),
      );
      return;
    }

    String searchQuery = '';
    bool baseOnly = false;
    final scrollController = ScrollController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        if (_selectedStationIndex != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final target = _selectedStationIndex! * 48.0;
            if (scrollController.hasClients) {
              scrollController.jumpTo(
                target.clamp(0, scrollController.position.maxScrollExtent),
              );
            }
          });
        }

        return StatefulBuilder(
          builder: (context, setSheetState) {
            final filtered = <int>[];
            for (int i = 0; i < widget.stations.length; i++) {
              final s = widget.stations[i];
              if (baseOnly && s.isInterpolated) continue;
              if (searchQuery.isNotEmpty &&
                  !s.no.toLowerCase().contains(searchQuery.toLowerCase())) {
                continue;
              }
              filtered.add(i);
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.6,
              minChildSize: 0.4,
              maxChildSize: 0.85,
              builder: (context, sheetScrollController) {
                return Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[400],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              autofocus: false,
                              decoration: InputDecoration(
                                hintText: '측점 검색 (예: NO.5)',
                                prefixIcon: const Icon(Icons.search, size: 20),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                                isDense: true,
                              ),
                              onChanged: (v) => setSheetState(() => searchQuery = v),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilterChip(
                            avatar: Icon(
                              baseOnly ? Icons.visibility_off : Icons.auto_awesome,
                              size: 16,
                              color: baseOnly ? Colors.grey : Colors.indigo[300],
                            ),
                            label: Text(baseOnly ? '기본만' : '전체'),
                            selected: baseOnly,
                            onSelected: (v) => setSheetState(() => baseOnly = v),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        '${filtered.length}개 측점',
                        style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                      ),
                    ),
                    const Divider(height: 8),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: filtered.length,
                        itemExtent: 48,
                        itemBuilder: (context, i) {
                          final originalIndex = filtered[i];
                          final station = widget.stations[originalIndex];
                          final isSelected = _selectedStationIndex == originalIndex;
                          final hasReading = station.actualReading != null;

                          return ListTile(
                            dense: true,
                            visualDensity: const VisualDensity(vertical: -4),
                            selected: isSelected,
                            selectedTileColor: Colors.blue[50],
                            leading: station.isInterpolated
                                ? Icon(Icons.auto_awesome, size: 16, color: Colors.indigo[300])
                                : const Icon(Icons.place, size: 16, color: Colors.blue),
                            title: Text(
                              station.no,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: isSelected ? FontWeight.bold : null,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${station.distance?.toStringAsFixed(1) ?? "-"}m',
                                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                ),
                                if (hasReading) ...[
                                  const SizedBox(width: 4),
                                  Icon(Icons.check_circle, size: 16, color: Colors.green[400]),
                                ],
                              ],
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              setState(() {
                                _selectedStationIndex = originalIndex;
                                _loadStationData();
                              });
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  void _loadStationData({double? actualReading}) {
    final station = _selectedStation;
    if (station == null) return;

    if (actualReading != null) {
      // 리스트에서 클릭한 경우: 해당 기록의 읽은값 표시
      _actualReadingController.text = actualReading.toStringAsFixed(widget.decimalPlaces);
    } else {
      // 측점 이동: 읽은값 비움
      _actualReadingController.clear();
    }

    _calculate();
  }

  double? _getPlanLevel() {
    final station = _selectedStation;
    if (station == null) return null;

    switch (_selectedPlanLevelColumn) {
      case 'GH':
        return station.gh;
      case 'IP':
        return station.ip;
      case 'deepestBedLevel':
        return station.deepestBedLevel;
      case 'plannedFloodLevel':
        return station.plannedFloodLevel;
      case 'leftBankHeight':
        return station.leftBankHeight;
      case 'rightBankHeight':
        return station.rightBankHeight;
      case 'plannedBankLeft':
        return station.plannedBankLeft;
      case 'plannedBankRight':
        return station.plannedBankRight;
      case 'roadbedLeft':
        return station.roadbedLeft;
      case 'roadbedRight':
        return station.roadbedRight;
      default:
        return station.gh;
    }
  }

  void _calculate() {
    final ih = double.tryParse(_ihController.text);
    final planLevel = _getPlanLevel();
    final offsetAbs = double.tryParse(_offsetController.text) ?? 0.0;
    final offsetM = _offsetPositive ? offsetAbs : -offsetAbs;
    double? targetReading = LevelCalculationService.calculateTargetReading(ih, planLevel);
    if (targetReading != null && offsetM != 0.0) {
      targetReading = targetReading - offsetM;
    }

    final actualReading = double.tryParse(_actualReadingController.text);
    double? cutFill;
    String? cutFillStatus;

    if (targetReading != null && actualReading != null) {
      cutFill = LevelCalculationService.calculateCutFill(targetReading, actualReading);
      cutFillStatus = LevelCalculationService.determineCutFillStatus(cutFill);
    }

    setState(() {
      _targetReading = targetReading;
      _cutFill = cutFill;
      _cutFillStatus = cutFillStatus;
    });
  }

  Future<void> _saveReading() async {
    if (_selectedStation == null || _selectedStationIndex == null) return;

    final actualReading = double.tryParse(_actualReadingController.text);
    if (actualReading == null) return;

    final updated = _selectedStation!.copyWith(
      actualReading: actualReading,
      targetReading: _targetReading,
      cutFill: _cutFill,
      cutFillStatus: _cutFillStatus,
      lastModified: DateTime.now(),
    );

    if (widget.projectId != null) {
      final db = DatabaseService.instance;
      await db.upsertStation(widget.projectId!, updated);
      final loaded = await db.getStations(widget.projectId!);
      widget.onStationsChanged?.call(loaded);

      final newIndex = loaded.indexWhere((s) => s.no == updated.no);
      if (newIndex >= 0) {
        _selectedStationIndex = newIndex;
      }

      // 세션에 기록 자동 저장
      await _saveToSession(updated);
    } else {
      final newList = List<StationData>.from(widget.stations);
      newList[_selectedStationIndex!] = updated;
      widget.onStationsChanged?.call(newList);
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${updated.no} 저장 완료'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 1),
        ),
      );

      // 다음 측점으로 자동 이동
      _moveToNextStation();
    }
  }

  /// 세션에 측량 기록 자동 저장 + 세션 이름 업데이트
  Future<void> _saveToSession(StationData station) async {
    if (_currentSessionId == null) return;
    final db = DatabaseService.instance;

    // 기록 저장 (현재 IH와 계획고 컬럼도 함께 저장)
    final ih = double.tryParse(_ihController.text);
    await db.upsertRecord(_currentSessionId!, MeasurementRecord(
      sessionId: _currentSessionId!,
      stationNo: station.no,
      ih: ih,
      planLevelColumn: _selectedPlanLevelColumn,
      targetReading: station.targetReading,
      actualReading: station.actualReading,
      cutFill: station.cutFill,
      cutFillStatus: station.cutFillStatus,
      measuredAt: DateTime.now(),
    ));

    // 측점 번호 목록 업데이트
    if (!_sessionStationNos.contains(station.no)) {
      _sessionStationNos.add(station.no);
    }

    // 세션 이름 자동 업데이트: "2026-02-19 NO.0~NO.5"
    final today = DateTime.now();
    final todayStr = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    final firstNo = _sessionStationNos.first;
    final lastNo = _sessionStationNos.last;
    final sessionName = _sessionStationNos.length == 1
        ? '$todayStr $firstNo'
        : '$todayStr $firstNo~$lastNo';

    await db.updateSession(_currentSessionId!,
        name: sessionName, ih: ih, planLevelColumn: _selectedPlanLevelColumn);

    // 야장 뷰용 레코드 캐시 갱신
    await _loadSessionRecords();
  }

  /// 세션 레코드 캐시 로드
  Future<void> _loadSessionRecords() async {
    if (_currentSessionId == null) {
      _sessionRecords = [];
      return;
    }
    final db = DatabaseService.instance;
    _sessionRecords = await db.getRecords(_currentSessionId!);
    if (mounted) setState(() {});
  }

  /// 다음 측점으로 이동
  /// 현재 측점이 보간(플러스 체인)이면 다음 플러스 체인으로,
  /// 기본 측점이면 다음 기본 측점으로 이동
  void _moveToNextStation() {
    if (_selectedStationIndex == null) return;
    final currentStation = _selectedStation;
    if (currentStation == null) return;

    final stations = widget.stations;
    final startIdx = _selectedStationIndex! + 1;

    if (currentStation.isInterpolated) {
      // 보간 측점이면 다음 측점으로 (종류 무관)
      if (startIdx < stations.length) {
        setState(() {
          _selectedStationIndex = startIdx;
          _loadStationData();
        });
      }
    } else {
      // 기본 측점이면 다음 기본 측점으로
      for (int i = startIdx; i < stations.length; i++) {
        if (stations[i].isBaseStation) {
          setState(() {
            _selectedStationIndex = i;
            _loadStationData();
          });
          return;
        }
      }
      // 다음 기본 측점이 없으면 그냥 다음 측점
      if (startIdx < stations.length) {
        setState(() {
          _selectedStationIndex = startIdx;
          _loadStationData();
        });
      }
    }
  }

  /// 측량 이력 보기
  void _showSessionHistory() async {
    if (widget.projectId == null) return;
    final db = DatabaseService.instance;
    final sessions = await db.getSessions(widget.projectId!);

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          builder: (context, scrollController) {
            return Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.history, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '측량 이력 (${sessions.length}건)',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: sessions.isEmpty
                      ? Center(
                          child: Text(
                            '저장된 측량 이력이 없습니다',
                            style: TextStyle(color: Colors.grey[400]),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: sessions.length,
                          itemBuilder: (context, index) {
                            final session = sessions[index];
                            final isToday = _currentSessionId == session.id;
                            final created = session.createdAt;
                            final hour = created.hour;
                            final ampm = hour < 12 ? 'AM' : 'PM';
                            final h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
                            final timeStr = '$h12:${created.minute.toString().padLeft(2, '0')} $ampm';
                            final dateStr = '${created.month}/${created.day}';

                            return InkWell(
                              onTap: () async {
                                Navigator.pop(context);
                                await _showSessionDetail(session);
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isToday ? Colors.blue.withValues(alpha: 0.05) : null,
                                  border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isToday ? Icons.edit_note : Icons.assignment,
                                      color: isToday ? Colors.blue : Colors.grey,
                                      size: 22,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            session.name,
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '$dateStr $timeStr  |  ${session.recordCount}건  |  ${_planLevelColumnLabel(session.planLevelColumn)}  |  IH ${session.ih?.toStringAsFixed(widget.decimalPlaces) ?? "-"}',
                                            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isToday)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.blue[50],
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text('오늘', style: TextStyle(fontSize: 11, color: Colors.blue)),
                                      ),
                                    const SizedBox(width: 4),
                                    Icon(Icons.chevron_right, size: 18, color: Colors.grey[400]),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 세션 불러오기 (이력에서 선택 시)
  Future<void> _loadSession(MeasurementSession session) async {
    final db = DatabaseService.instance;
    final records = await db.getRecords(session.id!);

    setState(() {
      _currentSessionId = session.id;
      _sessionStationNos = records.map((r) => r.stationNo).toList();
      _sessionRecords = records;

      // IH 복원
      if (session.ih != null) {
        _ihController.text = session.ih!.toString();
      }

      // 계획고 컬럼 복원
      if (session.planLevelColumn != null) {
        _selectedPlanLevelColumn = session.planLevelColumn!;
      }

      // 첫 측점으로 이동
      if (_sessionStationNos.isNotEmpty) {
        final firstNo = _sessionStationNos.first;
        final idx = widget.stations.indexWhere((s) => s.no == firstNo);
        if (idx >= 0) {
          _selectedStationIndex = idx;
        }
      }
    });

    // 측점 데이터 로드
    _loadStationData();
    _calculate();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${session.name} 불러옴'),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// 계획고 컬럼 이름 한글 변환
  String _planLevelColumnLabel(String? column) {
    switch (column) {
      case 'GH': return '지반고';
      case 'IP': return '계획하상고';
      case 'deepestBedLevel': return '최심하상고';
      case 'plannedFloodLevel': return '계획홍수위';
      case 'leftBankHeight': return '좌안제방고';
      case 'rightBankHeight': return '우안제방고';
      case 'plannedBankLeft': return '계획제방고(L)';
      case 'plannedBankRight': return '계획제방고(R)';
      case 'roadbedLeft': return '노체(L)';
      case 'roadbedRight': return '노체(R)';
      default: return column ?? '-';
    }
  }

  /// 기초레벨 기준 컬럼 선택 피커
  void _showPlanColumnPicker({
    required String selectedColumn,
    required void Function(String) onSelected,
  }) {
    const columns = [
      {'value': 'GH', 'label': '지반고'},
      {'value': 'IP', 'label': '계획하상고'},
      {'value': 'deepestBedLevel', 'label': '최심하상고'},
      {'value': 'plannedFloodLevel', 'label': '계획홍수위'},
      {'value': 'leftBankHeight', 'label': '좌안제방고'},
      {'value': 'rightBankHeight', 'label': '우안제방고'},
      {'value': 'plannedBankLeft', 'label': '계획제방고(L)'},
      {'value': 'plannedBankRight', 'label': '계획제방고(R)'},
      {'value': 'roadbedLeft', 'label': '노체(L)'},
      {'value': 'roadbedRight', 'label': '노체(R)'},
    ];

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final bottomPadding = MediaQuery.of(ctx).viewPadding.bottom;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[400],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.calculate, size: 20),
                  SizedBox(width: 8),
                  Text(
                    '기준 컬럼 선택',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ...columns.map((col) {
              final value = col['value']!;
              final label = col['label']!;
              final isSelected = selectedColumn == value;
              return ListTile(
                dense: true,
                selected: isSelected,
                selectedTileColor: Colors.blue[50],
                leading: Icon(
                  isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  size: 20,
                  color: isSelected ? Colors.blue : Colors.grey,
                ),
                title: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.bold : null,
                  ),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  onSelected(value);
                },
              );
            }),
            SizedBox(height: 8 + bottomPadding),
          ],
        );
      },
    );
  }

  /// 세션 상세 보기 (기록 목록 + 불러오기 버튼)
  Future<void> _showSessionDetail(MeasurementSession session) async {
    final db = DatabaseService.instance;
    final records = await db.getRecords(session.id!);

    if (!mounted) return;

    final created = session.createdAt;
    final hour = created.hour;
    final ampm = hour < 12 ? 'AM' : 'PM';
    final h12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final timeStr = '$h12:${created.minute.toString().padLeft(2, '0')} $ampm';
    final dateStr = '${created.year}.${created.month.toString().padLeft(2, '0')}.${created.day.toString().padLeft(2, '0')}';
    final dp = widget.decimalPlaces;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return Column(
              children: [
                // 핸들
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 세션 정보 헤더
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        session.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.calendar_today, size: 13, color: Colors.grey[500]),
                          const SizedBox(width: 4),
                          Text(
                            '$dateStr  $timeStr',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                          const SizedBox(width: 12),
                          Icon(Icons.tag, size: 13, color: Colors.grey[500]),
                          const SizedBox(width: 4),
                          Text(
                            '${records.length}건',
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                          const SizedBox(width: 12),
                          Icon(Icons.straighten, size: 13, color: Colors.grey[500]),
                          const SizedBox(width: 4),
                          Text(
                            _planLevelColumnLabel(session.planLevelColumn),
                            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            'IH ${session.ih?.toStringAsFixed(dp) ?? "-"}',
                            style: TextStyle(fontSize: 12, color: Colors.orange[700], fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // 테이블 헤더
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  color: Colors.grey[50],
                  child: const Row(
                    children: [
                      SizedBox(width: 70, child: Text('측점', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold))),
                      Expanded(child: Text('읽을값', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
                      Expanded(child: Text('읽은값', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
                      SizedBox(width: 60, child: Text('차이', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
                      SizedBox(width: 30, child: Text('판정', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold), textAlign: TextAlign.center)),
                    ],
                  ),
                ),
                const Divider(height: 1),
                // 기록 리스트
                Expanded(
                  child: records.isEmpty
                      ? const Center(child: Text('기록 없음', style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          controller: scrollController,
                          itemCount: records.length,
                          itemBuilder: (context, index) {
                            final r = records[index];
                            Color statusColor = Colors.grey;
                            String statusLabel = '-';
                            if (r.cutFillStatus == 'CUT') {
                              statusColor = Colors.red;
                              statusLabel = 'C';
                            } else if (r.cutFillStatus == 'FILL') {
                              statusColor = Colors.green;
                              statusLabel = 'F';
                            } else if (r.cutFillStatus == 'ON_GRADE') {
                              statusColor = Colors.blue;
                              statusLabel = 'OK';
                            }

                            // IH 변경 감지
                            final prevIh = index > 0 ? records[index - 1].ih : null;
                            final ihChanged = r.ih != null && prevIh != null && r.ih != prevIh;
                            final isFirst = index == 0 && r.ih != null;

                            return Column(
                              children: [
                                if (isFirst || ihChanged)
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 16),
                                    color: Colors.orange[50],
                                    child: Text(
                                      'IH: ${r.ih!.toStringAsFixed(dp)}  |  ${_planLevelColumnLabel(r.planLevelColumn)}',
                                      style: TextStyle(fontSize: 11, color: Colors.orange[800], fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  decoration: BoxDecoration(
                                    border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 70,
                                        child: Text(r.stationNo, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                                      ),
                                      Expanded(
                                        child: Text(
                                          r.targetReading?.toStringAsFixed(dp) ?? '-',
                                          style: const TextStyle(fontSize: 13),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          r.actualReading?.toStringAsFixed(dp) ?? '-',
                                          style: const TextStyle(fontSize: 13),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      SizedBox(
                                        width: 60,
                                        child: Text(
                                          r.cutFill?.toStringAsFixed(dp) ?? '-',
                                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: statusColor),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                      SizedBox(
                                        width: 30,
                                        child: Text(
                                          statusLabel,
                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: statusColor),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
                // 하단: 불러오기 + 삭제 버튼
                Container(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + MediaQuery.of(context).viewPadding.bottom),
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: Colors.grey[300]!)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            _loadSession(session);
                          },
                          icon: const Icon(Icons.download, size: 18),
                          label: const Text('이력 불러오기'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('이력 삭제', style: TextStyle(fontSize: 16)),
                              content: const Text('이 측량 이력을 삭제하시겠습니까?\n삭제 후 복구할 수 없습니다.'),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('삭제', style: TextStyle(color: Colors.red)),
                                ),
                              ],
                            ),
                          );
                          if (confirm == true && context.mounted) {
                            final nav = Navigator.of(context);
                            final messenger = ScaffoldMessenger.of(context);
                            final db = DatabaseService.instance;
                            await db.deleteSession(session.id!);
                            nav.pop();
                            messenger.showSnackBar(
                              const SnackBar(content: Text('이력이 삭제되었습니다'), duration: Duration(seconds: 1)),
                            );
                          }
                        },
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('삭제'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red[50],
                          foregroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 샘플 측량 세션 5개 생성
  /// 각 구간 ~10개 기본측점, 계획하상고(IP) 기준, 읽은값 = 읽을값 ± 3~20cm
  Future<void> _generateSampleSessions() async {
    if (widget.projectId == null || widget.stations.isEmpty) return;
    final db = DatabaseService.instance;
    final rng = Random(42); // 재현 가능한 시드

    // 기본측점만 추출
    final baseStations = widget.stations.where((s) => s.isBaseStation).toList();
    if (baseStations.length < 10) return;

    // 5개 구간 정의 (각 ~10개 기본측점)
    final segments = <Map<String, dynamic>>[];
    const stationsPerSegment = 10;
    for (int seg = 0; seg < 5; seg++) {
      final startIdx = seg * stationsPerSegment;
      final endIdx = (startIdx + stationsPerSegment).clamp(0, baseStations.length);
      if (startIdx >= baseStations.length) break;
      segments.add({
        'startIdx': startIdx,
        'endIdx': endIdx,
        'stations': baseStations.sublist(startIdx, endIdx),
      });
    }

    final today = DateTime.now();

    for (int i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final stationList = seg['stations'] as List<StationData>;
      if (stationList.isEmpty) continue;

      // 날짜를 과거로 분산 (오늘 포함)
      final sessionDate = today.subtract(Duration(days: segments.length - 1 - i));
      final dateStr = '${sessionDate.year}-${sessionDate.month.toString().padLeft(2, '0')}-${sessionDate.day.toString().padLeft(2, '0')}';

      // IH 결정: 구간 내 최대 IP + 1.2~1.8m (현실적인 기계고)
      double maxIp = 0;
      for (final s in stationList) {
        if (s.ip != null && s.ip! > maxIp) maxIp = s.ip!;
      }
      final ih = maxIp + 1.2 + rng.nextDouble() * 0.6; // IP 최대 + 1.2~1.8
      final ihRounded = (ih * 1000).round() / 1000.0;

      final firstName = stationList.first.no;
      final lastName = stationList.last.no;
      final sessionName = '$dateStr $firstName~$lastName';

      final sessionId = await db.createSession(
        widget.projectId!,
        sessionName,
        ih: ihRounded,
        planLevelColumn: 'IP',
      );

      // 세션 날짜를 과거로 조작 (DB 직접 업데이트)
      final dbInst = await db.database;
      await dbInst.update(
        'measurement_sessions',
        {
          'created_at': sessionDate.toIso8601String(),
          'last_modified': sessionDate.toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [sessionId],
      );

      // 각 측점에 대해 측량 기록 생성
      for (final station in stationList) {
        final planLevel = station.ip;
        if (planLevel == null) continue;

        final targetReading = ihRounded - planLevel;

        // 읽은 값: 읽을 값 ± 3~20cm (랜덤 오차)
        final errorCm = 3 + rng.nextInt(18); // 3~20cm
        final sign = rng.nextBool() ? 1.0 : -1.0;
        final errorM = sign * errorCm / 100.0;
        final actualReading = targetReading + errorM;
        final actualRounded = (actualReading * 1000).round() / 1000.0;

        final cutFill = targetReading - actualRounded;
        final cutFillRounded = (cutFill * 1000).round() / 1000.0;
        final cutFillStatus = LevelCalculationService.determineCutFillStatus(cutFillRounded);

        // 세션에 기록 저장 (per-record IH, planLevelColumn 포함)
        await db.upsertRecord(sessionId, MeasurementRecord(
          sessionId: sessionId,
          stationNo: station.no,
          ih: ihRounded,
          planLevelColumn: 'IP',
          targetReading: (targetReading * 1000).round() / 1000.0,
          actualReading: actualRounded,
          cutFill: cutFillRounded,
          cutFillStatus: cutFillStatus,
          measuredAt: sessionDate,
        ));

        // 측점 데이터에도 반영
        final updated = station.copyWith(
          actualReading: actualRounded,
          targetReading: (targetReading * 1000).round() / 1000.0,
          cutFill: cutFillRounded,
          cutFillStatus: cutFillStatus,
          lastModified: sessionDate,
        );
        await db.upsertStation(widget.projectId!, updated);
      }
    }

    // 측점 데이터 리로드
    if (widget.projectId != null) {
      final loaded = await db.getStations(widget.projectId!);
      widget.onStationsChanged?.call(loaded);
    }

    debugPrint('[LevelPanel] 샘플 세션 ${segments.length}개 생성 완료');
  }

  // ==================== 야장(레벨북) 뷰 ====================

  /// 간편/야장 토글 버튼
  Widget _buildViewModeToggle() {
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildToggleButton(
            label: '간편',
            icon: Icons.view_list,
            isActive: !_isLevelBookView,
            onTap: () => setState(() => _isLevelBookView = false),
          ),
          _buildToggleButton(
            label: '야장',
            icon: Icons.table_chart,
            isActive: _isLevelBookView,
            onTap: () => setState(() => _isLevelBookView = true),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleButton({
    required String label,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          boxShadow: isActive
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 2)]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: isActive ? Colors.blue : Colors.grey[500]),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                color: isActive ? Colors.blue : Colors.grey[500],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// MeasurementRecord -> _LevelBookRow 변환
  List<_LevelBookRow> _buildLevelBookRows() {
    final records = _sessionRecords;
    if (records.isEmpty) return [];

    final rows = <_LevelBookRow>[];

    for (int i = 0; i < records.length; i++) {
      final r = records[i];
      final prevIh = i > 0 ? records[i - 1].ih : null;
      final isFirst = i == 0;
      final isTurningPoint = !isFirst && r.ih != null && prevIh != null && r.ih != prevIh;

      // 지반고 계산: IH - 읽은값
      double? groundHeight;
      final currentIh = r.ih ?? (i > 0 ? records[i - 1].ih : null);
      if (currentIh != null && r.actualReading != null) {
        groundHeight = currentIh - r.actualReading!;
      }

      // 비고 생성
      String remark = '';
      if (isFirst) {
        remark = '기계설치';
      } else if (isTurningPoint) {
        remark = 'T.P';
      }
      if (r.cutFillStatus == 'CUT') {
        remark += remark.isNotEmpty ? '/절토' : '절토';
      } else if (r.cutFillStatus == 'FILL') {
        remark += remark.isNotEmpty ? '/성토' : '성토';
      } else if (r.cutFillStatus == 'ON_GRADE') {
        remark += remark.isNotEmpty ? '/OK' : 'OK';
      }

      rows.add(_LevelBookRow(
        stationNo: r.stationNo,
        ih: (isFirst || isTurningPoint) ? r.ih : null,
        reading: r.actualReading,
        groundHeight: groundHeight,
        cutFill: r.cutFill,
        cutFillStatus: r.cutFillStatus,
        isTurningPoint: isTurningPoint,
        isFirstRecord: isFirst,
        remark: remark,
      ));
    }

    return rows;
  }

  /// 야장 뷰 전체
  Widget _buildLevelBookGrid() {
    final rows = _buildLevelBookRows();

    if (rows.isEmpty) {
      return Center(
        child: Text(
          '측량 기록이 없습니다\n측점을 선택하고 읽은 값을 입력하세요',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[400], fontSize: 14),
        ),
      );
    }

    return Column(
      children: [
        // 야장 헤더
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.brown[50],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            border: Border.all(color: Colors.brown[200]!),
          ),
          child: Row(
            children: [
              SizedBox(width: 76, child: Text('지점', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold, color: Colors.brown[700]), textAlign: TextAlign.center)),
              SizedBox(width: 60, child: Text('I.H', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold, color: Colors.brown[700]), textAlign: TextAlign.center)),
              Expanded(child: Text('읽은값', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold, color: Colors.brown[700]), textAlign: TextAlign.center)),
              Expanded(child: Text('지반고', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold, color: Colors.brown[700]), textAlign: TextAlign.center)),
              SizedBox(width: 60, child: Text('비고', style: TextStyle(fontSize: 12 + widget.fontSizeDelta.toDouble(), fontWeight: FontWeight.bold, color: Colors.brown[700]), textAlign: TextAlign.center)),
            ],
          ),
        ),
        // 야장 데이터
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemExtent: 40,
            itemBuilder: (context, index) {
              return _buildLevelBookRow(rows[index], index);
            },
          ),
        ),
        // 합계/검산 행
        _buildLevelBookSummary(rows),
      ],
    );
  }

  /// 야장 개별 행
  Widget _buildLevelBookRow(_LevelBookRow row, int index) {
    final isCurrentStation = _selectedStation?.no == row.stationNo;

    // 배경색
    Color? bgColor;
    if (isCurrentStation) {
      bgColor = Colors.blue.withValues(alpha: 0.08);
    } else if (row.isTurningPoint) {
      bgColor = Colors.orange.withValues(alpha: 0.08);
    } else if (row.isFirstRecord) {
      bgColor = Colors.green.withValues(alpha: 0.06);
    }

    // 절/성토 색상
    Color? statusColor;
    if (row.cutFillStatus == 'CUT') {
      statusColor = Colors.red;
    } else if (row.cutFillStatus == 'FILL') {
      statusColor = Colors.green;
    } else if (row.cutFillStatus == 'ON_GRADE') {
      statusColor = Colors.blue;
    }

    return InkWell(
      onTap: () {
        final idx = widget.stations.indexWhere((st) => st.no == row.stationNo);
        if (idx >= 0) {
          setState(() {
            _selectedStationIndex = idx;
            _loadStationData();
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: bgColor,
          border: Border(
            bottom: BorderSide(color: Colors.grey[200]!),
            top: row.isTurningPoint
                ? BorderSide(color: Colors.orange[300]!, width: 1.5)
                : BorderSide.none,
          ),
        ),
        child: Row(
          children: [
            // 지점
            SizedBox(
              width: 76,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (row.isFirstRecord || row.isTurningPoint)
                    Icon(
                      row.isFirstRecord ? Icons.flag : Icons.swap_vert,
                      size: 12,
                      color: row.isFirstRecord ? Colors.green : Colors.orange,
                    ),
                  if (row.isFirstRecord || row.isTurningPoint)
                    const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      row.stationNo,
                      style: TextStyle(
                        fontSize: 13 + widget.fontSizeDelta.toDouble(),
                        fontWeight: isCurrentStation ? FontWeight.bold : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            // I.H (변경 시점만)
            SizedBox(
              width: 60,
              child: row.ih != null
                  ? Text(
                      row.ih!.toStringAsFixed(widget.decimalPlaces),
                      style: TextStyle(
                        fontSize: 12 + widget.fontSizeDelta.toDouble(),
                        fontWeight: FontWeight.bold,
                        color: Colors.orange[700],
                      ),
                      textAlign: TextAlign.center,
                    )
                  : const SizedBox.shrink(),
            ),
            // 읽은값
            Expanded(
              child: Text(
                row.reading?.toStringAsFixed(widget.decimalPlaces) ?? '-',
                style: TextStyle(fontSize: 13 + widget.fontSizeDelta.toDouble()),
                textAlign: TextAlign.center,
              ),
            ),
            // 지반고(G.H)
            Expanded(
              child: Text(
                row.groundHeight?.toStringAsFixed(widget.decimalPlaces) ?? '-',
                style: TextStyle(
                  fontSize: 13 + widget.fontSizeDelta.toDouble(),
                  color: statusColor,
                  fontWeight: statusColor != null ? FontWeight.bold : null,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            // 비고
            SizedBox(
              width: 60,
              child: Text(
                row.remark,
                style: TextStyle(
                  fontSize: 10 + widget.fontSizeDelta.toDouble(),
                  color: row.isTurningPoint ? Colors.orange[700] : Colors.grey[600],
                  fontWeight: row.isTurningPoint ? FontWeight.bold : null,
                ),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 야장 하단 합계/검산 행
  Widget _buildLevelBookSummary(List<_LevelBookRow> rows) {
    if (rows.isEmpty) return const SizedBox.shrink();

    int tpCount = rows.where((r) => r.isTurningPoint).length;
    int totalCount = rows.length;
    double? minGh, maxGh;
    for (final r in rows) {
      if (r.groundHeight == null) continue;
      if (minGh == null || r.groundHeight! < minGh) minGh = r.groundHeight!;
      if (maxGh == null || r.groundHeight! > maxGh) maxGh = r.groundHeight!;
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.brown[50],
        border: Border(top: BorderSide(color: Colors.brown[200]!, width: 1.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          Text('총 $totalCount점', style: TextStyle(fontSize: 11 + widget.fontSizeDelta.toDouble(), color: Colors.brown[700])),
          Text('이기 $tpCount회', style: TextStyle(fontSize: 11 + widget.fontSizeDelta.toDouble(), color: Colors.orange[700])),
          if (minGh != null && maxGh != null)
            Text(
              'GH: ${minGh.toStringAsFixed(widget.decimalPlaces)}~${maxGh.toStringAsFixed(widget.decimalPlaces)}',
              style: TextStyle(fontSize: 11 + widget.fontSizeDelta.toDouble(), color: Colors.brown[700]),
            ),
        ],
      ),
    );
  }

  // ==================== 기초레벨 산정 ====================

  /// 기초레벨 산정 다이얼로그
  void _showFoundationLevelDialog() {
    if (widget.stations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('측점 데이터가 없습니다')),
      );
      return;
    }

    final baseStations = widget.stations.where((s) => s.isBaseStation).toList();
    if (baseStations.length < 2) return;

    String? startNo = baseStations.first.no;
    String? endNo = baseStations.last.no;
    String side = 'both'; // 'L', 'R', 'both'
    int interpolation = 5;
    String planColumn = 'IP'; // 기준 컬럼
    final excavationController = TextEditingController(text: '90');
    final offsetController = TextEditingController(text: '0');

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.layers, size: 22, color: Colors.blue),
              SizedBox(width: 8),
              Text('레벨계산', style: TextStyle(fontSize: 18)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 시작 측점
                Text('시작 측점', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 4),
                InkWell(
                  onTap: () {
                    _showStationPickerDialog(
                      title: '시작 측점',
                      stations: baseStations,
                      selectedNo: startNo,
                      onSelected: (no) => setDialogState(() => startNo = no),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            startNo ?? '선택',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: startNo != null ? null : Colors.grey,
                            ),
                          ),
                        ),
                        const Icon(Icons.unfold_more, size: 18, color: Colors.grey),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // 종료 측점
                Text('종료 측점', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 4),
                InkWell(
                  onTap: () {
                    _showStationPickerDialog(
                      title: '종료 측점',
                      stations: baseStations,
                      selectedNo: endNo,
                      onSelected: (no) => setDialogState(() => endNo = no),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            endNo ?? '선택',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: endNo != null ? null : Colors.grey,
                            ),
                          ),
                        ),
                        const Icon(Icons.unfold_more, size: 18, color: Colors.grey),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 위치 (좌안/우안/양쪽)
                Text('위치', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'L', label: Text('좌안')),
                      ButtonSegment(value: 'R', label: Text('우안')),
                      ButtonSegment(value: 'both', label: Text('양쪽')),
                    ],
                    selected: {side},
                    onSelectionChanged: (v) => setDialogState(() => side = v.first),
                  ),
                ),
                const SizedBox(height: 16),

                // 보간 간격
                Text('보간 간격', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 5, label: Text('5m')),
                      ButtonSegment(value: 10, label: Text('10m')),
                      ButtonSegment(value: 15, label: Text('15m')),
                    ],
                    selected: {interpolation},
                    onSelectionChanged: (v) => setDialogState(() => interpolation = v.first),
                  ),
                ),
                const SizedBox(height: 16),

                // 기준 컬럼 선택
                Text('기준 컬럼', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 4),
                InkWell(
                  onTap: () {
                    _showPlanColumnPicker(
                      selectedColumn: planColumn,
                      onSelected: (col) => setDialogState(() => planColumn = col),
                    );
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey[300]!),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _planLevelColumnLabel(planColumn),
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const Icon(Icons.unfold_more, size: 18, color: Colors.grey),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 터파기 값
                Text('터파기', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 4),
                TextField(
                  controller: excavationController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    suffixText: 'cm',
                    hintText: '예: 90',
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
                const SizedBox(height: 16),

                // 보정값
                Text('보정값', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(height: 4),
                TextField(
                  controller: offsetController,
                  keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    suffixText: 'm',
                    hintText: '예: -0.5 또는 0.3',
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _showSavedFoundationList();
              },
              child: const Text('저장목록'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            ElevatedButton(
              onPressed: () {
                final excavationCm = int.tryParse(excavationController.text);
                final offsetM = double.tryParse(offsetController.text) ?? 0.0;
                if (startNo == null || endNo == null || excavationCm == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('모든 값을 입력하세요')),
                  );
                  return;
                }
                Navigator.pop(context);
                final results = _calculateFoundationLevel(
                  startNo: startNo!,
                  endNo: endNo!,
                  side: side,
                  interpolation: interpolation,
                  excavationCm: excavationCm,
                  planColumn: planColumn,
                  offsetM: offsetM,
                );
                _showFoundationLevelResult(
                  results: results,
                  side: side,
                  excavationCm: excavationCm,
                  startNo: startNo!,
                  endNo: endNo!,
                  interpolation: interpolation,
                  planColumn: planColumn,
                  offsetM: offsetM,
                );
              },
              child: const Text('계산'),
            ),
          ],
        ),
      ),
    );
  }

  /// 측점 선택 다이얼로그 (기초레벨용)
  void _showStationPickerDialog({
    required String title,
    required List<StationData> stations,
    required String? selectedNo,
    required ValueChanged<String> onSelected,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        contentPadding: const EdgeInsets.only(top: 12),
        content: SizedBox(
          width: double.maxFinite,
          height: 350,
          child: ListView.builder(
            itemCount: stations.length,
            itemBuilder: (context, index) {
              final s = stations[index];
              final isSelected = selectedNo == s.no;
              return ListTile(
                dense: true,
                leading: const Icon(Icons.place, size: 18, color: Colors.blue),
                title: Text(
                  s.no,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.bold : null,
                    color: isSelected ? Colors.blue : null,
                  ),
                ),
                trailing: Text(
                  '${s.distance?.toStringAsFixed(0) ?? "-"}m',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
                selected: isSelected,
                selectedTileColor: Colors.blue[50],
                onTap: () {
                  Navigator.pop(context);
                  onSelected(s.no);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  /// StationData에서 지정된 컬럼 값 가져오기
  double? _getStationColumnValue(StationData station, String column) {
    switch (column) {
      case 'GH': return station.gh;
      case 'IP': return station.ip;
      case 'deepestBedLevel': return station.deepestBedLevel;
      case 'plannedFloodLevel': return station.plannedFloodLevel;
      case 'leftBankHeight': return station.leftBankHeight;
      case 'rightBankHeight': return station.rightBankHeight;
      case 'plannedBankLeft': return station.plannedBankLeft;
      case 'plannedBankRight': return station.plannedBankRight;
      case 'roadbedLeft': return station.roadbedLeft;
      case 'roadbedRight': return station.roadbedRight;
      default: return station.ip;
    }
  }

  /// 기초레벨 계산
  List<_FoundationResult> _calculateFoundationLevel({
    required String startNo,
    required String endNo,
    required String side,
    required int interpolation,
    required int excavationCm,
    required String planColumn,
    double offsetM = 0.0,
  }) {
    final excavationM = excavationCm / 100.0;

    // 시작/종료 측점의 distance 찾기
    final startStation = widget.stations.firstWhere((s) => s.no == startNo);
    final endStation = widget.stations.firstWhere((s) => s.no == endNo);
    final startDist = startStation.distance ?? 0;
    final endDist = endStation.distance ?? 0;

    // 범위 내 원본(비보간) 측점 필터
    final rangeStations = widget.stations
        .where((s) =>
            !s.isInterpolated &&
            s.distance != null &&
            s.distance! >= startDist &&
            s.distance! <= endDist)
        .toList()
      ..sort((a, b) => a.distance!.compareTo(b.distance!));

    // 보간 실행
    final interpolated = InterpolationService.interpolateAllStations(
      allStations: rangeStations,
      interval: interpolation,
    );

    // 결과 생성
    return interpolated.map((s) {
      final baseValue = _getStationColumnValue(s, planColumn);
      double? foundationL;
      double? foundationR;

      if (baseValue != null) {
        final foundation = baseValue - excavationM + offsetM;
        if (side == 'L' || side == 'both') foundationL = foundation;
        if (side == 'R' || side == 'both') foundationR = foundation;
      }

      return _FoundationResult(
        stationNo: s.no,
        baseValue: baseValue,
        foundationL: foundationL,
        foundationR: foundationR,
        isInterpolated: s.isInterpolated,
      );
    }).toList();
  }

  /// 기초레벨 결과 바텀시트
  void _showFoundationLevelResult({
    required List<_FoundationResult> results,
    required String side,
    required int excavationCm,
    required String startNo,
    required String endNo,
    required int interpolation,
    String planColumn = 'IP',
    double offsetM = 0.0,
  }) {
    final showL = side == 'L' || side == 'both';
    final showR = side == 'R' || side == 'both';
    final dp = widget.decimalPlaces;
    final fd = widget.fontSizeDelta.toDouble();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return Column(
              children: [
                // 핸들
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // 헤더
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      const Icon(Icons.layers, size: 20, color: Colors.blue),
                      const SizedBox(width: 8),
                      Text(
                        '기초레벨 결과',
                        style: TextStyle(fontSize: 16 + fd, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.orange[50],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '터파기 ${excavationCm}cm${offsetM != 0.0 ? ', 보정 ${offsetM > 0 ? '+' : ''}${offsetM}m' : ''}',
                          style: TextStyle(fontSize: 12, color: Colors.orange[800], fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.save, size: 22, color: Colors.green),
                        tooltip: '결과 저장',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () => _saveFoundationResult(
                          results: results,
                          side: side,
                          excavationCm: excavationCm,
                          startNo: startNo,
                          endNo: endNo,
                          interpolation: interpolation,
                          planColumn: planColumn,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // 테이블 헤더
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 90,
                        child: Text('측점', style: TextStyle(fontSize: 12 + fd, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                      ),
                      Expanded(
                        child: Text(_planLevelColumnLabel(planColumn), style: TextStyle(fontSize: 12 + fd, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                      ),
                      if (showL)
                        Expanded(
                          child: Text('기초(L)', style: TextStyle(fontSize: 12 + fd, fontWeight: FontWeight.bold, color: Colors.blue[700]), textAlign: TextAlign.center),
                        ),
                      if (showR)
                        Expanded(
                          child: Text('기초(R)', style: TextStyle(fontSize: 12 + fd, fontWeight: FontWeight.bold, color: Colors.teal[700]), textAlign: TextAlign.center),
                        ),
                    ],
                  ),
                ),

                // 데이터 행
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    itemCount: results.length,
                    itemExtent: 40,
                    itemBuilder: (context, index) {
                      final r = results[index];
                      final isInterp = r.isInterpolated;

                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: isInterp ? Colors.indigo[50] : (index.isEven ? Colors.white : Colors.grey[50]),
                          border: Border(bottom: BorderSide(color: Colors.grey[200]!)),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 90,
                              child: Text(
                                r.stationNo,
                                style: TextStyle(
                                  fontSize: 13 + fd,
                                  fontWeight: isInterp ? FontWeight.normal : FontWeight.bold,
                                  color: isInterp ? Colors.indigo[600] : null,
                                  fontStyle: isInterp ? FontStyle.italic : null,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Expanded(
                              child: Text(
                                r.baseValue?.toStringAsFixed(dp) ?? '-',
                                style: TextStyle(fontSize: 13 + fd),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            if (showL)
                              Expanded(
                                child: Text(
                                  r.foundationL?.toStringAsFixed(dp) ?? '-',
                                  style: TextStyle(
                                    fontSize: 13 + fd,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blue[700],
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            if (showR)
                              Expanded(
                                child: Text(
                                  r.foundationR?.toStringAsFixed(dp) ?? '-',
                                  style: TextStyle(
                                    fontSize: 13 + fd,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.teal[700],
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // 하단 요약
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    border: Border(top: BorderSide(color: Colors.grey[300]!)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '총 ${results.length}개 측점',
                        style: TextStyle(fontSize: 12 + fd, color: Colors.grey[600]),
                      ),
                      Text(
                        '보간 ${results.where((r) => r.isInterpolated).length}개',
                        style: TextStyle(fontSize: 12 + fd, color: Colors.indigo[400]),
                      ),
                      Text(
                        '${_planLevelColumnLabel(planColumn)} | ${side == "both" ? "양쪽" : side == "L" ? "좌안" : "우안"} | ${excavationCm}cm${offsetM != 0.0 ? ' | 보정${offsetM > 0 ? '+' : ''}${offsetM}m' : ''}',
                        style: TextStyle(fontSize: 12 + fd, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 기초레벨 결과 저장
  Future<void> _saveFoundationResult({
    required List<_FoundationResult> results,
    required String side,
    required int excavationCm,
    required String startNo,
    required String endNo,
    required int interpolation,
    String planColumn = 'IP',
  }) async {
    final projectId = widget.projectId;
    if (projectId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('프로젝트가 없습니다')),
        );
      }
      return;
    }

    // 라벨: 범위식별자 + 날짜스탬프
    final now = DateTime.now();
    final stamp = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}';
    final label = '$startNo~${endNo}_$stamp';

    // 결과를 JSON 문자열로 직렬화
    final dataList = results.map((r) => {
      'stationNo': r.stationNo,
      'baseValue': r.baseValue,
      'planColumn': planColumn,
      'foundationL': r.foundationL,
      'foundationR': r.foundationR,
      'isInterpolated': r.isInterpolated,
    }).toList();

    final jsonStr = jsonEncode(dataList);

    try {
      await DatabaseService.instance.saveFoundationResult(
        projectId,
        label: label,
        startStationNo: startNo,
        endStationNo: endNo,
        side: side,
        interpolation: interpolation,
        excavationCm: excavationCm,
        data: jsonStr,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 완료: $label')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    }
  }

  /// 저장된 기초레벨 결과 목록
  void _showSavedFoundationList() async {
    final projectId = widget.projectId;
    if (projectId == null) return;

    final saved = await DatabaseService.instance.getFoundationResults(projectId);
    if (!mounted) return;

    if (saved.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('저장된 기초레벨 결과가 없습니다')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.folder_open, size: 22, color: Colors.blue),
            SizedBox(width: 8),
            Text('저장된 기초레벨', style: TextStyle(fontSize: 18)),
          ],
        ),
        contentPadding: const EdgeInsets.only(top: 12),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: ListView.builder(
            itemCount: saved.length,
            itemBuilder: (context, index) {
              final row = saved[index];
              final label = row['label'] as String;
              final side = row['side'] as String;
              final excCm = row['excavation_cm'] as int;
              final interp = row['interpolation'] as int;
              final createdAt = DateTime.parse(row['created_at'] as String);
              final sideLabel = side == 'both' ? '양쪽' : side == 'L' ? '좌안' : '우안';

              return ListTile(
                dense: true,
                leading: const Icon(Icons.layers, size: 20, color: Colors.blue),
                title: Text(
                  label,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  '$sideLabel | ${excCm}cm | ${interp}m간격 | ${createdAt.month}/${createdAt.day} ${createdAt.hour}:${createdAt.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                ),
                trailing: IconButton(
                  icon: Icon(Icons.delete, size: 18, color: Colors.red[300]),
                  onPressed: () async {
                    await DatabaseService.instance.deleteFoundationResult(row['id'] as int);
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    _showSavedFoundationList();
                  },
                ),
                onTap: () {
                  Navigator.pop(context);
                  _loadFoundationResult(row);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  /// 저장된 기초레벨 결과 불러와서 표시
  void _loadFoundationResult(Map<String, dynamic> row) {
    final side = row['side'] as String;
    final excavationCm = row['excavation_cm'] as int;
    final startNo = row['start_station_no'] as String;
    final endNo = row['end_station_no'] as String;
    final interpolation = row['interpolation'] as int;
    final dataStr = row['data'] as String;

    try {
      final List<dynamic> dataList = jsonDecode(dataStr);
      // planColumn: 새 형식이면 baseValue/planColumn, 구형식이면 ip 키로 호환
      String loadedPlanColumn = 'IP';
      final results = dataList.map((item) {
        final m = item as Map<String, dynamic>;
        if (m.containsKey('planColumn')) {
          loadedPlanColumn = m['planColumn'] as String? ?? 'IP';
        }
        return _FoundationResult(
          stationNo: m['stationNo'] as String,
          baseValue: (m['baseValue'] as num?)?.toDouble() ?? (m['ip'] as num?)?.toDouble(),
          foundationL: (m['foundationL'] as num?)?.toDouble(),
          foundationR: (m['foundationR'] as num?)?.toDouble(),
          isInterpolated: m['isInterpolated'] as bool? ?? false,
        );
      }).toList();

      _showFoundationLevelResult(
        results: results,
        side: side,
        excavationCm: excavationCm,
        startNo: startNo,
        endNo: endNo,
        interpolation: interpolation,
        planColumn: loadedPlanColumn,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('데이터 로드 실패: $e')),
      );
    }
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('레벨 계산 도움말'),
        content: const SingleChildScrollView(
          child: Text(
            '1. 측점 선택: 상단에서 측점 선택, 좌우 버튼으로 이동\n'
            '2. IH (기계고): 측량 기기의 시준선 고도 입력\n'
            '3. 읽을 값: IH - 계획고 (자동 계산)\n'
            '4. 읽은 값: 현장 측정값 입력 후 저장\n'
            '5. 절/성토: CUT(파내기) / FILL(쌓기) / OK(맞음)\n'
            '6. 하단 그리드: 측량 완료된 기록 모아보기\n'
            '   - 행을 탭하면 해당 측점으로 이동',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }
}
