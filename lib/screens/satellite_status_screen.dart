import 'dart:math';
import 'package:flutter/material.dart';
import '../services/bluetooth_gnss_service.dart';
import '../services/nmea_parser.dart';

/// 위성정보 화면 — 스카이뷰 + 위성 리스트 + 신호 막대
class SatelliteStatusScreen extends StatefulWidget {
  final BluetoothGnssService gnssService;

  const SatelliteStatusScreen({super.key, required this.gnssService});

  @override
  State<SatelliteStatusScreen> createState() => _SatelliteStatusScreenState();
}

class _SatelliteStatusScreenState extends State<SatelliteStatusScreen> {
  @override
  void initState() {
    super.initState();
    widget.gnssService.addListener(_onUpdate);
  }

  @override
  void dispose() {
    widget.gnssService.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Color _fixColor(int fixQuality) {
    switch (fixQuality) {
      case 4: return Colors.green;
      case 5: return Colors.yellow;
      case 1: case 2: return Colors.orange;
      default: return Colors.red;
    }
  }

  String _fixLabel(int fixQuality) {
    switch (fixQuality) {
      case 4: return 'RTK Fixed';
      case 5: return 'RTK Float';
      case 2: return 'DGPS';
      case 1: return 'GPS';
      default: return 'No Fix';
    }
  }

  static Color _systemColor(String system) {
    switch (system) {
      case 'GPS': return Colors.green;
      case 'GLO': return Colors.red;
      case 'GAL': return Colors.blue;
      case 'BDS': return Colors.orange;
      case 'QZSS': return Colors.purple;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sats = widget.gnssService.satelliteList;
    final fix = widget.gnssService.fixQuality;
    final satCount = widget.gnssService.satellites;
    final hdop = widget.gnssService.position?.hdop;
    final pdop = widget.gnssService.pdop;
    final vdop = widget.gnssService.vdop;

    // 시스템별 그룹
    final systemGroups = <String, List<SatelliteInfo>>{};
    for (final s in sats) {
      systemGroups.putIfAbsent(s.system, () => []).add(s);
    }
    final usedSats = sats.where((s) => s.hasSignal).length;

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('위성 정보'),
        backgroundColor: Colors.grey[850],
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _fixColor(fix).withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _fixColor(fix), width: 1),
              ),
              child: Text(
                _fixLabel(fix),
                style: TextStyle(color: _fixColor(fix), fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 상단 정보 바
          Container(
            color: Colors.grey[850],
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _infoChip('위성', '$usedSats / $satCount'),
                if (hdop != null) _infoChip('HDOP', hdop.toStringAsFixed(1)),
                if (pdop != null) _infoChip('PDOP', pdop.toStringAsFixed(1)),
                if (vdop != null) _infoChip('VDOP', vdop.toStringAsFixed(1)),
              ],
            ),
          ),
          // 시스템 범례
          Container(
            color: Colors.grey[850],
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final sys in ['GPS', 'GLO', 'GAL', 'BDS', 'QZSS'])
                  if (systemGroups.containsKey(sys))
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          Container(width: 10, height: 10, decoration: BoxDecoration(
                            color: _systemColor(sys), shape: BoxShape.circle,
                          )),
                          const SizedBox(width: 4),
                          Text('$sys(${systemGroups[sys]!.length})',
                            style: TextStyle(color: _systemColor(sys), fontSize: 11)),
                        ],
                      ),
                    ),
              ],
            ),
          ),
          // 스카이뷰
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final size = min(constraints.maxWidth, constraints.maxHeight);
                  return Center(
                    child: SizedBox(
                      width: size,
                      height: size,
                      child: CustomPaint(
                        painter: _SkyViewPainter(sats),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          // SNR 바 차트
          Expanded(
            flex: 2,
            child: _buildSnrBars(sats),
          ),
        ],
      ),
    );
  }

  Widget _infoChip(String label, String value) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        const SizedBox(height: 2),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildSnrBars(List<SatelliteInfo> sats) {
    if (sats.isEmpty) {
      return const Center(child: Text('위성 데이터 수신 대기중...', style: TextStyle(color: Colors.white38)));
    }

    // SNR 순으로 정렬 (높은 것부터)
    final sorted = List<SatelliteInfo>.from(sats)
      ..sort((a, b) => (b.snr ?? 0).compareTo(a.snr ?? 0));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 8, bottom: 4),
            child: Text('신호 세기 (SNR dB-Hz)', style: TextStyle(color: Colors.white54, fontSize: 11)),
          ),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: sorted.length,
              itemBuilder: (ctx, i) {
                final sat = sorted[i];
                final snr = sat.snr ?? 0;
                final maxSnr = 50.0;
                final ratio = (snr / maxSnr).clamp(0.0, 1.0);
                final barColor = snr >= 35 ? Colors.green
                    : snr >= 25 ? Colors.yellow
                    : snr >= 15 ? Colors.orange
                    : Colors.red;

                return SizedBox(
                  width: 28,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text('${sat.snr ?? "-"}', style: TextStyle(
                        color: barColor, fontSize: 9, fontWeight: FontWeight.bold,
                      )),
                      const SizedBox(height: 2),
                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            heightFactor: ratio,
                            child: Container(
                              width: 16,
                              decoration: BoxDecoration(
                                color: barColor,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text('${sat.prn}', style: TextStyle(
                        color: _systemColor(sat.system), fontSize: 8,
                      )),
                      Container(
                        width: 6, height: 6,
                        decoration: BoxDecoration(
                          color: _systemColor(sat.system),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 스카이뷰 페인터 — 위성 위치를 하늘 원형 차트에 표시
class _SkyViewPainter extends CustomPainter {
  final List<SatelliteInfo> satellites;

  _SkyViewPainter(this.satellites);

  static Color _systemColor(String system) {
    switch (system) {
      case 'GPS': return Colors.green;
      case 'GLO': return Colors.red;
      case 'GAL': return Colors.blue;
      case 'BDS': return Colors.orange;
      case 'QZSS': return Colors.purple;
      default: return Colors.grey;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - 20;

    // 배경 원 (고도각 링)
    final bgPaint = Paint()
      ..color = Colors.white10
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    for (final el in [0, 30, 60, 90]) {
      final r = radius * (1 - el / 90);
      canvas.drawCircle(center, r, bgPaint);
    }

    // 고도각 레이블
    final labelStyle = TextStyle(color: Colors.white24, fontSize: 9);
    for (final el in [0, 30, 60]) {
      final r = radius * (1 - el / 90);
      final tp = TextPainter(
        text: TextSpan(text: '$el°', style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(center.dx + 2, center.dy - r - tp.height));
    }

    // 십자선 (N-S, E-W)
    final crossPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(center.dx, center.dy - radius), Offset(center.dx, center.dy + radius), crossPaint);
    canvas.drawLine(Offset(center.dx - radius, center.dy), Offset(center.dx + radius, center.dy), crossPaint);

    // 방위 레이블
    final dirStyle = TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold);
    for (final entry in {'N': Offset(0, -1), 'S': Offset(0, 1), 'E': Offset(1, 0), 'W': Offset(-1, 0)}.entries) {
      final tp = TextPainter(
        text: TextSpan(text: entry.key, style: entry.key == 'N' ? dirStyle.copyWith(color: Colors.redAccent) : dirStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final pos = center + entry.value * (radius + 12) - Offset(tp.width / 2, tp.height / 2);
      tp.paint(canvas, pos);
    }

    // 위성 표시
    for (final sat in satellites) {
      if (sat.elevation == null || sat.azimuth == null) continue;

      final el = sat.elevation!.clamp(0, 90);
      final az = sat.azimuth!;
      final r = radius * (1 - el / 90);
      // 방위각: 0°=North(위), 시계방향
      final angle = (az - 90) * pi / 180;
      final pos = center + Offset(r * cos(angle), r * sin(angle));

      final color = _systemColor(sat.system);
      final hasSignal = sat.hasSignal;

      // 원
      final dotPaint = Paint()
        ..color = hasSignal ? color : color.withValues(alpha: 0.3)
        ..style = hasSignal ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(pos, hasSignal ? 8 : 6, dotPaint);

      // PRN 번호
      final tp = TextPainter(
        text: TextSpan(
          text: '${sat.prn}',
          style: TextStyle(
            color: hasSignal ? Colors.white : Colors.white38,
            fontSize: 8,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _SkyViewPainter oldDelegate) => true;
}
