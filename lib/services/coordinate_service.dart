import 'package:proj4dart/proj4dart.dart' as proj4;

/// WGS84 (경위도) ↔ EPSG:5186 (TM 중부원점) 좌표 변환 서비스
class CoordinateService {
  static proj4.Projection? _epsg5186;

  static proj4.Projection get _tm {
    _epsg5186 ??= proj4.Projection.add(
      'EPSG:5186',
      '+proj=tmerc +lat_0=38 +lon_0=127 '
          '+k=1 +x_0=200000 +y_0=600000 '
          '+ellps=GRS80 +units=m +no_defs',
    );
    return _epsg5186!;
  }

  static final proj4.Projection _wgs84 = proj4.Projection.get('EPSG:4326')!;

  /// WGS84 경위도 → EPSG:5186 TM 좌표
  /// 반환: (x: Easting, y: Northing) — DXF의 X, Y에 대응
  static ({double x, double y}) wgs84ToTm(double latitude, double longitude) {
    final point = proj4.Point(x: longitude, y: latitude);
    final result = _wgs84.transform(_tm, point);
    return (x: result.x, y: result.y);
  }

  /// EPSG:5186 TM 좌표 → WGS84 경위도
  static ({double lat, double lon}) tmToWgs84(double x, double y) {
    final point = proj4.Point(x: x, y: y);
    final result = _tm.transform(_wgs84, point);
    return (lat: result.y, lon: result.x);
  }
}
