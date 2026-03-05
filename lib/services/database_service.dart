import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/station_data.dart';
import '../models/measurement_session.dart';

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
  static const int _databaseVersion = 9;

  // 테이블 이름
  static const String tableProjects = 'projects';
  static const String tableStations = 'stations';
  static const String tableDxfFiles = 'dxf_files';
  static const String tableMeasurementSessions = 'measurement_sessions';
  static const String tableMeasurementRecords = 'measurement_records';
  static const String tableStationRanges = 'station_ranges';
  static const String tableFoundationResults = 'foundation_results';

  /// 데이터베이스 인스턴스 가져오기 (싱글톤)
  Future<Database> get database async {
    if (_database != null) return _database!;
    final db = await _initDatabase();
    _database = db;
    return db;
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
        interval_distance REAL,
        deepest_bed_level REAL,
        planned_flood_level REAL,
        left_bank_height REAL,
        right_bank_height REAL,
        planned_bank_left REAL,
        planned_bank_right REAL,
        roadbed_left REAL,
        roadbed_right REAL,
        foundation_excavation REAL,
        offset_left REAL,
        offset_right REAL,
        lr TEXT,
        height REAL,
        single_count REAL,
        slope REAL,
        angle REAL,
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
        memo TEXT,
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

    // 측량 세션 테이블
    await db.execute('''
      CREATE TABLE $tableMeasurementSessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        ih REAL,
        plan_level_column TEXT,
        created_at TEXT NOT NULL,
        last_modified TEXT NOT NULL,
        FOREIGN KEY (project_id) REFERENCES $tableProjects (id) ON DELETE CASCADE
      )
    ''');

    // 측량 기록 테이블
    await db.execute('''
      CREATE TABLE $tableMeasurementRecords (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER NOT NULL,
        station_no TEXT NOT NULL,
        ih REAL,
        plan_level_column TEXT,
        target_reading REAL,
        actual_reading REAL,
        cut_fill REAL,
        cut_fill_status TEXT,
        measured_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES $tableMeasurementSessions (id) ON DELETE CASCADE,
        UNIQUE(session_id, station_no)
      )
    ''');

    // 저장된 측점 범위 테이블
    await db.execute('''
      CREATE TABLE $tableStationRanges (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        start_station_no TEXT NOT NULL,
        end_station_no TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (project_id) REFERENCES $tableProjects (id) ON DELETE CASCADE
      )
    ''');

    // 기초레벨 결과 테이블
    await db.execute('''
      CREATE TABLE $tableFoundationResults (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER NOT NULL,
        label TEXT NOT NULL,
        start_station_no TEXT NOT NULL,
        end_station_no TEXT NOT NULL,
        side TEXT NOT NULL,
        interpolation INTEGER NOT NULL,
        excavation_cm INTEGER NOT NULL,
        data TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (project_id) REFERENCES $tableProjects (id) ON DELETE CASCADE
      )
    ''');

    // 인덱스 생성 (성능 최적화)
    await db.execute(
        'CREATE INDEX idx_stations_project_id ON $tableStations(project_id)');
    await db.execute('CREATE INDEX idx_stations_no ON $tableStations(no)');
    await db
        .execute('CREATE INDEX idx_stations_distance ON $tableStations(distance)');
    await db.execute(
        'CREATE INDEX idx_msessions_project_id ON $tableMeasurementSessions(project_id)');
    await db.execute(
        'CREATE INDEX idx_mrecords_session_id ON $tableMeasurementRecords(session_id)');
    await db.execute(
        'CREATE INDEX idx_sranges_project_id ON $tableStationRanges(project_id)');
    await db.execute(
        'CREATE INDEX idx_foundation_project_id ON $tableFoundationResults(project_id)');
  }

  /// 데이터베이스 업그레이드
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      final newColumns = [
        'interval_distance REAL',
        'deepest_bed_level REAL',
        'planned_flood_level REAL',
        'left_bank_height REAL',
        'right_bank_height REAL',
        'planned_bank_left REAL',
        'planned_bank_right REAL',
        'roadbed_left REAL',
        'roadbed_right REAL',
      ];
      for (final col in newColumns) {
        try {
          await db.execute('ALTER TABLE $tableStations ADD COLUMN $col');
        } catch (_) {} // 이미 존재하면 무시
      }
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableMeasurementSessions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          project_id INTEGER NOT NULL,
          name TEXT NOT NULL,
          ih REAL,
          plan_level_column TEXT,
          created_at TEXT NOT NULL,
          last_modified TEXT NOT NULL,
          FOREIGN KEY (project_id) REFERENCES $tableProjects (id) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableMeasurementRecords (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          station_no TEXT NOT NULL,
          target_reading REAL,
          actual_reading REAL,
          cut_fill REAL,
          cut_fill_status TEXT,
          measured_at TEXT NOT NULL,
          FOREIGN KEY (session_id) REFERENCES $tableMeasurementSessions (id) ON DELETE CASCADE,
          UNIQUE(session_id, station_no)
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_msessions_project_id ON $tableMeasurementSessions(project_id)');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_mrecords_session_id ON $tableMeasurementRecords(session_id)');
    }
    if (oldVersion < 4) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableStationRanges (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          project_id INTEGER NOT NULL,
          name TEXT NOT NULL,
          start_station_no TEXT NOT NULL,
          end_station_no TEXT NOT NULL,
          created_at TEXT NOT NULL,
          FOREIGN KEY (project_id) REFERENCES $tableProjects (id) ON DELETE CASCADE
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_sranges_project_id ON $tableStationRanges(project_id)');
    }
    if (oldVersion < 5) {
      // measurement_records에 ih, plan_level_column 컬럼 추가
      try {
        await db.execute('ALTER TABLE $tableMeasurementRecords ADD COLUMN ih REAL');
      } catch (_) {}
      try {
        await db.execute('ALTER TABLE $tableMeasurementRecords ADD COLUMN plan_level_column TEXT');
      } catch (_) {}
    }

    if (oldVersion < 6) {
      try {
        await db.execute('ALTER TABLE $tableStations ADD COLUMN memo TEXT');
      } catch (_) {}
    }

    if (oldVersion < 7) {
      // 통합 CSV 데이터 반영을 위해 기존 측점 데이터 클리어
      // 앱 시작 시 CSV에서 새로 로드됨
      await db.delete(tableStations);
      await db.delete(tableProjects);
    }

    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $tableFoundationResults (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          project_id INTEGER NOT NULL,
          label TEXT NOT NULL,
          start_station_no TEXT NOT NULL,
          end_station_no TEXT NOT NULL,
          side TEXT NOT NULL,
          interpolation INTEGER NOT NULL,
          excavation_cm INTEGER NOT NULL,
          data TEXT NOT NULL,
          created_at TEXT NOT NULL,
          FOREIGN KEY (project_id) REFERENCES $tableProjects (id) ON DELETE CASCADE
        )
      ''');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_foundation_project_id ON $tableFoundationResults(project_id)');
    }

    if (oldVersion < 9) {
      // 기초터파기, 옵셋좌/우, LR, Height, 단수, 기울기, 각도 컬럼 추가
      final newCols = [
        'foundation_excavation REAL',
        'offset_left REAL',
        'offset_right REAL',
        'lr TEXT',
        'height REAL',
        'single_count REAL',
        'slope REAL',
        'angle REAL',
      ];
      for (final col in newCols) {
        try {
          await db.execute('ALTER TABLE $tableStations ADD COLUMN $col');
        } catch (_) {}
      }
      // 기존 데이터 초기화 → 앱 시작 시 CSV에서 새로 로드
      await db.delete(tableStations);
      await db.delete(tableProjects);
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

    final data = _stationToDb(projectId, station);

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
      final data = _stationToDb(projectId, station);

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

  /// StationData를 DB 행으로 변환
  Map<String, dynamic> _stationToDb(int projectId, StationData station) {
    return {
      'project_id': projectId,
      'no': station.no,
      'interval_distance': station.intervalDistance,
      'distance': station.distance,
      'gh': station.gh,
      'ip': station.ip,
      'deepest_bed_level': station.deepestBedLevel,
      'planned_flood_level': station.plannedFloodLevel,
      'left_bank_height': station.leftBankHeight,
      'right_bank_height': station.rightBankHeight,
      'planned_bank_left': station.plannedBankLeft,
      'planned_bank_right': station.plannedBankRight,
      'roadbed_left': station.roadbedLeft,
      'roadbed_right': station.roadbedRight,
      'foundation_excavation': station.foundationExcavation,
      'offset_left': station.offsetLeft,
      'offset_right': station.offsetRight,
      'lr': station.lr,
      'height': station.height,
      'single_count': station.singleCount,
      'slope': station.slope,
      'angle': station.angle,
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
      'memo': station.memo,
    };
  }

  /// DB 행을 StationData로 변환
  StationData _stationFromDb(Map<String, dynamic> row) {
    return StationData(
      no: row['no'] as String,
      intervalDistance: row['interval_distance'] as double?,
      distance: row['distance'] as double?,
      gh: row['gh'] as double?,
      ip: row['ip'] as double?,
      deepestBedLevel: row['deepest_bed_level'] as double?,
      plannedFloodLevel: row['planned_flood_level'] as double?,
      leftBankHeight: row['left_bank_height'] as double?,
      rightBankHeight: row['right_bank_height'] as double?,
      plannedBankLeft: row['planned_bank_left'] as double?,
      plannedBankRight: row['planned_bank_right'] as double?,
      roadbedLeft: row['roadbed_left'] as double?,
      roadbedRight: row['roadbed_right'] as double?,
      foundationExcavation: row['foundation_excavation'] as double?,
      offsetLeft: row['offset_left'] as double?,
      offsetRight: row['offset_right'] as double?,
      lr: row['lr'] as String?,
      height: row['height'] as double?,
      singleCount: row['single_count'] as double?,
      slope: row['slope'] as double?,
      angle: row['angle'] as double?,
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
      memo: row['memo'] as String?,
    );
  }

  // ==================== 측량 세션 관리 ====================

  /// 새 세션 생성
  Future<int> createSession(int projectId, String name, {double? ih, String? planLevelColumn}) async {
    final db = await database;
    final now = DateTime.now().toIso8601String();
    return await db.insert(tableMeasurementSessions, {
      'project_id': projectId,
      'name': name,
      'ih': ih,
      'plan_level_column': planLevelColumn,
      'created_at': now,
      'last_modified': now,
    });
  }

  /// 세션 업데이트 (이름, IH 등)
  Future<void> updateSession(int sessionId, {String? name, double? ih, String? planLevelColumn}) async {
    final db = await database;
    final data = <String, dynamic>{
      'last_modified': DateTime.now().toIso8601String(),
    };
    if (name != null) data['name'] = name;
    if (ih != null) data['ih'] = ih;
    if (planLevelColumn != null) data['plan_level_column'] = planLevelColumn;
    await db.update(tableMeasurementSessions, data,
        where: 'id = ?', whereArgs: [sessionId]);
  }

  /// 프로젝트의 세션 목록 가져오기
  Future<List<MeasurementSession>> getSessions(int projectId) async {
    final db = await database;
    final results = await db.rawQuery('''
      SELECT s.*, COUNT(r.id) as record_count
      FROM $tableMeasurementSessions s
      LEFT JOIN $tableMeasurementRecords r ON r.session_id = s.id
      WHERE s.project_id = ?
      GROUP BY s.id
      ORDER BY s.last_modified DESC
    ''', [projectId]);

    return results.map((row) => MeasurementSession(
      id: row['id'] as int,
      projectId: row['project_id'] as int,
      name: row['name'] as String,
      ih: row['ih'] as double?,
      planLevelColumn: row['plan_level_column'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String),
      lastModified: DateTime.parse(row['last_modified'] as String),
      recordCount: row['record_count'] as int,
    )).toList();
  }

  /// 세션 삭제
  Future<void> deleteSession(int sessionId) async {
    final db = await database;
    await db.delete(tableMeasurementSessions,
        where: 'id = ?', whereArgs: [sessionId]);
  }

  /// 측량 기록 저장 (upsert)
  Future<void> upsertRecord(int sessionId, MeasurementRecord record) async {
    final db = await database;
    await db.insert(tableMeasurementRecords, {
      'session_id': sessionId,
      'station_no': record.stationNo,
      'ih': record.ih,
      'plan_level_column': record.planLevelColumn,
      'target_reading': record.targetReading,
      'actual_reading': record.actualReading,
      'cut_fill': record.cutFill,
      'cut_fill_status': record.cutFillStatus,
      'measured_at': record.measuredAt.toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // 세션 last_modified 갱신
    await db.update(tableMeasurementSessions,
        {'last_modified': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [sessionId]);
  }

  /// 세션의 측량 기록 가져오기
  Future<List<MeasurementRecord>> getRecords(int sessionId) async {
    final db = await database;
    final results = await db.query(
      tableMeasurementRecords,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'measured_at ASC',
    );
    return results.map((row) => MeasurementRecord(
      id: row['id'] as int,
      sessionId: row['session_id'] as int,
      stationNo: row['station_no'] as String,
      ih: row['ih'] as double?,
      planLevelColumn: row['plan_level_column'] as String?,
      targetReading: row['target_reading'] as double?,
      actualReading: row['actual_reading'] as double?,
      cutFill: row['cut_fill'] as double?,
      cutFillStatus: row['cut_fill_status'] as String?,
      measuredAt: DateTime.parse(row['measured_at'] as String),
    )).toList();
  }

  // ==================== 측점 범위 관리 ====================

  /// 범위 저장
  Future<int> saveStationRange(int projectId, String name, String startNo, String endNo) async {
    final db = await database;
    return await db.insert(tableStationRanges, {
      'project_id': projectId,
      'name': name,
      'start_station_no': startNo,
      'end_station_no': endNo,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// 프로젝트의 저장된 범위 목록
  Future<List<Map<String, dynamic>>> getStationRanges(int projectId) async {
    final db = await database;
    return await db.query(
      tableStationRanges,
      where: 'project_id = ?',
      whereArgs: [projectId],
      orderBy: 'created_at DESC',
    );
  }

  /// 범위 삭제
  Future<void> deleteStationRange(int rangeId) async {
    final db = await database;
    await db.delete(tableStationRanges, where: 'id = ?', whereArgs: [rangeId]);
  }

  // ==================== 기초레벨 결과 관리 ====================

  /// 기초레벨 결과 저장
  Future<int> saveFoundationResult(int projectId, {
    required String label,
    required String startStationNo,
    required String endStationNo,
    required String side,
    required int interpolation,
    required int excavationCm,
    required String data,
  }) async {
    final db = await database;
    return await db.insert(tableFoundationResults, {
      'project_id': projectId,
      'label': label,
      'start_station_no': startStationNo,
      'end_station_no': endStationNo,
      'side': side,
      'interpolation': interpolation,
      'excavation_cm': excavationCm,
      'data': data,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// 프로젝트의 기초레벨 결과 목록
  Future<List<Map<String, dynamic>>> getFoundationResults(int projectId) async {
    final db = await database;
    return await db.query(
      tableFoundationResults,
      where: 'project_id = ?',
      whereArgs: [projectId],
      orderBy: 'created_at DESC',
    );
  }

  /// 기초레벨 결과 삭제
  Future<void> deleteFoundationResult(int id) async {
    final db = await database;
    await db.delete(tableFoundationResults, where: 'id = ?', whereArgs: [id]);
  }

  /// 데이터베이스 닫기
  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}
