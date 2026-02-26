import 'dart:async';
import 'package:flutter/material.dart';
import '../services/excel_service.dart';

import '../services/database_service.dart';
import '../services/interpolation_service.dart';
import '../models/station_data.dart';

/// 데이터 테이블 화면
/// 측점 데이터를 테이블 형태로 표시
/// 모바일에 최적화: 가로 스크롤 + 컬럼 선택
class DataTableScreen extends StatefulWidget {
  final List<StationData> stations;
  final int? projectId;
  final String projectName;
  final void Function(List<StationData>)? onStationsChanged;
  final int decimalPlaces;
  final ValueChanged<int>? onDecimalPlacesChanged;
  final int fontSizeDelta;
  final ValueChanged<int>? onFontSizeDeltaChanged;

  const DataTableScreen({
    super.key,
    this.stations = const [],
    this.projectId,
    this.projectName = '',
    this.onStationsChanged,
    this.decimalPlaces = 3,
    this.onDecimalPlacesChanged,
    this.fontSizeDelta = 0,
    this.onFontSizeDeltaChanged,
  });

  @override
  State<DataTableScreen> createState() => _DataTableScreenState();
}

class _DataTableScreenState extends State<DataTableScreen> {
  // 선택된 측점
  String? _selectedStationNo;

  // 확장된 측점 (한줄 보기에서 탭 시 확장)
  String? _expandedStationNo;

  // 메모 저장 debounce
  Timer? _memoDebounce;

  // 확장 카드 내 메모 컨트롤러
  final TextEditingController _memoController = TextEditingController();

  // 표시할 컬럼 (모바일 화면에 맞게 제한)
  List<String> _visibleColumns = ['누가거리', '지반고', '계획하상고'];

  // 사용 가능한 모든 컬럼 (표시명: 필드명)
  final Map<String, String> _availableColumns = {
    '점간거리': 'intervalDistance',
    '누가거리': 'distance',
    '지반고': 'gh',
    '최심하상고': 'deepestBedLevel',
    '계획하상고': 'ip',
    '계획홍수위': 'plannedFloodLevel',
    '좌안제방고': 'leftBankHeight',
    '우안제방고': 'rightBankHeight',
    '계획제방고(L)': 'plannedBankLeft',
    '계획제방고(R)': 'plannedBankRight',
    '노체(L)': 'roadbedLeft',
    '노체(R)': 'roadbedRight',
    'X': 'x',
    'Y': 'y',
  };

  // 보간 표시 여부
  bool _showInterpolated = true;

  // 보기 형식 ('compact', 'card', 'table')
  String _viewMode = 'compact';

  // 테이블 뷰 스크롤 컨트롤러
  final ScrollController _tableHeaderScrollCtrl = ScrollController();
  final ScrollController _tableFixedColScrollCtrl = ScrollController();
  final ScrollController _tableDataScrollCtrl = ScrollController();
  bool _syncingScroll = false;

  // 측점 범위 필터 (측점 번호 기준)
  String? _rangeStartNo;
  String? _rangeEndNo;

  @override
  void initState() {
    super.initState();
    // 테이블 뷰 세로 스크롤 동기화
    _tableFixedColScrollCtrl.addListener(() {
      if (_syncingScroll) return;
      _syncingScroll = true;
      _tableDataScrollCtrl.jumpTo(_tableFixedColScrollCtrl.offset);
      _syncingScroll = false;
    });
    _tableDataScrollCtrl.addListener(() {
      if (_syncingScroll) return;
      _syncingScroll = true;
      _tableFixedColScrollCtrl.jumpTo(_tableDataScrollCtrl.offset);
      _syncingScroll = false;
    });
  }

  @override
  void dispose() {
    _tableHeaderScrollCtrl.dispose();
    _tableFixedColScrollCtrl.dispose();
    _tableDataScrollCtrl.dispose();
    _memoDebounce?.cancel();
    _memoController.dispose();
    super.dispose();
  }

  List<StationData> get _displayStations {
    var list = _showInterpolated
        ? widget.stations
        : widget.stations.where((s) => !s.isInterpolated).toList();

    // 범위 필터 적용
    if (_rangeStartNo != null || _rangeEndNo != null) {
      final startStation = _rangeStartNo != null
          ? widget.stations.where((s) => s.no == _rangeStartNo).firstOrNull
          : null;
      final endStation = _rangeEndNo != null
          ? widget.stations.where((s) => s.no == _rangeEndNo).firstOrNull
          : null;
      final startDist = startStation?.distance ?? double.negativeInfinity;
      final endDist = endStation?.distance ?? double.infinity;
      list = list.where((s) =>
          s.distance != null &&
          s.distance! >= startDist &&
          s.distance! <= endDist).toList();
    }

    return list;
  }

