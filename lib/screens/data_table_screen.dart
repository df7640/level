import 'package:flutter/material.dart';
import '../services/excel_service.dart';
import '../services/csv_service.dart';
import '../services/database_service.dart';
import '../models/station_data.dart';

/// 데이터 테이블 화면
/// 측점 데이터를 테이블 형태로 표시
/// 모바일에 최적화: 가로 스크롤 + 컬럼 선택
class DataTableScreen extends StatefulWidget {
  const DataTableScreen({super.key});

  @override
  State<DataTableScreen> createState() => _DataTableScreenState();
}

class _DataTableScreenState extends State<DataTableScreen> {
  // 선택된 측점
  String? _selectedStationNo;

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
    '제방고(L)': 'plannedBankLeft',
    '제방고(R)': 'plannedBankRight',
    '기초(L)': 'roadbedLeft',
    '기초(R)': 'roadbedRight',
    'X': 'x',
    'Y': 'y',
  };

  // 로딩 상태
  bool _isLoading = false;

  // 측점 데이터 (임시 - Provider로 이동 예정)
  List<StationData> _stations = [];

  @override
  void initState() {
    super.initState();
    _loadSampleData();
  }

  /// 샘플 CSV 데이터 로드 및 SQLite에 저장
  Future<void> _loadSampleData() async {
    setState(() => _isLoading = true);

    try {
      // 1. CSV에서 데이터 로드
      final stations = await CsvService.loadFromAssets(
        'assets/sample_data/stations.csv',
      );

      // 2. 데이터베이스 초기화
      final db = DatabaseService.instance;

      // 3. 기본 프로젝트 생성 (없으면)
      final projectId = await db.createProject('샘플 프로젝트');

      // 4. 측점 데이터를 데이터베이스에 저장
      for (final station in stations) {
        await db.upsertStation(projectId, station);
      }

      // 5. 데이터베이스에서 다시 읽기
      final loadedStations = await db.getStations(projectId);

      setState(() {
        _stations = loadedStations;
        _isLoading = false;
      });

      print('샘플 데이터 로드 완료: ${loadedStations.length}개 측점');
    } catch (e) {
      print('샘플 데이터 로드 실패: $e');
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('측점 데이터'),
        actions: [
          // 필터
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: _showFilterDialog,
            tooltip: '필터',
          ),
          // 컬럼 선택
          IconButton(
            icon: const Icon(Icons.view_column),
            onPressed: _showColumnSelector,
            tooltip: '컬럼 선택',
          ),
          // 정렬
          IconButton(
            icon: const Icon(Icons.sort),
            onPressed: _showSortOptions,
            tooltip: '정렬',
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
                value: 'clear',
                child: ListTile(
                  leading: Icon(Icons.clear_all),
                  title: Text('모두 지우기'),
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

          // 데이터 테이블
          Expanded(
            child: _buildDataTable(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addNewStation,
        tooltip: '측점 추가',
        child: const Icon(Icons.add),
      ),
    );
  }

  /// 빠른 통계 카드
  Widget _buildQuickStats() {
    return Container(
      padding: const EdgeInsets.all(12),
      color: Colors.grey[100],
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildStatItem('총 측점', '${_stations.length}', Icons.location_on),
          _buildStatItem('기본', '$_baseStationCount', Icons.place),
          _buildStatItem('보간', '$_interpolatedCount', Icons.auto_awesome),
          _buildStatItem('범위', _stations.isEmpty ? '-' : '${_stations.first.no} ~ ${_stations.last.no}', Icons.straighten),
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

  int get _baseStationCount =>
      _stations.where((s) => s.isBaseStation).length;

  int get _interpolatedCount =>
      _stations.where((s) => s.isInterpolated).length;

  /// 데이터 테이블 (가로 스크롤 가능)
  Widget _buildDataTable() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_stations.isEmpty) {
      return const Center(
        child: Text(
          '데이터 없음\n\nExcel 파일을 가져오거나\n측점을 추가하세요',
          textAlign: TextAlign.center,
        ),
      );
    }

    // 간단한 리스트 뷰로 표시
    return ListView.builder(
      itemCount: _stations.length,
      itemBuilder: (context, index) {
        final station = _stations[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ListTile(
            title: Text(
              station.no,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(_buildStationSubtitle(station)),
            trailing: station.x != null && station.y != null
                ? const Icon(Icons.location_on, color: Colors.blue)
                : null,
            onTap: () {
              setState(() => _selectedStationNo = station.no);
            },
            selected: _selectedStationNo == station.no,
          ),
        );
      },
    );
  }

  /// 선택된 컬럼에 따라 측점 정보 텍스트 생성
  String _buildStationSubtitle(StationData station) {
    final lines = <String>[];

    for (final columnName in _visibleColumns) {
      final fieldName = _availableColumns[columnName];
      if (fieldName == null) continue;

      final value = _getFieldValue(station, fieldName);
      final displayValue = value?.toStringAsFixed(3) ?? '-';
      lines.add('$columnName: $displayValue');
    }

    return lines.join('\n');
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
      case 'ghD':
        return station.ghD;
      case 'gh1':
        return station.gh1;
      case 'gh2':
        return station.gh2;
      case 'gh3':
        return station.gh3;
      case 'gh4':
        return station.gh4;
      case 'gh5':
        return station.gh5;
      case 'targetReading':
        return station.targetReading;
      case 'actualReading':
        return station.actualReading;
      case 'cutFill':
        return station.cutFill;
      default:
        return null;
    }
  }

  void _showFilterDialog() {
    // TODO: 필터 다이얼로그
  }

  void _showColumnSelector() {
    final tempSelected = List<String>.from(_visibleColumns);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('표시할 컬럼 선택'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '최소 1개, 최대 3개까지 선택 가능',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 16),
                ..._availableColumns.keys.map((columnName) {
                  final isSelected = tempSelected.contains(columnName);
                  final canSelect = tempSelected.length < 3 || isSelected;

                  return CheckboxListTile(
                    title: Text(columnName),
                    value: isSelected,
                    enabled: canSelect,
                    onChanged: (value) {
                      setDialogState(() {
                        if (value == true) {
                          if (tempSelected.length < 3) {
                            tempSelected.add(columnName);
                          }
                        } else {
                          if (tempSelected.length > 1) {
                            tempSelected.remove(columnName);
                          }
                        }
                      });
                    },
                  );
                }).toList(),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            ElevatedButton(
              onPressed: tempSelected.isEmpty
                  ? null
                  : () {
                      setState(() {
                        _visibleColumns = tempSelected;
                      });
                      Navigator.pop(context);
                    },
              child: const Text('확인'),
            ),
          ],
        ),
      ),
    );
  }

  void _showSortOptions() {
    // TODO: 정렬 옵션
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
      case 'clear':
        _clearAllData();
        break;
    }
  }

  /// Excel 파일 가져오기
  Future<void> _importExcel() async {
    setState(() => _isLoading = true);

    try {
      // 파일 선택
      final filePath = await ExcelService.pickExcelFile();
      if (filePath == null) {
        setState(() => _isLoading = false);
        return;
      }

      // Excel 파일 읽기
      final stations = await ExcelService.loadFromExcel(filePath);

      setState(() {
        _stations = stations;
        _isLoading = false;
      });

      // 성공 메시지
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${stations.length}개의 측점을 불러왔습니다'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);

      // 에러 메시지
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
    if (_stations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('내보낼 데이터가 없습니다')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final fileName = '측점데이터_${DateTime.now().millisecondsSinceEpoch}.xlsx';
      final result = await ExcelService.exportToExcel(_stations, fileName);

      setState(() => _isLoading = false);

      if (result != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('파일 저장 완료: $result'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _isLoading = false);

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

  void _runInterpolation() {
    // TODO: 보간 실행
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('보간 기능은 준비 중입니다')),
    );
  }

  void _clearAllData() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('데이터 삭제'),
        content: const Text('모든 데이터를 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _stations.clear());
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('모든 데이터를 삭제했습니다')),
              );
            },
            child: const Text('삭제'),
          ),
        ],
      ),
    );
  }

  void _addNewStation() {
    // TODO: 측점 추가
  }
}
