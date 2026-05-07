import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:roamvault/main.dart';
import 'package:roamvault/models/backup_state.dart';

void main() {
  testWidgets('App smoke test — renders without crashing', (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => BackupState()),
          ChangeNotifierProvider(create: (_) => AppSettings()),
        ],
        child: const RoamVaultApp(),
      ),
    );
    expect(find.text('RoamVault'), findsWidgets);
  });
}
