import 'package:flutter/material.dart';

/// 레벨 패널 화면
/// 현장 측량용 계산기
/// 모바일에 최적화: 큰 버튼, 간결한 레이아웃
class LevelPanelScreen extends StatefulWidget {
  const LevelPanelScreen({super.key});

  @override
  State<LevelPanelScreen> createState() => _LevelPanelScreenState();
}

class _LevelPanelScreenState extends State<LevelPanelScreen> {
  // IH (기계고)
  final TextEditingController _ihController = TextEditingController();

  // 읽은 값 (현장 측정)
  final TextEditingController _actualReadingController = TextEditingController();

  // 계획고 컬럼 선택
  String _selectedPlanLevelColumn = 'GH';

  // 선택된 측점
  String? _selectedStationNo;

  // 계산 결과
  double? _targetReading;
  double? _cutFill;
  String? _cutFillStatus;

  @override
  void dispose() {
    _ihController.dispose();
    _actualReadingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('레벨 계산'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showHelp,
            tooltip: '도움말',
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 측점 선택
            _buildStationSelector(),
            const SizedBox(height: 20),

            // IH 입력
            _buildIHInput(),
            const SizedBox(height: 16),

            // 계획고 컬럼 선택
            _buildPlanLevelColumnSelector(),
            const SizedBox(height: 20),

            // 계산 결과 (읽을 값)
            _buildTargetReadingCard(),
            const SizedBox(height: 20),

            // 읽은 값 입력
            _buildActualReadingInput(),
            const SizedBox(height: 20),

            // 절/성토 결과
            _buildCutFillResultCard(),
            const SizedBox(height: 20),

            // 저장 버튼
            _buildSaveButton(),
          ],
        ),
      ),
    );
  }

  /// 측점 선택기
  Widget _buildStationSelector() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.location_on),
        title: const Text('선택된 측점'),
        subtitle: Text(_selectedStationNo ?? '측점을 선택하세요'),
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: _selectStation,
      ),
    );
  }

  /// IH (기계고) 입력
  Widget _buildIHInput() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'IH (기계고)',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _ihController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                suffixText: 'm',
                hintText: '예: 100.500',
              ),
              onChanged: (_) => _calculate(),
            ),
          ],
        ),
      ),
    );
  }

  /// 계획고 컬럼 선택
  Widget _buildPlanLevelColumnSelector() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '계획고 컬럼',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedPlanLevelColumn,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'GH', child: Text('GH')),
                DropdownMenuItem(value: 'IP', child: Text('IP')),
                DropdownMenuItem(value: 'GH-D', child: Text('GH-D')),
                DropdownMenuItem(value: 'GH-1', child: Text('GH-1')),
                DropdownMenuItem(value: 'GH-2', child: Text('GH-2')),
              ],
              onChanged: (value) {
                setState(() => _selectedPlanLevelColumn = value!);
                _calculate();
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 읽을 값 (목표값) 결과 카드
  Widget _buildTargetReadingCard() {
    return Card(
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const Text(
              '읽을 값',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _targetReading != null
                  ? '${_targetReading!.toStringAsFixed(3)} m'
                  : '- - -',
              style: const TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.bold,
                color: Colors.blue,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'IH - 계획고',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 읽은 값 (현장 측정) 입력
  Widget _buildActualReadingInput() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '읽은 값 (현장 측정)',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _actualReadingController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                suffixText: 'm',
                hintText: '예: 89.150',
              ),
              onChanged: (_) => _calculate(),
            ),
          ],
        ),
      ),
    );
  }

  /// 절/성토 결과 카드
  Widget _buildCutFillResultCard() {
    Color statusColor = Colors.grey;
    String statusText = '대기 중';
    IconData statusIcon = Icons.remove;

    if (_cutFillStatus != null) {
      switch (_cutFillStatus) {
        case 'CUT':
          statusColor = Colors.red;
          statusText = '절토 (파내기)';
          statusIcon = Icons.arrow_downward;
          break;
        case 'FILL':
          statusColor = Colors.green;
          statusText = '성토 (쌓기)';
          statusIcon = Icons.arrow_upward;
          break;
        case 'ON_GRADE':
          statusColor = Colors.blue;
          statusText = '계획고 맞음';
          statusIcon = Icons.check;
          break;
      }
    }

    return Card(
      color: statusColor.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(statusIcon, size: 48, color: statusColor),
            const SizedBox(height: 12),
            Text(
              statusText,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: statusColor,
              ),
            ),
            const SizedBox(height: 8),
            if (_cutFill != null)
              Text(
                '${_cutFill!.toStringAsFixed(3)} m',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: statusColor,
                ),
              )
            else
              const Text(
                '- - -',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 저장 버튼
  Widget _buildSaveButton() {
    return ElevatedButton.icon(
      onPressed: _cutFill != null ? _saveReading : null,
      icon: const Icon(Icons.save),
      label: const Text('읽은 값 저장'),
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.all(16),
      ),
    );
  }

  void _selectStation() {
    // TODO: 측점 선택 다이얼로그
  }

  void _calculate() {
    // TODO: 실제 계산 로직 (Provider 사용)
  }

  void _saveReading() {
    // TODO: 읽은 값 저장
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('레벨 계산 도움말'),
        content: const SingleChildScrollView(
          child: Text(
            '1. IH (기계고) 입력\n'
            '   - 측량 기기의 시준선 고도\n'
            '   - 예: 100.500 m\n\n'
            '2. 읽을 값 자동 계산\n'
            '   - 공식: IH - 계획고\n'
            '   - 레벨링 로드에서 봐야 할 값\n\n'
            '3. 읽은 값 입력\n'
            '   - 현장에서 측정한 값\n'
            '   - 예: 89.150 m\n\n'
            '4. 절/성토 판정\n'
            '   - CUT (절토): 파내기\n'
            '   - FILL (성토): 쌓기\n'
            '   - 허용오차: ±0.5mm',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }
}
