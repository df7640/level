// ignore_for_file: avoid_print
import 'dart:math';

void main() {
  // 원본 HONEY
  final origDx = 0.1875;
  final origDy = 0.108253175;
  final scale = 2.0;
  final patternAngle = 71.7643063783546;
  final patRad = patternAngle * pi / 180;

  print('=== 바닥보호공: HONEY scale=$scale, patternAngle=$patternAngle ===');
  print('');

  // DXF에서 읽은 값
  final dxfLines = [
    {'angle': 71.7643063783546, 'ox': -244565.0964348053, 'oy': 267788.2597086854,
     'code45': -0.0882853169335918, 'code46': 0.4239170942695462,
     'dashes': [0.2499999999999999, -0.5]},
    {'angle': 191.7643063783545, 'ox': -244565.0964348053, 'oy': 267788.2597086854,
     'code45': -0.3229803142691137, 'code46': -0.2884158743804239,
     'dashes': [0.25, -0.5]},
  ];

  for (final d in dxfLines) {
    final lineAngle = d['angle'] as double;
    final code45 = d['code45'] as double;
    final code46 = d['code46'] as double;
    final rad = lineAngle * pi / 180;

    final dirX = cos(rad);
    final dirY = sin(rad);
    final perpX = -sin(rad);
    final perpY = cos(rad);

    final stagger = code45 * dirX + code46 * dirY;
    final spacing = code45 * perpX + code46 * perpY;

    print('Line angle=$lineAngle°:');
    print('  DXF offset: ($code45, $code46)');
    print('  stagger=${stagger.toStringAsFixed(6)}, spacing=${spacing.toStringAsFixed(6)}');

    // 원본과 비교
    final expectedSpacing = origDy * scale;
    final expectedStagger = origDx * scale;
    print('  expected: stagger=${expectedStagger.toStringAsFixed(6)}, spacing=${expectedSpacing.toStringAsFixed(6)}');
    print('  match? spacing=${(spacing - expectedSpacing).abs() < 0.001}, stagger=${(stagger - expectedStagger).abs() < 0.001}');
    print('');
  }

  // base point 검증
  print('=== Base Point 검증 ===');
  final oxDxf = -244565.0964348053;
  final oyDxf = 267788.2597086854;
  // base point는 원본 origin(0,0)을 patternAngle로 회전... 하지만 0,0이면 0,0이어야?
  // 아니다 — DXF에서 base point는 hatch의 origin(elevation point)에 따라 다를 수 있음
  print('base point: ($oxDxf, $oyDxf) — 이 값은 해치 원점 기준');

  // nMin/nMax 계산 검증 (bbox 5x6 기준)
  print('');
  print('=== n 범위 검증 (bbox 5x6) ===');
  final bboxCX = 217181.0;
  final bboxCY = 401049.0;

  for (final d in dxfLines) {
    final lineAngle = d['angle'] as double;
    final code45 = d['code45'] as double;
    final code46 = d['code46'] as double;
    final ox = d['ox'] as double;
    final oy = d['oy'] as double;
    final rad = lineAngle * pi / 180;

    final dirX = cos(rad);
    final dirY = sin(rad);
    final perpX = -sin(rad);
    final perpY = cos(rad);

    final spacing = code45 * perpX + code46 * perpY;
    final absSpacing = spacing.abs();

    // bbox 중심 기준
    final halfW = 2.5;
    final halfH = 3.0;
    final corners = [
      (-halfW) * perpX + (-halfH) * perpY,
      ( halfW) * perpX + (-halfH) * perpY,
      (-halfW) * perpX + ( halfH) * perpY,
      ( halfW) * perpX + ( halfH) * perpY,
    ];
    final minPerp = corners.reduce((a, b) => a < b ? a : b);
    final maxPerp = corners.reduce((a, b) => a > b ? a : b);

    final nMinLocal = (minPerp / spacing).floor() - 1;
    final nMaxLocal = (maxPerp / spacing).ceil() + 1;

    // origin offset
    final relCX = bboxCX - ox;
    final relCY = bboxCY - oy;
    final originPerpDist = relCX * perpX + relCY * perpY;
    final originN = (originPerpDist / spacing).round();

    print('Line angle=$lineAngle°: spacing=$spacing');
    print('  nMin=$nMinLocal, nMax=$nMaxLocal, count=${nMaxLocal-nMinLocal}');
    print('  originN=$originN (originPerpDist=$originPerpDist)');
    print('  origN range: ${nMinLocal + originN} ~ ${nMaxLocal + originN}');
    print('');
  }
}
