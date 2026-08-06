import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/cloud_notes_service.dart';

/// 云端头像/横幅诊断（真机运行）：
///   flutter test integration_test/cloud_diag_test.dart -d <device>
/// 输出广场作者的头像/横幅是否存在于云端（getUserProfiles 匿名可查）。
void main() {
  testWidgets('cloud avatar diagnostic', (tester) async {
    final notes = await CloudNotesService.instance
        .getPlazaNotes(page: 1, pageSize: 20);
    final ids = notes.$1.map((n) => n.ownerUserId).toSet().toList();
    debugPrint('DIAG PLAZA_NOTES=${notes.$1.length} AUTHORS=${ids.length}');
    for (final n in notes.$1.take(5)) {
      debugPrint(
          'DIAG NOTE uid=${n.ownerUserId} name=${n.authorName} account=${n.authorAccount}');
    }
    final profiles = await CloudNotesService.instance.getUserProfiles(ids);
    var withAvatar = 0;
    var withBanner = 0;
    var withAccount = 0;
    var withTagline = 0;
    for (final p in profiles) {
      if (p.avatar.isNotEmpty) withAvatar++;
      if (p.banner.isNotEmpty) withBanner++;
      if (p.account.isNotEmpty) withAccount++;
      if (p.tagline.isNotEmpty) withTagline++;
    }
    debugPrint(
        'DIAG PROFILES=${profiles.length} AVATAR=$withAvatar BANNER=$withBanner ACCOUNT=$withAccount TAGLINE=$withTagline');
    for (final p in profiles.take(5)) {
      debugPrint(
          'DIAG PROFILE uid=${p.id} name=${p.name} account=${p.account} taglineLen=${p.tagline.length} avatarLen=${p.avatar.length} bannerLen=${p.banner.length}');
    }
  });
}
