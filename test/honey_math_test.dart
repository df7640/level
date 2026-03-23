// ignore_for_file: avoid_print
import 'dart:math';

/// HONEY 패턴 수학 검증
/// acad.pat 원본:
///   0,    0,0,  0.1875, 0.108253175,  0.125, -0.25
///   120,  0,0,  0.1875, 0.108253175,  0.125, -0.25
///   60,   0,0,  0.1875, 0.108253175, -0.25,  0.125
///
/// DXF scale=5, patternAngle=0:
///   Line1: angle=0,   ox=0, oy=0, code45=0.9375,  code46=0.5413,  dashes=[0.625, -1.25]
///   Line2: angle=120, ox=0, oy=0, code45=-0.9375, code46=0.5413,  dashes=[0.625, -1.25]
///   Line3: angle=60,  ox=0, oy=0, code45=~0,      code46=1.0825,  dashes=[-1.25, 0.625]

void main() {
  print('=== HONEY 패턴 원본 (acad.pat) ===');
  // 원본값 (scale 1)
  final origDx = 0.1875;
  final origDy = 0.108253175;
  print('원본 offset: dx=$origDx, dy=$origDy');
  print('');

  // scale=5 적용
  final scaledDx = origDx * 5;
  final scaledDy = origDy * 5;
  print('scale=5 적용: dx=$scaledDx, dy=$scaledDy');
  print('');

  // 각 라인의 각도별 offset 벡터 회전
  for (final lineAngle in [0.0, 120.0, 60.0]) {
    final rad = lineAngle * pi / 180;
    final cosA = cos(rad);
    final sinA = sin(rad);

    // offset 벡터를 lineAngle로 회전
    final rotX = scaledDx * cosA - scaledDy * sinA;
    final rotY = scaledDx * sinA + scaledDy * cosA;

    print('Line angle=$lineAngle°:');
    print('  회전된 offset: (${rotX.toStringAsFixed(6)}, ${rotY.toStringAsFixed(6)})');

    // 라인 방향/수직 분해
    final dirX = cos(rad);
    final dirY = sin(rad);
    final perpX = -sinA;
    final perpY = cosA;

    final stagger = rotX * dirX + rotY * dirY;
    final spacing = rotX * perpX + rotY * perpY;

    print('  stagger (dir 투영): ${stagger.toStringAsFixed(6)}');
    print('  spacing (perp 투영): ${spacing.toStringAsFixed(6)}');

    // 원본 값과 비교
    print('  원본 stagger: ${scaledDx.toStringAsFixed(6)}');
    print('  원본 spacing: ${scaledDy.toStringAsFixed(6)}');
    print('  spacing == 원본dy? ${(spacing - scaledDy).abs() < 1e-6}');
    print('  stagger == 원본dx? ${(stagger - scaledDx).abs() < 1e-6}');
    print('');
  }

  print('=== DXF에서 읽은 값 vs 회전 결과 비교 ===');
  final dxfValues = [
    {'angle': 0.0, 'code45': 0.9375, 'code46': 0.5412658773652741},
    {'angle': 120.0, 'code45': -0.9374999999999998, 'code46': 0.5412658773652744},
    {'angle': 60.0, 'code45': 0.0000000000000002, 'code46': 1.082531754730547},
  ];

  for (final d in dxfValues) {
    final lineAngle = d['angle']!;
    final code45 = d['code45']!;
    final code46 = d['code46']!;
    final rad = lineAngle * pi / 180;

    // DXF offset → 라인 좌표계 분해
    final dirX = cos(rad);
    final dirY = sin(rad);
    final perpX = -sin(rad);
    final perpY = cos(rad);

    final stagger = code45 * dirX + code46 * dirY;
    final spacing = code45 * perpX + code46 * perpY;

    print('DXF Line angle=$lineAngle°, offset=($code45, $code46):');
    print('  stagger=${stagger.toStringAsFixed(6)}, spacing=${spacing.toStringAsFixed(6)}');
  }
}
