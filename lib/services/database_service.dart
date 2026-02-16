import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/station_data.dart';

/// SQLite 데이터베이스 서비스
/// 측점 데이터, 프로젝트 설정, DXF 정보 관리
class DatabaseService {
  // 싱글톤 인스턴스
  static final DatabaseService instance = DatabaseService._internal();

  factory DatabaseService() {
    return instance;
  }

  DatabaseService._internal();

  static Database? _database;
  static const String _databaseName = 'longitudinal_viewer.db';
  static const int _databaseVersion = 1;

  // 테이블 이름
  static const String tableProjects = 'projects';
  static const String tableStations = 'stations';
  static const String tableDxfFiles = 'dxf_files';

  /// 데이터베이스 인스턴스 가져오기 (싱글톤)
  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  /// 데이터베이스 초기화
  Future<Database> _initDatabase() async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, _databaseName);

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 테이블 생성
  Future<void> _onCreate(Database db, int version) async {
    // 프로젝트 테이블
    await db.execute('''
      CREATE TABLE $tableProjects (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        file_path TEXT,
        created_at TEXT NOT NULL,
        last_modified TEXT NOT NULL,
        settings TEXT,
        is_active INTEGER DEFAULT 0
      )
    ''');

    // 측점 테이블
    await db.execute('''
      CREATE TABLE $tableStations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER NOT NULL,
        no TEXT NOT NULL,
        distance REAL,
        gh REAL,
        ip REAL,
        gh_d REAL,
        gh1 REAL,
        gh2 REAL,
        gh3 REAL,
        gh4 REAL,
        gh5 REAL,
        x REAL,
        y REAL,
        actual_reading REAL,
        target_reading REAL,
        cut_fill REAL,
        cut_fill_status TEXT,
        is_interpolated INTEGER DEFAULT 0,
        last_modified TEXT,
        FOREIGN KEY (project_id) REFERENCES $tableProjects (id) ON DELETE CASCADE,
        UNIQUE(project_id, no)
      )
    ''');

    // DXF 파일 테이블
    await db.execute('''
      CREATE TABLE $tableDxfFiles (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER NOT NULL,
        file_path TEXT NOT NULL,
        file_name TEXT NOT NULL,
        loaded_at TEXT NOT NULL,
        layer_info TEXT,
        FOREIGN KEY (project_id) REFERENCES $tableProjects (id) ON DELETE CASCADE
      )
    ''');

    // 인덱스 생성 (성능 최적화)
    await db.execute(
        'CREATE INDEX idx_stations_project_id ON $tableStations(project_id)');
    await db.execute('CREATE INDEX idx_stations_no ON $tableStations(no)');
    await db
        .execute('CREATE INDEX idx_stations_distance ON $tableStations(distance)');
  }

  /// 데이터베이스 업그레이드
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 버전별 마이그레이션 로직
    if (oldVersion < 2) {
      // 예: 새로운 컬럼 추가
      // await db.execute('ALTER TABLE $tableStations ADD COLUMN new_column TEXT');
    }
  }

  // ==================== 프로젝트 관리 ====================

  /// 새 프로젝트 생성
  Future<int> createProject(String name, {String? filePath}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();

    // 기존 활성 프로젝트 비활성화
    await db.update(
      tableProjects,
      {'is_active': 0},
      where: 'is_active = ?',
      whereArgs: [1],
    );

    // 새 프로젝트 생성
    return await db.insert(tableProjects, {
      'name': name,
      'file_path': filePath,
      'created_at': now,
      'last_modified': now,
      'is_active': 1,
    });
  }

  /// 모든 프로젝트 목록 가져오기
  Future<List<Map<String, dynamic>>> getAllProjects() async {
    final db = await database;
    return await db.query(
      tableProjects,
      orderBy: 'last_modified DESC',
    );
  }

  /// 활성 프로젝트 가져오기
  Future<Map<String, dynamic>?> getActiveProject() async {
    final db = await database;
    final results = await db.query(
      tableProjects,
      where: 'is_active = ?',
      whereArgs: [1],
      limit: 1,
    );
    return results.isNotEmpty ? results.first : null;
  }

  /// 프로젝트 활성화
  Future<void> setActiveProject(int projectId) async {
    final db = await database;
    await db.transaction((txn) async {
      // 모든 프로젝트 비활성화
      await txn.update(tableProjects, {'is_active': 0});
      // 선택된 프로젝트 활성화
      await txn.update(
        tableProjects,
        {'is_active': 1, 'last_modified': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [projectId],
      );
    });
  }

  /// 프로젝트 삭제
  Future<void> deleteProject(int projectId) async {
    final db = await database;
    await db.delete(
      tableProjects,
      where: 'id = ?',
      whereArgs: [projectId],
    );
    // CASCADE로 관련 측점들도 자동 삭제됨
  }

  // ==================== 측점 데이터 관리 ====================

  /// 측점 추가/업데이트
  Future<int> upsertStation(int projectId, StationData station) async {
    final db = await database;

    final data = {
      'project_id': projectId,
      'no': station.no,
      'distance': station.distance,
      'gh': station.gh,
      'ip': station.ip,
      'gh_d': station.ghD,
      'gh1': station.gh1,
      'gh2': station.gh2,
      'gh3': station.gh3,
      'gh4': station.gh4,
      'gh5': station.gh5,
      'x': station.x,
      'y': station.y,
      'actual_reading': station.actualReading,
      'target_reading': station.targetReading,
      'cut_fill': station.cutFill,
      'cut_fill_status': station.cutFillStatus,
      'is_interpolated': station.isInterpolated ? 1 : 0,
      'last_modified': DateTime.now().toIso8601String(),
    };

    return await db.insert(
      tableStations,
      data,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 여러 측점 일괄 추가/업데이트
  Future<void> upsertStations(int projectId, List<StationData> stations) async {
    final db = await database;
    final batch = db.batch();

    for (final station in stations) {
      final data = {
        'project_id': projectId,
        'no': station.no,
        'distance': station.distance,
        'gh': station.gh,
        'ip': station.ip,
        'gh_d': station.ghD,
        'gh1': station.gh1,
        'gh2': station.gh2,
        'gh3': station.gh3,
        'gh4': station.gh4,
        'gh5': station.gh5,
        'x': station.x,
        'y': station.y,
        'actual_reading': station.actualReading,
        'target_reading': station.targetReading,
        'cut_fill': station.cutFill,
        'cut_fill_status': station.cutFillStatus,
        'is_interpolated': station.isInterpolated ? 1 : 0,
        'last_modified': DateTime.now().toIso8601String(),
      };

      batch.insert(
        tableStations,
        data,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    await batch.commit(noResult: true);
  }

  /// 프로젝트의 모든 측점 가져오기
  Future<List<StationData>> getStations(int projectId) async {
    final db = await database;
    final results = await db.query(
      tableStations,
      where: 'project_id = ?',
      whereArgs: [projectId],
      orderBy: 'distance ASC',
    );

    return results.map((row) => _stationFromDb(row)).toList();
  }

  /// 특정 측점 가져오기
  Future<StationData?> getStation(int projectId, String no) async {
    final db = await database;
    final results = await db.query(
      tableStations,
      where: 'project_id = ? AND no = ?',
      whereArgs: [projectId, no],
      limit: 1,
    );

    return results.isNotEmpty ? _stationFromDb(results.first) : null;
  }

  /// 기본 측점만 가져오기 (플러스 체인 제외)
  Future<List<StationData>> getBaseStations(int projectId) async {
    final db = await database;
    final results = await db.query(
      tableStations,
      where: 'project_id = ? AND no NOT LIKE ?',
      whereArgs: [projectId, '%+%'],
      orderBy: 'distance ASC',
    );

    return results.map((row) => _stationFromDb(row)).toList();
  }

  /// 보간된 측점 삭제
  Future<void> deleteInterpolatedStations(int projectId) async {
    final db = await database;
    await db.delete(
      tableStations,
      where: 'project_id = ? AND is_interpolated = ?',
      whereArgs: [projectId, 1],
    );
  }

  /// 측점 삭제
  Future<void> deleteStation(int projectId, String no) async {
    final db = await database;
    await db.delete(
      tableStations,
      where: 'project_id = ? AND no = ?',
      whereArgs: [projectId, no],
    );
  }

  /// 프로젝트의 모든 측점 삭제
  Future<void> deleteAllStations(int projectId) async {
    final db = await database;
    await db.delete(
      tableStations,
      where: 'project_id = ?',
      whereArgs: [projectId],
    );
  }

  // ==================== 헬퍼 메서드 ====================

  /// DB 행을 StationData로 변환
  StationData _stationFromDb(Map<String, dynamic> row) {
    return StationData(
      no: row['no'] as String,
      distance: row['distance'] as double?,
      gh: row['gh'] as double?,
      ip: row['ip'] as double?,
      ghD: row['gh_d'] as double?,
      gh1: row['gh1'] as double?,
      gh2: row['gh2'] as double?,
      gh3: row['gh3'] as double?,
      gh4: row['gh4'] as double?,
      gh5: row['gh5'] as double?,
      x: row['x'] as double?,
      y: row['y'] as double?,
      actualReading: row['actual_reading'] as double?,
      targetReading: row['target_reading'] as double?,
      cutFill: row['cut_fill'] as double?,
      cutFillStatus: row['cut_fill_status'] as String?,
      isInterpolated: (row['is_interpolated'] as int) == 1,
      lastModified: row['last_modified'] != null
          ? DateTime.parse(row['last_modified'] as String)
          : null,
    );
  }

  /// 데이터베이스 닫기
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
