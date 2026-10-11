import 'package:debrify/services/desktop_schedule_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'shutdown during asynchronous initialization leaves no timer alive',
    () async {
      SharedPreferences.setMockInitialValues({});
      final service = DesktopScheduleService.instance;
      service.shutdown();
      addTearDown(service.shutdown);
      if (!service.isSupported) return;

      final initializing = service.init();
      service.shutdown();
      await initializing;
      expect(service.debugHasActiveTick, isFalse);
    },
  );

  test('fresh initialization wins after an abandoned startup', () async {
    SharedPreferences.setMockInitialValues({});
    final service = DesktopScheduleService.instance;
    service.shutdown();
    addTearDown(service.shutdown);
    if (!service.isSupported) return;

    final obsoleteStartup = service.init();
    service.shutdown();
    final activeStartup = service.init();
    await Future.wait([obsoleteStartup, activeStartup]);
    expect(service.debugHasActiveTick, isTrue);
    service.shutdown();
    expect(service.debugHasActiveTick, isFalse);
  });
}
