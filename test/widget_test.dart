import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:longitudinal_viewer_mobile/main.dart';

void main() {
  testWidgets('App starts successfully', (WidgetTester tester) async {
    // 앱 빌드
    await tester.pumpWidget(const LongitudinalViewerApp());

    // 메인 화면이 로드되는지 확인
    expect(find.text('데이터'), findsOneWidget);
    expect(find.text('레벨'), findsOneWidget);
    expect(find.text('도면'), findsOneWidget);
    expect(find.text('프로젝트'), findsOneWidget);
  });
}
