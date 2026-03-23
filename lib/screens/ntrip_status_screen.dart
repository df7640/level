import 'package:flutter/material.dart';
import '../services/ntrip_service.dart';
import '../services/bluetooth_gnss_service.dart';

/// NTRIP 기지국 상태 화면 — 연결 상태 + RTCM 메시지 통계 + 소스테이블
class NtripStatusScreen extends StatefulWidget {
  final NtripService ntripService;
  final BluetoothGnssService gnssService;

  const NtripStatusScreen({
    super.key,
    required this.ntripService,
    required this.gnssService,
  });

  @override
  State<NtripStatusScreen> createState() => _NtripStatusScreenState();
}

class _NtripStatusScreenState extends State<NtripStatusScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<String>? _sourceTable;
  bool _loadingSourceTable = false;
  String _sourceFilter = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    widget.ntripService.addListener(_onUpdate);
    widget.gnssService.addListener(_onUpdate);
  }

  @override
  void dispose() {
    widget.ntripService.removeListener(_onUpdate);
    widget.gnssService.removeListener(_onUpdate);
    _tabController.dispose();
    super.dispose();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSourceTable() async {
    setState(() => _loadingSourceTable = true);
    final table = await widget.ntripService.getSourceTable();
    if (mounted) {
      setState(() {
        _sourceTable = table;
        _loadingSourceTable = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ntrip = widget.ntripService;
    final config = ntrip.config;
    final isConnected = ntrip.isConnected;

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('기지국 정보'),
        backgroundColor: Colors.grey[850],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.greenAccent,
          labelColor: Colors.greenAccent,
          unselectedLabelColor: Colors.white54,
          tabs: const [
            Tab(text: '상태'),
            Tab(text: 'RTCM'),
            Tab(text: '소스테이블'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildStatusTab(ntrip, config, isConnected),
          _buildRtcmTab(ntrip),
          _buildSourceTableTab(ntrip),
        ],
      ),
    );
  }

  /// 연결 상태 탭
  Widget _buildStatusTab(NtripService ntrip, NtripConfig? config, bool isConnected) {
    final gnss = widget.gnssService;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 연결 상태 카드
        _card(
          title: '연결 상태',
          icon: isConnected ? Icons.cell_tower : Icons.signal_cellular_off,
          iconColor: isConnected ? Colors.greenAccent : Colors.red,
          children: [
            _row('상태', _stateLabel(ntrip.state), _stateColor(ntrip.state)),
            if (config != null) ...[
              _row('서버', '${config.host}:${config.port}'),
              _row('마운트포인트', config.mountPoint),
              _row('계정', config.username),
            ],
            if (ntrip.errorMessage != null)
              _row('오류', ntrip.errorMessage!, Colors.redAccent),
          ],
        ),
        const SizedBox(height: 12),
        // 수신 통계
        _card(
          title: '수신 통계',
          icon: Icons.download,
          iconColor: Colors.cyanAccent,
          children: [
            _row('수신 데이터', '${(ntrip.bytesReceived / 1024).toStringAsFixed(1)} KB'),
            _row('MSM 수신', ntrip.hasReceivedMsm ? 'OK' : '미수신',
                ntrip.hasReceivedMsm ? Colors.greenAccent : Colors.orangeAccent),
            if (ntrip.lastDataTime != null)
              _row('마지막 수신', _timeAgo(ntrip.lastDataTime!)),
          ],
        ),
        const SizedBox(height: 12),
        // GPS 상태 요약
        _card(
          title: 'GPS 연결',
          icon: Icons.gps_fixed,
          iconColor: gnss.connectionState == GnssConnectionState.connected ? Colors.green : Colors.white38,
          children: [
            _row('기기', gnss.deviceName ?? '미연결'),
            _row('Fix', _fixLabel(gnss.fixQuality), _fixColor(gnss.fixQuality)),
            _row('위성 수', '${gnss.satellites}'),
            if (gnss.pdop != null) _row('PDOP', gnss.pdop!.toStringAsFixed(1)),
            if (gnss.position?.diffAge != null)
              _row('보정 나이', '${gnss.position!.diffAge!.toStringAsFixed(1)}초'),
          ],
        ),
        const SizedBox(height: 12),
        // 디버그 로그 (최근 10줄)
        _card(
          title: '최근 로그',
          icon: Icons.terminal,
          iconColor: Colors.white38,
          children: [
            for (final log in ntrip.debugLog.reversed.take(10))
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(log, style: const TextStyle(color: Colors.white54, fontSize: 10, fontFamily: 'monospace')),
              ),
            if (ntrip.debugLog.isEmpty)
              const Text('로그 없음', style: TextStyle(color: Colors.white24, fontSize: 11)),
          ],
        ),
      ],
    );
  }

  /// RTCM 메시지 통계 탭
  Widget _buildRtcmTab(NtripService ntrip) {
    final types = ntrip.rtcmTypeCounts;
    if (types.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.signal_cellular_off, size: 48, color: Colors.white24),
            SizedBox(height: 12),
            Text('RTCM 데이터 미수신', style: TextStyle(color: Colors.white38)),
            Text('NTRIP 연결 후 데이터가 표시됩니다', style: TextStyle(color: Colors.white24, fontSize: 12)),
          ],
        ),
      );
    }

    // 메시지 타입별 정렬
    final sorted = types.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final total = sorted.fold<int>(0, (s, e) => s + e.value);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 요약
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[850],
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _infoChip('메시지 타입', '${types.length}'),
              _infoChip('총 메시지', '$total'),
              _infoChip('MSM', ntrip.hasReceivedMsm ? 'OK' : 'X',
                  ntrip.hasReceivedMsm ? Colors.greenAccent : Colors.red),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 메시지별 상세
        for (final entry in sorted) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[850],
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(
                    color: _rtcmColor(entry.key),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${entry.key} - ${NtripService.rtcmTypeName(entry.key)}',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
                Text(
                  '${entry.value}',
                  style: const TextStyle(color: Colors.cyanAccent, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// 소스테이블 탭
  Widget _buildSourceTableTab(NtripService ntrip) {
    return Column(
      children: [
        // 검색/새로고침 바
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '마운트포인트 검색...',
                    hintStyle: const TextStyle(color: Colors.white24),
                    prefixIcon: const Icon(Icons.search, color: Colors.white38, size: 20),
                    filled: true,
                    fillColor: Colors.grey[850],
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onChanged: (v) => setState(() => _sourceFilter = v.toUpperCase()),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: _loadingSourceTable
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh, color: Colors.white70),
                onPressed: _loadingSourceTable ? null : _loadSourceTable,
                tooltip: '소스테이블 가져오기',
              ),
            ],
          ),
        ),
        // 현재 마운트포인트 표시
        if (ntrip.config != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.greenAccent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.greenAccent, size: 16),
                const SizedBox(width: 8),
                Text('현재: ${ntrip.config!.mountPoint}',
                    style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
              ],
            ),
          ),
        const SizedBox(height: 8),
        // 리스트
        Expanded(
          child: _sourceTable == null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cell_tower, size: 48, color: Colors.white24),
                      const SizedBox(height: 12),
                      const Text('소스테이블 미로드', style: TextStyle(color: Colors.white38)),
                      const SizedBox(height: 8),
                      ElevatedButton.icon(
                        onPressed: _loadSourceTable,
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('가져오기'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey[700],
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  ),
                )
              : _sourceTable!.isEmpty
                  ? const Center(child: Text('마운트포인트 없음', style: TextStyle(color: Colors.white38)))
                  : _buildMountPointList(),
        ),
      ],
    );
  }

  Widget _buildMountPointList() {
    final filtered = _sourceFilter.isEmpty
        ? _sourceTable!
        : _sourceTable!.where((m) => m.toUpperCase().contains(_sourceFilter)).toList();

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (ctx, i) {
        final mp = filtered[i];
        final isCurrent = widget.ntripService.config?.mountPoint == mp;
        return ListTile(
          dense: true,
          leading: Icon(
            isCurrent ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            color: isCurrent ? Colors.greenAccent : Colors.white38,
            size: 20,
          ),
          title: Text(mp, style: TextStyle(
            color: isCurrent ? Colors.greenAccent : Colors.white,
            fontSize: 13,
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          )),
          trailing: mp.contains('RTCM3')
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('RTCM3', style: TextStyle(color: Colors.blue, fontSize: 9)),
                )
              : null,
        );
      },
    );
  }

  Widget _card({
    required String title,
    required IconData icon,
    Color iconColor = Colors.white54,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[850],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 18),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  Widget _row(String label, String value, [Color? valueColor]) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          Text(value, style: TextStyle(color: valueColor ?? Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _infoChip(String label, String value, [Color? color]) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
        Text(value, style: TextStyle(color: color ?? Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
      ],
    );
  }

  String _stateLabel(NtripState state) {
    switch (state) {
      case NtripState.connected: return '연결됨';
      case NtripState.connecting: return '연결 중...';
      case NtripState.error: return '오류';
      case NtripState.disconnected: return '미연결';
    }
  }

  Color _stateColor(NtripState state) {
    switch (state) {
      case NtripState.connected: return Colors.greenAccent;
      case NtripState.connecting: return Colors.yellow;
      case NtripState.error: return Colors.red;
      case NtripState.disconnected: return Colors.white54;
    }
  }

  Color _fixColor(int fix) {
    switch (fix) {
      case 4: return Colors.green;
      case 5: return Colors.yellow;
      case 1: case 2: return Colors.orange;
      default: return Colors.red;
    }
  }

  String _fixLabel(int fix) {
    switch (fix) {
      case 4: return 'RTK Fixed';
      case 5: return 'RTK Float';
      case 2: return 'DGPS';
      case 1: return 'GPS';
      default: return 'No Fix';
    }
  }

  Color _rtcmColor(int type) {
    if (type >= 1071 && type <= 1137) return Colors.greenAccent; // MSM
    if (type >= 1001 && type <= 1012) return Colors.orange; // Legacy
    if (type == 1005 || type == 1006) return Colors.cyanAccent; // Base station
    return Colors.white54;
  }

  String _timeAgo(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inSeconds < 5) return '방금';
    if (diff.inSeconds < 60) return '${diff.inSeconds}초 전';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
    return '${diff.inHours}시간 전';
  }
}
