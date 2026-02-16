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

  @override
  void initState() {
    super.initState();
    _loadStations();
  }

  Future<void> _loadStations() async {
    try {
      final stations = await CsvService.loadFromAssets(
        'assets/sample_data/stations.csv',
      );
      final db = DatabaseService.instance;
      final projectId = await db.createProject('샘플 프로젝트');
      for (final station in stations) {
        await db.upsertStation(projectId, station);
      }
      final loaded = await db.getStations(projectId);
      setState(() => _stations = loaded);
    } catch (e) {
      print('[MainScreen] 측점 로드 실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: [
          const DataTableScreen(),
          const LevelPanelScreen(),
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
