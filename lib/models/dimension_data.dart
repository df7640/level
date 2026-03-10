import 'dart:ui';

/// 치수 유형
enum DimensionType {
  aligned,    // 정렬(사선) 치수
  horizontal, // 수평 치수
  vertical,   // 수직 치수
  angular,    // 각도 치수
}

/// 화살표 스타일
enum ArrowStyle {
  filled, // 채워진 화살촉
  open,   // 빈 화살촉
  tick,   // 빗금 (건축 스타일)
  dot,    // 점
  none,   // 없음
}

/// 치수 스타일 설정
class DimensionStyle {
  final Color color;
  final double fontSize;
  final int decimalPlaces;
  final ArrowStyle arrowStyle;
  final double arrowSize;
  final double extensionGap;
  final double extensionOvershoot;

  const DimensionStyle({
    this.color = const Color(0xFF00FF00), // green
    this.fontSize = 16.0,
    this.decimalPlaces = 2,
    this.arrowStyle = ArrowStyle.filled,
    this.arrowSize = 12.0,
    this.extensionGap = 4.0,
    this.extensionOvershoot = 6.0,
  });

  DimensionStyle copyWith({
    Color? color,
    double? fontSize,
    int? decimalPlaces,
    ArrowStyle? arrowStyle,
    double? arrowSize,
    double? extensionGap,
    double? extensionOvershoot,
  }) {
    return DimensionStyle(
      color: color ?? this.color,
      fontSize: fontSize ?? this.fontSize,
      decimalPlaces: decimalPlaces ?? this.decimalPlaces,
      arrowStyle: arrowStyle ?? this.arrowStyle,
      arrowSize: arrowSize ?? this.arrowSize,
      extensionGap: extensionGap ?? this.extensionGap,
      extensionOvershoot: extensionOvershoot ?? this.extensionOvershoot,
    );
  }
}

/// 확정된 치수 결과
class DimensionResult {
  final String id;
  final DimensionType type;
  final double x1, y1;
  final double x2, y2;
  final double? x3, y3; // 각도 치수 꼭짓점
  final double value;    // 거리(m) 또는 각도(degree)
  final double offsetX, offsetY;
  final DimensionStyle style;

  DimensionResult({
    required this.id,
    required this.type,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.x3,
    this.y3,
    required this.value,
    required this.offsetX,
    required this.offsetY,
    required this.style,
  });

  DimensionResult copyWith({
    String? id,
    DimensionType? type,
    double? x1,
    double? y1,
    double? x2,
    double? y2,
    double? x3,
    double? y3,
    double? value,
    double? offsetX,
    double? offsetY,
    DimensionStyle? style,
  }) {
    return DimensionResult(
      id: id ?? this.id,
      type: type ?? this.type,
      x1: x1 ?? this.x1,
      y1: y1 ?? this.y1,
      x2: x2 ?? this.x2,
      y2: y2 ?? this.y2,
      x3: x3 ?? this.x3,
      y3: y3 ?? this.y3,
      value: value ?? this.value,
      offsetX: offsetX ?? this.offsetX,
      offsetY: offsetY ?? this.offsetY,
      style: style ?? this.style,
    );
  }

  /// 고유 ID 생성
  static String generateId() =>
      DateTime.now().microsecondsSinceEpoch.toString();
}
