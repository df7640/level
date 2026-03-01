/// NMEA 문장 파서
/// CHCNAV i80 등 GNSS 수신기에서 출력하는 NMEA-0183 데이터를 파싱

class NmeaPosition {
  final double latitude;
  final double longitude;
  final double? altitude;
  final int fixQuality; // 0=무효, 1=GPS, 2=DGPS, 4=RTK Fixed, 5=RTK Float
  final int satellites;
  final DateTime? utcTime;

  const NmeaPosition({
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.fixQuality = 0,
    this.satellites = 0,
    this.utcTime,
  });

  bool get hasValidFix => fixQuality > 0;
  bool get isRtkFixed => fixQuality == 4;
  bool get isRtkFloat => fixQuality == 5;

  String get fixLabel {
    switch (fixQuality) {
      case 1: return 'GPS';
      case 2: return 'DGPS';
      case 4: return 'RTK';
      case 5: return 'Float';
      default: return 'N/A';
    }
  }
}

class NmeaParser {
  NmeaPosition? _lastPosition;

  NmeaPosition? get lastPosition => _lastPosition;

  /// NMEA 문장 파싱. 유효한 위치 정보가 있으면 NmeaPosition 반환
  NmeaPosition? parse(String sentence) {
    if (!sentence.startsWith('\$')) return null;
    if (!_validateChecksum(sentence)) return null;

    // 체크섬 부분 제거
    final starIdx = sentence.indexOf('*');
    final body = starIdx > 0 ? sentence.substring(0, starIdx) : sentence;
    final parts = body.split(',');
    if (parts.isEmpty) return null;

    final type = parts[0];

    // GGA: 위치 Fix 데이터 (가장 중요)
    if (type == '\$GPGGA' || type == '\$GNGGA') {
      final pos = _parseGGA(parts);
      if (pos != null) _lastPosition = pos;
      return pos;
    }

    // RMC: 최소 항법 데이터
    if (type == '\$GPRMC' || type == '\$GNRMC') {
      final pos = _parseRMC(parts);
      if (pos != null) _lastPosition = pos;
      return pos;
    }

    return null;
  }

  /// GGA 문장 파싱
  /// $GPGGA,hhmmss.ss,llll.lll,a,yyyyy.yyy,a,x,xx,x.x,x.x,M,x.x,M,x.x,xxxx*hh
  NmeaPosition? _parseGGA(List<String> parts) {
    if (parts.length < 10) return null;

    final lat = _parseLatLon(parts[2], parts[3]);
    final lon = _parseLatLon(parts[4], parts[5]);
    if (lat == null || lon == null) return null;

    final fixQuality = int.tryParse(parts[6]) ?? 0;
    final satellites = int.tryParse(parts[7]) ?? 0;
    final altitude = double.tryParse(parts[9]);
    final utcTime = _parseTime(parts[1]);

    return NmeaPosition(
      latitude: lat,
      longitude: lon,
      altitude: altitude,
      fixQuality: fixQuality,
      satellites: satellites,
      utcTime: utcTime,
    );
  }

  /// RMC 문장 파싱
  /// $GPRMC,hhmmss.ss,A,llll.lll,a,yyyyy.yyy,a,x.x,x.x,ddmmyy,x.x,a*hh
  NmeaPosition? _parseRMC(List<String> parts) {
    if (parts.length < 7) return null;

    // A=Active, V=Void
    if (parts[2] != 'A') return null;

    final lat = _parseLatLon(parts[3], parts[4]);
    final lon = _parseLatLon(parts[5], parts[6]);
    if (lat == null || lon == null) return null;

    final utcTime = _parseTime(parts[1]);

    // RMC에는 fix quality가 없으므로 기존 값 유지하거나 1(GPS)로 설정
    final prevFix = _lastPosition?.fixQuality ?? 1;
    final prevSats = _lastPosition?.satellites ?? 0;
    final prevAlt = _lastPosition?.altitude;

    return NmeaPosition(
      latitude: lat,
      longitude: lon,
      altitude: prevAlt,
      fixQuality: prevFix,
      satellites: prevSats,
      utcTime: utcTime,
    );
  }

  /// DDMM.MMMM 형식을 십진도로 변환
  double? _parseLatLon(String value, String hemisphere) {
    if (value.isEmpty || hemisphere.isEmpty) return null;

    final v = double.tryParse(value);
    if (v == null) return null;

    final degrees = v ~/ 100;
    final minutes = v - (degrees * 100);
    double result = degrees + minutes / 60.0;

    if (hemisphere == 'S' || hemisphere == 'W') {
      result = -result;
    }

    return result;
  }

  /// hhmmss.ss 형식 UTC 시간 파싱
  DateTime? _parseTime(String value) {
    if (value.length < 6) return null;
    final h = int.tryParse(value.substring(0, 2));
    final m = int.tryParse(value.substring(2, 4));
    final s = int.tryParse(value.substring(4, 6));
    if (h == null || m == null || s == null) return null;

    final now = DateTime.now().toUtc();
    return DateTime.utc(now.year, now.month, now.day, h, m, s);
  }

  /// NMEA 체크섬 검증 ($와 * 사이 XOR)
  bool _validateChecksum(String sentence) {
    final starIdx = sentence.indexOf('*');
    if (starIdx < 0 || starIdx + 2 >= sentence.length) return true; // 체크섬 없으면 통과

    final data = sentence.substring(1, starIdx); // $ 제외
    final checksumStr = sentence.substring(starIdx + 1).trim();
    final expected = int.tryParse(checksumStr, radix: 16);
    if (expected == null) return false;

    int checksum = 0;
    for (int i = 0; i < data.length; i++) {
      checksum ^= data.codeUnitAt(i);
    }

    return checksum == expected;
  }
}
