import 'package:flutter/material.dart';
import '../models/station_data.dart';
import '../services/csv_service.dart';
import '../services/database_service.dart';
import 'data_table_screen.dart';
import 'dxf_viewer_screen.dart';
import 'level_panel_screen.dart';
import 'projects_screen.dart';

/// 메인 화면 - 탭 기반 네비게이션
/// 작은 화면에 최적화된 레이아웃
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;
  List<StationData> _stations = [];
  int? _projectId;
  String _projectName = '';
  int _decimalPlaces = 2;
  int _fontSizeDelta = 0;

  @override
  void initState() {
    super.initState();
    _loadStations();
  }

  Future<void> _loadStations() async {
    try {
      final db = DatabaseService.instance;
      debugPrint('[MainScreen] 데이터 로드 시작...');

      // 1) 데이터가 있는 활성 프로젝트 찾기
      final activeProject = await db.getActiveProject();
      if (activeProject != null) {
        final projectId = activeProject['id'] as int;
        final name = activeProject['name'] as String;
        debugPrint('[MainScreen] 활성 프로젝트 발견: $name (id=$projectId)');
        final loaded = await db.getStations(projectId);
        debugPrint('[MainScreen] 측점 수: ${loaded.length}');
        if (loaded.isNotEmpty) {
          setState(() {
            _stations = loaded;
            _projectId = projectId;
            _projectName = name;
          });
          return;
        }
      } else {
        debugPrint('[MainScreen] 활성 프로젝트 없음');
      }

      // 2) 데이터가 있는 아무 프로젝트라도 찾기
      final allProjects = await db.getAllProjects();
      debugPrint('[MainScreen] 전체 프로젝트 수: ${allProjects.length}');
      for (final proj in allProjects) {
        final pid = proj['id'] as int;
        final stations = await db.getStations(pid);
        if (stations.isNotEmpty) {
          await db.setActiveProject(pid);
          setState(() {
            _stations = stations;
            _projectId = pid;
            _projectName = proj['name'] as String;
          });
          debugPrint('[MainScreen] 기존 프로젝트 로드: ${proj['name']} (${stations.length}개)');
          return;
        }
      }

      // 3) 데이터 있는 프로젝트가 하나도 없으면 샘플 CSV 로드
      debugPrint('[MainScreen] CSV에서 샘플 데이터 로드...');
      final stations = await CsvService.loadFromAssets(
        'assets/sample_data/stations.csv',
      );
      debugPrint('[MainScreen] CSV 파싱 완료: ${stations.length}개');
      final projectId = await db.createProject('거정소하천');
      await db.upsertStations(projectId, stations);
      final loaded = await db.getStations(projectId);
      debugPrint('[MainScreen] DB 저장 후 로드: ${loaded.length}개');
      setState(() {
        _stations = loaded;
        _projectId = projectId;
        _projectName = '거정소하천';
      });
    } catch (e, stackTrace) {
      debugPrint('[MainScreen] 측점 로드 실패: $e');
      debugPrint('[MainScreen] $stackTrace');
    }
  }

  void _onStationsChanged(List<StationData> stations) {
    setState(() => _stations = stations);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          DataTableScreen(
            stations: _stations,
            projectId: _projectId,
            projectName: _projectName,
            onStationsChanged: _onStationsChanged,
            decimalPlaces: _decimalPlaces,
            onDecimalPlacesChanged: (v) => setState(() => _decimalPlaces = v),
            fontSizeDelta: _fontSizeDelta,
            onFontSizeDeltaChanged: (v) => setState(() => _fontSizeDelta = v),
          ),
          LevelPanelScreen(
            stations: _stations,
            projectId: _projectId,
            onStationsChanged: _onStationsChanged,
            decimalPlaces: _decimalPlaces,
            fontSizeDelta: _fontSizeDelta,
          ),
          DxfViewerScreen(stations: _stations),
          const ProjectsScreen(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Theme.of(context).primaryColor,
        unselectedItemColor: Colors.grey,
        selectedFontSize: 12,
        unselectedFontSize: 11,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.table_chart),
            label: '데이터',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.calculate),
            label: '레벨',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.map),
            label: '도면',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.folder),
            label: '프로젝트',
          ),
        ],
      ),
    );
  }
}
