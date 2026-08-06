import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/auth_service.dart';
import 'package:my_flutter_app/cloud_notes_service.dart';
import 'package:my_flutter_app/sync_service.dart';

/// 同步上传诊断（真机运行，复用已安装 App 的真实登录态与本地数据）：
///   flutter test integration_test/sync_diag_test.dart -d <device>
void main() {
  testWidgets('sync push diagnostic', (tester) async {
    // 恢复真实会话（测试包与正式包同包名，共享 SharedPreferences 与登录态）。
    await AuthService.instance.restoreDone;
    debugPrint('DIAG isLoggedIn=${AuthService.instance.isLoggedIn}');

    // 1. 先直接测试云端写入回环（验证会话 + setUserData 云函数本身可用）。
    try {
      await CloudNotesService.instance.setUserData({
        'files': {
          'diag_probe': {'name': 'diag.txt', 'data': 'hello'},
        },
      });
      final back = await CloudNotesService.instance.getUserData();
      final files = (back?['files'] as Map?) ?? {};
      debugPrint(
          'DIAG roundtrip OK filesKeys=${files.keys.toList()}');
    } catch (e) {
      debugPrint('DIAG roundtrip FAILED $e');
    }

    // 2. 触发一次真实推送（SyncService.push 走 _collect：头像/横幅/sutra_states/prefs）。
    try {
      await SyncService.instance.push();
      debugPrint('DIAG push() returned normally');
    } catch (e) {
      debugPrint('DIAG push() threw $e');
    }

    // 3. 拉回云端看 files 是否包含 avatar/banner。
    try {
      final back = await CloudNotesService.instance.getUserData();
      final files = (back?['files'] as Map?) ?? {};
      debugPrint(
          'DIAG after-push filesKeys=${files.keys.toList()}');
      final avatar = files['avatar'];
      final banner = files['banner'];
      debugPrint(
          'DIAG avatar=${avatar != null ? (avatar as Map)['name'] : 'NULL'} dataLen=${avatar != null ? (avatar as Map)['data'].toString().length : 0}');
      debugPrint(
          'DIAG banner=${banner != null ? (banner as Map)['name'] : 'NULL'} dataLen=${banner != null ? (banner as Map)['data'].toString().length : 0}');
    } catch (e) {
      debugPrint('DIAG getUserData after push FAILED $e');
    }
  });
}
