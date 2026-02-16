import 'package:flutter/material.dart';

/// 프로젝트 관리 화면
/// 프로젝트 목록, 생성, 삭제, 설정
class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({super.key});

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('프로젝트'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettings,
            tooltip: '설정',
          ),
        ],
      ),
      body: _buildProjectList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewProject,
        icon: const Icon(Icons.add),
        label: const Text('새 프로젝트'),
      ),
    );
  }

  Widget _buildProjectList() {
    // TODO: Provider에서 프로젝트 목록 가져오기
    return const Center(
      child: Text('프로젝트가 없습니다\n\n새 프로젝트를 만들어보세요'),
    );
  }

  void _createNewProject() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('새 프로젝트'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: '프로젝트 이름',
              hintText: '예: 국도00호선 종단측량',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('생성'),
            ),
          ],
        );
      },
    );

    if (name != null && name.isNotEmpty) {
      // TODO: 프로젝트 생성
    }
  }

  void _showSettings() {
    // TODO: 설정 화면
  }
}
