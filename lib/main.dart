import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'presentation/providers/auth_provider.dart';
import 'presentation/providers/dashboard_provider.dart';
import 'presentation/providers/profile_provider.dart';
import 'presentation/router/app_router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  runApp(const ProviderScope(child: EduVisionApp()));
}

class EduVisionApp extends ConsumerWidget {
  const EduVisionApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    // ── المراقب الأساسي لتغيير المستخدم ─────────────────────────────────
    // يجلس هنا في أعلى الـ widget tree — يُشغَّل مرة واحدة طوال عمر التطبيق.
    // عند كل تغيير في authProvider يتحقق:
    // - إذا انتقلنا من AuthAuthenticated(userA) → AuthAuthenticated(userB)
    //   أي تسجيل دخول بحساب مختلف → يُلغي كل providers البيانات فوراً
    // - إذا انتقلنا إلى AuthUnauthenticated → يُلغي أيضاً
    // هذا يضمن أن profileProvider/dashboardProvider/myCourseItemsProvider
    // تُعيد الجلب من API بدلاً من إرجاع بيانات المستخدم السابق
    ref.listen<AuthState>(authProvider, (previous, next) {
      final prevId = (previous is AuthAuthenticated) ? previous.user.id : null;
      final nextId = (next     is AuthAuthenticated) ? next.user.id     : null;

      // المستخدم تغيّر (دخول بحساب جديد) أو خرج
      final userChanged = prevId != nextId;

      if (userChanged) {
        ref.invalidate(profileProvider);
        ref.invalidate(dashboardProvider);
        ref.invalidate(myCourseItemsProvider);
        ref.invalidate(myCoursesProvider);
      }
    });

    return MaterialApp.router(
      title: 'ايديو فيجن',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      routerConfig: router,
    );
  }
}