  /// 현재 범위 라벨
  String get _rangeLabel {
    if (_rangeStartNo == null && _rangeEndNo == null) return '전체';
    final start = _rangeStartNo ?? '처음';
    final end = _rangeEndNo ?? '끝';
    return '$start ~ $end';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.projectName.isNotEmpty
              ? '${widget.projectName} - 측점 데이터'
              : '측점 데이터',
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          // 보간 표시 토글
          IconButton(
            icon: Icon(
              _showInterpolated ? Icons.auto_awesome : Icons.auto_awesome_outlined,
              color: _showInterpolated ? Colors.amber : null,
            ),
            onPressed: () => setState(() => _showInterpolated = !_showInterpolated),
            tooltip: _showInterpolated ? '보간 데이터 숨기기' : '보간 데이터 보기',
          ),
          // 컬럼 선택
          IconButton(
            icon: const Icon(Icons.view_column),
            onPressed: _showColumnSelector,
            tooltip: '컬럼 선택',
          ),
          // 더보기 메뉴
          PopupMenuButton<String>(
            onSelected: _handleMenuAction,
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'import_excel',
                child: ListTile(
                  leading: Icon(Icons.upload_file),
                  title: Text('Excel 가져오기'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'export_excel',
                child: ListTile(
                  leading: Icon(Icons.download),
                  title: Text('Excel 내보내기'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'interpolate',
                child: ListTile(
                  leading: Icon(Icons.auto_awesome),
                  title: Text('보간 실행'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'delete_interpolated',
                child: ListTile(
                  leading: Icon(Icons.delete_sweep),
                  title: Text('보간 데이터 삭제'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'view_mode',
                child: ListTile(
                  leading: Icon(Icons.dashboard),
                  title: Text('보기 형식'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'decimal_places',
                child: ListTile(
                  leading: Icon(Icons.looks_one),
                  title: Text('소수점 자리수'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: 'station_range',
                child: ListTile(
                  leading: Icon(Icons.filter_list),
                  title: Text('측점 범위'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 'font_size',
                child: ListTile(
                  leading: const Icon(Icons.text_fields),
                  title: Text('글꼴 크기${widget.fontSizeDelta > 0 ? " (+$widget.fontSizeDelta)" : ""}'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // 빠른 통계 (상단 카드)
          _buildQuickStats(),

          // 범위 필터 표시 (활성일 때)
          if (_rangeStartNo != null || _rangeEndNo != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: Colors.blue[50],
              child: Row(
                children: [
                  const Icon(Icons.filter_list, size: 16, color: Colors.blue),
                  const SizedBox(width: 6),
                  Text(
                    _rangeLabel,
                    style: const TextStyle(fontSize: 13, color: Colors.blue, fontWeight: FontWeight.w500),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: () => setState(() {
                      _rangeStartNo = null;
                      _rangeEndNo = null;
                    }),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 16, color: Colors.blue),
                    ),
                  ),
                ],
              ),
            ),

          // 데이터 테이블
          Expanded(
            child: _buildDataTable(),
          ),
        ],
      ),
    );
  }

  /// 빠른 통계 카드
  Widget _buildQuickStats() {
    final baseCount = widget.stations.where((s) => s.isBaseStation).length;
    final interpCount = widget.stations.where((s) => s.isInterpolated).length;

    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.grey[100],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem('총 측점', '${widget.stations.length}', Icons.location_on),
          _buildStatItem('기본', '$baseCount', Icons.place),
          _buildStatItem('보간', '$interpCount', Icons.auto_awesome),
          _buildStatItem(
            '범위',
            widget.stations.isEmpty ? '-' : _buildRangeText(),
            Icons.straighten,
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: Colors.blue),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[600],
          ),
        ),
      ],
    );
  }

  /// 범위 텍스트 생성
  /// 기본 측점의 첫/끝 기준, 끝에 플러스 체인이 더 있으면 함께 표시
  String _buildRangeText() {
    final baseStations = widget.stations.where((s) => s.isBaseStation).toList();
    if (baseStations.isEmpty) return widget.stations.first.no;

    final firstBase = baseStations.first.no;
    final lastBase = baseStations.last.no;
    final lastStation = widget.stations.last;

    // 마지막 측점이 마지막 기본 측점 이후의 플러스 체인이면 함께 표시
    if (lastStation.no != lastBase && !lastStation.isBaseStation) {
      // station.no는 "NO.57+7.00" 형태 → "+" 이후만 추출
      final plusIndex = lastStation.no.indexOf('+');
      final plusPart = plusIndex >= 0
          ? lastStation.no.substring(plusIndex)
          : lastStation.no;
      return '$firstBase ~ $lastBase ($plusPart)';
    }

    return '$firstBase ~ $lastBase';
  }

  /// 데이터 테이블 (보기 형식에 따라 분기)
  Widget _buildDataTable() {
    if (widget.stations.isEmpty) {
      return const Center(
        child: Text(
          '데이터 없음\n\nExcel 파일을 가져오거나\n측점을 추가하세요',
          textAlign: TextAlign.center,
        ),
      );
    }

    switch (_viewMode) {
      case 'card':
        return _buildCardView();
      case 'table':
        return _buildTableView();
      default:
        return _buildCompactView();
    }
  }

  /// 보기 형식 1: 한줄 요약 (기본) - 탭 시 확장
  Widget _buildCompactView() {
    final stations = _displayStations;

    return ListView.builder(
      itemCount: stations.length,
      itemBuilder: (context, index) {
        final station = stations[index];
        final isPlusChain = station.no.contains('+');
        final isExpanded = _expandedStationNo == station.no;

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          color: isPlusChain ? Colors.indigo[50] : null,
          shape: RoundedRectangleBorder(
            side: isExpanded
                ? const BorderSide(color: Colors.blue, width: 2)
                : BorderSide(color: Colors.grey[200]!),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              // 헤더 행 (항상 표시)
              InkWell(
                onTap: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedStationNo = null;
                    } else {
                      _expandedStationNo = station.no;
                      _memoController.text = station.memo ?? '';
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      isPlusChain
                          ? Icon(Icons.auto_awesome, size: 18, color: Colors.indigo[300])
                          : const Icon(Icons.place, size: 18, color: Colors.blue),
                      const SizedBox(width: 8),
                      Text(
                        _getDisplayName(station, index),
                        style: TextStyle(
                          fontSize: 13 + widget.fontSizeDelta.toDouble(),
                          fontWeight: isPlusChain ? FontWeight.normal : FontWeight.bold,
                          color: isPlusChain ? Colors.indigo[700] : null,
                          fontStyle: isPlusChain ? FontStyle.italic : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _visibleColumns.map((columnName) {
                            final fieldName = _availableColumns[columnName];
                            if (fieldName == null) return '';
                            final value = _getFieldValue(station, fieldName);
                            final displayValue = value?.toStringAsFixed(widget.decimalPlaces) ?? '-';
                            return '$columnName: $displayValue';
                          }).join('  |  '),
                          style: TextStyle(
                            fontSize: 13 + widget.fontSizeDelta.toDouble(),
                            color: isPlusChain ? Colors.indigo[400] : Colors.grey[700],
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 20,
                        color: Colors.grey[400],
                      ),
                    ],
                  ),
                ),
              ),
              // 확장 영역
              if (isExpanded) _buildExpandedContent(station),
            ],
          ),
        );
      },
    );
  }

  /// 확장 카드 내용: 모든 컬럼 값 + 메모
  Widget _buildExpandedContent(StationData station) {
    final allColumns = _availableColumns.entries.toList();
    final fd = widget.fontSizeDelta.toDouble();

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Divider(color: Colors.grey[300], height: 1),
          const SizedBox(height: 8),
          // 모든 컬럼 값 (2열 그리드)
          Wrap(
            spacing: 0,
            runSpacing: 4,
            children: allColumns.map((entry) {
              final columnName = entry.key;
              final fieldName = entry.value;
              final value = _getFieldValue(station, fieldName);
              final displayValue = value?.toStringAsFixed(widget.decimalPlaces) ?? '-';

              // X, Y 좌표는 소수점이 길어서 라벨과 값을 붙여서 한줄에 표시
              final isCoordinate = fieldName == 'x' || fieldName == 'y';
              final coordDisplay = isCoordinate && value != null
                  ? value.toStringAsFixed(4)
                  : displayValue;

              return SizedBox(
                width: MediaQuery.of(context).size.width / 2 - 24,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: isCoordinate
                      ? Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: '$columnName ',
                              style: TextStyle(fontSize: 11 + fd, color: Colors.grey[700]),
                            ),
                            TextSpan(
                              text: coordDisplay,
                              style: TextStyle(
                                fontSize: 12 + fd,
                                fontWeight: FontWeight.w500,
                                color: value != null ? null : Colors.grey[300],
                              ),
                            ),
                          ]),
                          overflow: TextOverflow.ellipsis,
                        )
                      : Row(
                          children: [
                            SizedBox(
                              width: 80,
                              child: Text(
                                columnName,
                                style: TextStyle(fontSize: 11 + fd, color: Colors.grey[700]),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                displayValue,
                                style: TextStyle(
                                  fontSize: 13 + fd,
                                  fontWeight: FontWeight.w500,
                                  color: value != null ? null : Colors.grey[300],
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          Divider(color: Colors.grey[300], height: 1),
          const SizedBox(height: 8),
          // 메모 영역
          Row(
            children: [
              Icon(Icons.edit_note, size: 16, color: Colors.grey[400]),
              const SizedBox(width: 4),
              Text('메모', style: TextStyle(fontSize: 11 + fd, color: Colors.grey[700])),
            ],
          ),
          const SizedBox(height: 4),
          TextField(
            controller: _memoController,
            maxLines: 2,
            style: TextStyle(fontSize: 13 + fd),
            decoration: InputDecoration(
              hintText: '측점 메모 입력...',
              hintStyle: TextStyle(fontSize: 12 + fd, color: Colors.grey[300]),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              isDense: true,
            ),
            onChanged: (value) => _onMemoChanged(station, value),
          ),
        ],
      ),
    );
  }

  /// 메모 변경 시 debounce 저장
  void _onMemoChanged(StationData station, String memo) {
    _memoDebounce?.cancel();
    _memoDebounce = Timer(const Duration(milliseconds: 500), () async {
      if (widget.projectId == null) return;
      final updated = station.copyWith(memo: memo);
      await DatabaseService.instance.upsertStation(widget.projectId!, updated);
    });
  }

  /// 보기 형식 2: 카드 (컬럼별 행 표시)
  Widget _buildCardView() {
    final stations = _displayStations;

    return ListView.builder(
      itemCount: stations.length,
      itemBuilder: (context, index) {
        final station = stations[index];
        final isPlusChain = station.no.contains('+');
        final isSelected = _selectedStationNo == station.no;

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: isPlusChain ? Colors.indigo[50] : null,
          shape: RoundedRectangleBorder(
            side: isSelected
                ? const BorderSide(color: Colors.blue, width: 2)
                : BorderSide(color: Colors.grey[200]!),
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            onTap: () => setState(() => _selectedStationNo = station.no),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 측점 헤더
                  Row(
                    children: [
                      isPlusChain
                          ? Icon(Icons.auto_awesome, size: 18, color: Colors.indigo[300])
                          : const Icon(Icons.place, size: 18, color: Colors.blue),
                      const SizedBox(width: 8),
                      Text(
                        _getDisplayName(station, index),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isPlusChain ? Colors.indigo[700] : null,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 12),
                  // 컬럼 값들 (2열 그리드)
                  Wrap(
                    spacing: 0,
                    runSpacing: 4,
                    children: _visibleColumns.map((columnName) {
                      final fieldName = _availableColumns[columnName];
                      if (fieldName == null) return const SizedBox.shrink();
                      final value = _getFieldValue(station, fieldName);
                      final displayValue = value?.toStringAsFixed(widget.decimalPlaces) ?? '-';

                      return SizedBox(
                        width: MediaQuery.of(context).size.width / 2 - 24,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 80,
                                child: Text(
                                  columnName,
                                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  displayValue,
                                  style: TextStyle(
                                    fontSize: 13 + widget.fontSizeDelta.toDouble(),
                                    fontWeight: FontWeight.w500,
                                    color: isPlusChain ? Colors.indigo[600] : null,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 컬럼별 최적 너비 계산 (셀 텍스트 기준 + 20% 여유)
  Map<String, double> _calcColumnWidths(List<StationData> stations, List<String> columnNames) {
    final fontSize = 13.0 + widget.fontSizeDelta;
    final headerFontSize = 12.0 + widget.fontSizeDelta;
    final dp = widget.decimalPlaces;
    final widths = <String, double>{};

    for (final col in columnNames) {
      final fieldName = _availableColumns[col];
      // 헤더 텍스트 너비
      double maxWidth = col.length * headerFontSize * 0.65;

      // 셀 데이터 너비
      if (fieldName != null) {
        for (final s in stations) {
          final value = _getFieldValue(s, fieldName);
          if (value != null) {
            final text = value.toStringAsFixed(dp);
            final textWidth = text.length * fontSize * 0.6;
            if (textWidth > maxWidth) maxWidth = textWidth;
          }
        }
      }

      // 20% 여유 + 양쪽 패딩 16
      widths[col] = (maxWidth * 1.2) + 16;
      // 최소 너비 보장
      if (widths[col]! < 70) widths[col] = 70;
    }
    return widths;
  }

  /// 보기 형식 3: 테이블 (측점 열 고정, 나머지 가로 스크롤, 모든 컬럼 표시)
  Widget _buildTableView() {
    final stations = _displayStations;
    final allColumnNames = _availableColumns.keys.toList();
    final colWidths = _calcColumnWidths(stations, allColumnNames);
    final scrollableWidth = colWidths.values.fold(0.0, (sum, w) => sum + w);
    final rowHeight = 36.0 + widget.fontSizeDelta * 2.0;

    return Row(
      children: [
        // 고정 측점 열
        SizedBox(
          width: 100,
          child: Column(
            children: [
              // 헤더
              Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: Colors.grey[200],
                  border: Border(right: BorderSide(color: Colors.grey[400]!, width: 1.5)),
                ),
                child: const Text(
                  '측점',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
              // 데이터
              Expanded(
                child: ListView.builder(
                  controller: _tableFixedColScrollCtrl,
                  itemCount: stations.length,
                  itemBuilder: (context, index) {
                    final station = stations[index];
                    final isPlusChain = station.no.contains('+');
                    final isSelected = _selectedStationNo == station.no;
                    final isEven = index.isEven;

                    return GestureDetector(
                      onTap: () => setState(() => _selectedStationNo = station.no),
                      child: Container(
                        height: rowHeight,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? Colors.blue[50]
                              : isPlusChain
                                  ? Colors.indigo[50]
                                  : isEven ? Colors.white : Colors.grey[50],
                          border: const Border(right: BorderSide(color: Colors.grey, width: 1.5)),
                        ),
                        child: Text(
                          station.no,
                          style: TextStyle(
                            fontSize: 13 + widget.fontSizeDelta.toDouble(),
                            fontWeight: isPlusChain ? FontWeight.normal : FontWeight.bold,
                            color: isPlusChain ? Colors.indigo[600] : null,
                            fontStyle: isPlusChain ? FontStyle.italic : null,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // 스크롤 가능한 데이터 열
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            controller: _tableHeaderScrollCtrl,
            child: SizedBox(
              width: scrollableWidth,
              child: Column(
                children: [
                  // 헤더
                  Container(
                    height: 38,
                    color: Colors.grey[200],
                    child: Row(
                      children: allColumnNames.map((col) => Container(
                        width: colWidths[col]!,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.centerRight,
                        decoration: BoxDecoration(
                          border: Border(right: BorderSide(color: Colors.grey[300]!)),
                        ),
                        child: Text(
                          col,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      )).toList(),
                    ),
                  ),
                  // 데이터
                  Expanded(
                    child: ListView.builder(
                      controller: _tableDataScrollCtrl,
                      itemCount: stations.length,
                      itemBuilder: (context, index) {
                        final station = stations[index];
                        final isPlusChain = station.no.contains('+');
                        final isSelected = _selectedStationNo == station.no;
                        final isEven = index.isEven;

                        return GestureDetector(
                          onTap: () => setState(() => _selectedStationNo = station.no),
                          child: Container(
                            height: rowHeight,
                            color: isSelected
                                ? Colors.blue[50]
                                : isPlusChain
                                    ? Colors.indigo[50]
                                    : isEven ? Colors.white : Colors.grey[50],
                            child: Row(
                              children: allColumnNames.map((col) {
                                final fieldName = _availableColumns[col];
                                final value = fieldName != null ? _getFieldValue(station, fieldName) : null;
                                return Container(
                                  width: colWidths[col]!,
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  alignment: Alignment.centerRight,
                                  decoration: BoxDecoration(
                                    border: Border(right: BorderSide(color: Colors.grey[200]!)),
                                  ),
                                  child: Text(
                                    value?.toStringAsFixed(widget.decimalPlaces) ?? '-',
                                    style: TextStyle(
                                      fontSize: 13 + widget.fontSizeDelta.toDouble(),
                                      color: isPlusChain ? Colors.indigo[400] : null,
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 표시명 (station.no에 이미 기본측점+플러스체인 형태로 저장됨)
  String _getDisplayName(StationData station, int displayIndex) {
    return station.no;
  }

  /// StationData에서 필드 값 가져오기
  double? _getFieldValue(StationData station, String fieldName) {
    switch (fieldName) {
      case 'intervalDistance':
        return station.intervalDistance;
      case 'distance':
        return station.distance;
      case 'gh':
        return station.gh;
      case 'deepestBedLevel':
        return station.deepestBedLevel;
      case 'ip':
        return station.ip;
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
      case 'x':
        return station.x;
      case 'y':
        return station.y;
      default:
        return null;
    }
  }

  void _showColumnSelector() {
    final tempSelected = List<String>.from(_visibleColumns);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final unselected = _availableColumns.keys
              .where((c) => !tempSelected.contains(c))
              .toList();

          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                      const Icon(Icons.view_column, size: 20, color: Colors.blue),
                      const SizedBox(width: 8),
                      const Text('표시 컬럼', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      Text(
                        '${tempSelected.length}/5',
                        style: TextStyle(
                          fontSize: 13,
                          color: tempSelected.length >= 5 ? Colors.red : Colors.grey[500],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // 선택된 컬럼 영역
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(minHeight: 52),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue[200]!),
                    ),
                    child: tempSelected.isEmpty
                        ? Center(
                            child: Text(
                              '아래에서 컬럼을 선택하세요',
                              style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                            ),
                          )
                        : Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: tempSelected.map((col) {
                              return InputChip(
                                label: Text(col),
                                labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                                backgroundColor: Colors.white,
                                selectedColor: Colors.blue[100],
                                selected: true,
                                showCheckmark: false,
                                deleteIcon: const Icon(Icons.close, size: 16),
                                onDeleted: tempSelected.length > 1
                                    ? () {
                                        setSheetState(() => tempSelected.remove(col));
                                      }
                                    : null,
                                onPressed: () {},
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              );
                            }).toList(),
                          ),
                  ),
                ),

                const SizedBox(height: 12),

                // 구분선
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Icon(Icons.add_circle_outline, size: 14, color: Colors.grey[400]),
                      const SizedBox(width: 4),
                      Text('선택 가능', style: TextStyle(fontSize: 11, color: Colors.grey[400])),
                      const SizedBox(width: 8),
                      Expanded(child: Divider(color: Colors.grey[200])),
                    ],
                  ),
                ),
                const SizedBox(height: 8),

                // 미선택 컬럼 영역
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: unselected.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '모든 컬럼이 선택되었습니다',
                            style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                          ),
                        )
                      : Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: unselected.map((col) {
                            final canAdd = tempSelected.length < 5;
                            return ActionChip(
                              avatar: Icon(
                                Icons.add,
                                size: 16,
                                color: canAdd ? Colors.blue : Colors.grey[300],
                              ),
                              label: Text(col),
                              labelStyle: TextStyle(
                                fontSize: 13,
                                color: canAdd ? null : Colors.grey[400],
                              ),
                              backgroundColor: Colors.grey[100],
                              onPressed: canAdd
                                  ? () {
                                      setSheetState(() => tempSelected.add(col));
                                    }
                                  : null,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            );
                          }).toList(),
                        ),
                ),

                const SizedBox(height: 16),

                // 버튼
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('취소'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: tempSelected.isEmpty
                              ? null
                              : () {
                                  setState(() => _visibleColumns = tempSelected);
                                  Navigator.pop(context);
                                },
                          child: const Text('적용'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _handleMenuAction(String action) async {
    switch (action) {
      case 'import_excel':
        await _importExcel();
        break;
      case 'export_excel':
        await _exportExcel();
        break;
      case 'interpolate':
        _runInterpolation();
        break;
      case 'delete_interpolated':
        _deleteInterpolated();
        break;
      case 'view_mode':
        _showViewModeSelector();
        break;
      case 'decimal_places':
        _showDecimalPlacesDialog();
        break;
      case 'station_range':
        _showStationRangeDialog();
        break;
      case 'font_size':
        _showFontSizeDialog();
        break;
    }
  }

  /// Excel 파일 가져오기
  Future<void> _importExcel() async {
    try {
      final filePath = await ExcelService.pickExcelFile();
      if (filePath == null) return;

      final stations = await ExcelService.loadFromExcel(filePath);

      // DB에 저장
      if (widget.projectId != null) {
        final db = DatabaseService.instance;
        await db.upsertStations(widget.projectId!, stations);
        final loaded = await db.getStations(widget.projectId!);
        widget.onStationsChanged?.call(loaded);
      } else {
        widget.onStationsChanged?.call(stations);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${stations.length}개의 측점을 불러왔습니다'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('파일 불러오기 실패: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Excel 파일 내보내기
  Future<void> _exportExcel() async {
    if (widget.stations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내보낼 데이터가 없습니다')),
      );
      return;
    }

    try {
      final fileName = '측점데이터_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      final result = await ExcelService.exportToExcel(widget.stations, fileName);

      if (result != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('파일 저장 완료: $result'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('파일 저장 실패: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// 보간 실행
  void _runInterpolation() {
    if (widget.stations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('측점 데이터가 없습니다')),
      );
      return;
    }

    // 보간 간격 선택 다이얼로그
    showDialog(
      context: context,
      builder: (context) {
        int selectedInterval = 5;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('보간 실행'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('플러스 체인 간격을 선택하세요'),
                const SizedBox(height: 16),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 5, label: Text('5m')),
                    ButtonSegment(value: 10, label: Text('10m')),
                    ButtonSegment(value: 15, label: Text('15m')),
                    ButtonSegment(value: 20, label: Text('20m')),
                  ],
                  selected: {selectedInterval},
                  onSelectionChanged: (value) {
                    setDialogState(() => selectedInterval = value.first);
                  },
                ),
                const SizedBox(height: 12),
                Text(
                  '기본 측점 사이에 ${selectedInterval}m 간격으로 보간합니다',
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  _executeInterpolation(selectedInterval);
                },
                child: const Text('실행'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 보간 실행
  Future<void> _executeInterpolation(int interval) async {
    // 원본 데이터 (기본측점 + 원본 플러스체인) - 보간이 아닌 것만
    final originalStations = widget.stations.where((s) => !s.isInterpolated).toList();

    // 보간 실행 (원본 플러스체인을 앵커로 활용)
    final result = InterpolationService.interpolateAllStations(
      allStations: originalStations,
      interval: interval,
    );

    // DB에 저장
    if (widget.projectId != null) {
      final db = DatabaseService.instance;
      // 기존 보간 데이터 삭제
      await db.deleteInterpolatedStations(widget.projectId!);
      // 새 보간 데이터 저장
      final interpolatedOnly = result.where((s) => s.isInterpolated).toList();
      await db.upsertStations(widget.projectId!, interpolatedOnly);
      // 전체 데이터 다시 로드
      final loaded = await db.getStations(widget.projectId!);
      widget.onStationsChanged?.call(loaded);
    } else {
      widget.onStationsChanged?.call(result);
    }

    if (mounted) {
      final interpCount = result.where((s) => s.isInterpolated).length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('보간 완료: $interpCount개 측점 생성'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  /// 보간 데이터 삭제
  void _deleteInterpolated() {
    final interpCount = widget.stations.where((s) => s.isInterpolated).length;
    if (interpCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('삭제할 보간 데이터가 없습니다')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('보간 데이터 삭제'),
        content: Text('보간된 ${interpCount}개 측점을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);

              if (widget.projectId != null) {
                final db = DatabaseService.instance;
                await db.deleteInterpolatedStations(widget.projectId!);
                final loaded = await db.getStations(widget.projectId!);
                widget.onStationsChanged?.call(loaded);
              } else {
                final base = widget.stations.where((s) => s.isBaseStation).toList();
                widget.onStationsChanged?.call(base);
              }

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('보간 데이터 ${interpCount}개 삭제됨'),
                  ),
                );
              }
            },
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  /// 보기 형식 선택
  void _showViewModeSelector() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final modes = [
          {
            'key': 'compact',
            'icon': Icons.view_list,
            'label': '한줄 보기',
            'desc': '측점명과 데이터를 한 줄에 표시',
          },
          {
            'key': 'card',
            'icon': Icons.view_agenda,
            'label': '카드 보기',
            'desc': '각 컬럼을 행으로 나누어 표시',
          },
          {
            'key': 'table',
            'icon': Icons.table_chart,
            'label': '테이블 보기',
            'desc': '헤더 고정, 행/열 정렬 표시',
          },
        ];

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.dashboard, size: 20, color: Colors.blue),
                    SizedBox(width: 8),
                    Text('보기 형식', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 모드 목록
              ...modes.map((mode) {
                final isActive = _viewMode == mode['key'];
                return ListTile(
                  leading: Icon(
                    mode['icon'] as IconData,
                    color: isActive ? Colors.blue : Colors.grey[600],
                  ),
                  title: Text(
                    mode['label'] as String,
                    style: TextStyle(
                      fontWeight: isActive ? FontWeight.bold : null,
                      color: isActive ? Colors.blue : null,
                    ),
                  ),
                  subtitle: Text(
                    mode['desc'] as String,
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
                  trailing: isActive
                      ? const Icon(Icons.check_circle, color: Colors.blue, size: 20)
                      : null,
                  selected: isActive,
                  selectedTileColor: Colors.blue[50],
                  onTap: () {
                    Navigator.pop(context);
                    setState(() => _viewMode = mode['key'] as String);
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  /// 소수점 자리수 설정 다이얼로그
  void _showDecimalPlacesDialog() {
    int selected = widget.decimalPlaces;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('소수점 자리수'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('표시할 소수점 자리수를 선택하세요'),
              const SizedBox(height: 16),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('1')),
                  ButtonSegment(value: 2, label: Text('2')),
                  ButtonSegment(value: 3, label: Text('3')),
                  ButtonSegment(value: 4, label: Text('4')),
                ],
                selected: {selected},
                onSelectionChanged: (value) {
                  setDialogState(() => selected = value.first);
                },
              ),
              const SizedBox(height: 12),
              Text(
                '예: ${(123.456789).toStringAsFixed(selected)}',
                style: TextStyle(fontSize: 14, color: Colors.grey[600]),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                widget.onDecimalPlacesChanged?.call(selected);
              },
              child: const Text('확인'),
            ),
          ],
        ),
      ),
    );
  }

  /// 글꼴 크기 설정 다이얼로그
  void _showFontSizeDialog() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final options = [
          {'delta': -3, 'label': '-3'},
          {'delta': -2, 'label': '-2'},
          {'delta': -1, 'label': '-1'},
          {'delta': 0, 'label': '기본'},
          {'delta': 1, 'label': '+1'},
          {'delta': 2, 'label': '+2'},
          {'delta': 3, 'label': '+3'},
          {'delta': 4, 'label': '+4'},
          {'delta': 5, 'label': '+5'},
        ];

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
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
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.text_fields, size: 20, color: Colors.blue),
                    SizedBox(width: 8),
                    Text('글꼴 크기', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const Divider(height: 1),
              ...options.map((opt) {
                final delta = opt['delta'] as int;
                final isActive = widget.fontSizeDelta == delta;
                return ListTile(
                  leading: Text(
                    'A',
                    style: TextStyle(
                      fontSize: 16.0 + delta,
                      fontWeight: FontWeight.bold,
                      color: isActive ? Colors.blue : Colors.grey[600],
                    ),
                  ),
                  title: Text(
                    opt['label'] as String,
                    style: TextStyle(
                      fontWeight: isActive ? FontWeight.bold : null,
                      color: isActive ? Colors.blue : null,
                    ),
                  ),
                  trailing: isActive
                      ? const Icon(Icons.check_circle, color: Colors.blue, size: 20)
                      : null,
                  selected: isActive,
                  selectedTileColor: Colors.blue[50],
                  onTap: () {
                    Navigator.pop(context);
                    widget.onFontSizeDeltaChanged?.call(delta);
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  /// 측점 범위 설정 바텀시트
  void _showStationRangeDialog() {
    if (widget.stations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('측점 데이터가 없습니다')),
      );
      return;
    }

    // 기본측점 목록
    final baseStations = widget.stations.where((s) => s.isBaseStation).toList();
    if (baseStations.isEmpty) return;

    String? startNo = _rangeStartNo;
    String? endNo = _rangeEndNo;
    List<Map<String, dynamic>> savedRanges = [];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        // 저장된 범위 로드
        Future<void> loadRanges(StateSetter setSheetState) async {
          if (widget.projectId == null) return;
          final ranges = await DatabaseService.instance.getStationRanges(widget.projectId!);
          setSheetState(() => savedRanges = ranges);
        }

        return StatefulBuilder(
          builder: (context, setSheetState) {
            if (savedRanges.isEmpty && widget.projectId != null) {
              loadRanges(setSheetState);
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.65,
              minChildSize: 0.4,
              maxChildSize: 0.85,
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
                          const Icon(Icons.filter_list, size: 20, color: Colors.blue),
                          const SizedBox(width: 8),
                          const Text('측점 범위', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          const Spacer(),
                          // 현재 범위 표시
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: (_rangeStartNo != null || _rangeEndNo != null)
                                  ? Colors.blue[50] : Colors.grey[100],
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _rangeLabel,
                              style: TextStyle(
                                fontSize: 12,
                                color: (_rangeStartNo != null || _rangeEndNo != null)
                                    ? Colors.blue : Colors.grey[600],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 범위 선택 영역
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[50],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey[200]!),
                        ),
                        child: Column(
                          children: [
                            // 시작/끝 측점 행
                            Row(
                              children: [
                                // 시작 측점
                                Expanded(
                                  child: _buildRangeSelector(
                                    label: '시작',
                                    value: startNo,
                                    stations: baseStations,
                                    onChanged: (v) => setSheetState(() => startNo = v),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                  child: Icon(Icons.arrow_forward, size: 20, color: Colors.grey[400]),
                                ),
                                // 끝 측점
                                Expanded(
                                  child: _buildRangeSelector(
                                    label: '끝',
                                    value: endNo,
                                    stations: baseStations,
                                    onChanged: (v) => setSheetState(() => endNo = v),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            // 버튼 행
                            Row(
                              children: [
                                // 전체 보기
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () {
                                      Navigator.pop(context);
                                      setState(() {
                                        _rangeStartNo = null;
                                        _rangeEndNo = null;
                                      });
                                    },
                                    icon: const Icon(Icons.all_inclusive, size: 16),
                                    label: const Text('전체'),
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // 저장
                                if (startNo != null || endNo != null)
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () async {
                                        if (widget.projectId == null) return;
                                        final name = '${startNo ?? baseStations.first.no} ~ ${endNo ?? baseStations.last.no}';
                                        await DatabaseService.instance.saveStationRange(
                                          widget.projectId!, name,
                                          startNo ?? '', endNo ?? '',
                                        );
                                        await loadRanges(setSheetState);
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('범위 저장됨'), duration: Duration(seconds: 1)),
                                          );
                                        }
                                      },
                                      icon: const Icon(Icons.bookmark_add, size: 16),
                                      label: const Text('저장'),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(vertical: 10),
                                      ),
                                    ),
                                  ),
                                const SizedBox(width: 8),
                                // 적용
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: () {
                                      Navigator.pop(context);
                                      setState(() {
                                        _rangeStartNo = startNo;
                                        _rangeEndNo = endNo;
                                      });
                                    },
                                    icon: const Icon(Icons.check, size: 16),
                                    label: const Text('적용'),
                                    style: FilledButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 10),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 저장된 범위 목록
                    if (savedRanges.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Icon(Icons.bookmarks, size: 16, color: Colors.grey[500]),
                            const SizedBox(width: 4),
                            Text(
                              '저장된 범위',
                              style: TextStyle(fontSize: 12, color: Colors.grey[500], fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Divider(color: Colors.grey[300])),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],

                    // 저장된 범위 리스트
                    Expanded(
                      child: savedRanges.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  '범위를 설정하고 저장하면\n여기에 표시됩니다',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: Colors.grey[400], fontSize: 13),
                                ),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              itemCount: savedRanges.length,
                              itemBuilder: (context, index) {
                                final range = savedRanges[index];
                                final rName = range['name'] as String;
                                final rStart = range['start_station_no'] as String;
                                final rEnd = range['end_station_no'] as String;
                                final isActive = _rangeStartNo == (rStart.isEmpty ? null : rStart) &&
                                    _rangeEndNo == (rEnd.isEmpty ? null : rEnd);

                                return Card(
                                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  color: isActive ? Colors.blue[50] : null,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    side: isActive
                                        ? const BorderSide(color: Colors.blue, width: 1.5)
                                        : BorderSide(color: Colors.grey[200]!),
                                  ),
                                  child: ListTile(
                                    dense: true,
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                                    leading: Icon(
                                      isActive ? Icons.bookmark : Icons.bookmark_outline,
                                      color: isActive ? Colors.blue : Colors.grey[400],
                                      size: 20,
                                    ),
                                    title: Text(
                                      rName,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: isActive ? FontWeight.bold : null,
                                      ),
                                    ),
                                    trailing: IconButton(
                                      icon: Icon(Icons.close, size: 18, color: Colors.grey[400]),
                                      onPressed: () async {
                                        await DatabaseService.instance.deleteStationRange(range['id'] as int);
                                        await loadRanges(setSheetState);
                                      },
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onTap: () {
                                      Navigator.pop(context);
                                      setState(() {
                                        _rangeStartNo = rStart.isEmpty ? null : rStart;
                                        _rangeEndNo = rEnd.isEmpty ? null : rEnd;
                                      });
                                    },
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
      },
    );
  }

  /// 범위 선택 위젯 (시작/끝 각각)
  Widget _buildRangeSelector({
    required String label,
    required String? value,
    required List<StationData> stations,
    required ValueChanged<String?> onChanged,
  }) {
    return InkWell(
      onTap: () {
        _showStationPicker(
          title: '$label 측점',
          stations: stations,
          selectedNo: value,
          onSelected: onChanged,
        );
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: value != null ? Colors.blue[200]! : Colors.grey[300]!),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                  const SizedBox(height: 2),
                  Text(
                    value ?? (label == '시작' ? '처음부터' : '끝까지'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: value != null ? FontWeight.bold : null,
                      color: value != null ? Colors.blue[700] : Colors.grey[400],
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.unfold_more, size: 16, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }

  /// 측점 선택 팝업
  void _showStationPicker({
    required String title,
    required List<StationData> stations,
    required String? selectedNo,
    required ValueChanged<String?> onSelected,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16)),
        contentPadding: const EdgeInsets.only(top: 12),
        content: SizedBox(
          width: double.maxFinite,
          height: 350,
          child: ListView(
            children: [
              // 해제 옵션
              ListTile(
                dense: true,
                leading: const Icon(Icons.clear, size: 18),
                title: Text(
                  title.contains('시작') ? '처음부터' : '끝까지',
                  style: TextStyle(
                    color: selectedNo == null ? Colors.blue : null,
                    fontWeight: selectedNo == null ? FontWeight.bold : null,
                  ),
                ),
                selected: selectedNo == null,
                selectedTileColor: Colors.blue[50],
                onTap: () {
                  Navigator.pop(context);
                  onSelected(null);
                },
              ),
              const Divider(height: 1),
              // 측점 목록
              ...stations.map((s) {
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
              }),
            ],
          ),
        ),
      ),
    );
  }
}
