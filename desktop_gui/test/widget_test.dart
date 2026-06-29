import 'package:flutter_test/flutter_test.dart';
import 'package:gon2n_gui/main.dart';

void main() {
  testWidgets('shows connection form', (tester) async {
    await tester.pumpWidget(const GoN2NApp(initialDarkMode: false));

    expect(find.text('加入虚拟局域网'), findsOneWidget);
    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('连接'), findsOneWidget);
  });
}
