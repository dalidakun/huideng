import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/cloud_notes_service.dart';
import 'package:my_flutter_app/notification_center.dart';

void main() {
  test('订阅系统通知不生成互动用户，标题直接显示贺语', () {
    final groups = NotificationCenter.aggregate(const [
      NotificationItem(
        id: 'sub-1',
        type: 'subscription',
        content: '恭喜你获得无限翻译和认证徽标。',
        viewed: false,
        createdAt: 1000,
      ),
    ]);

    expect(groups, hasLength(1));
    expect(groups.first.type, 'subscription');
    expect(groups.first.actors, isEmpty);
    expect(groups.first.hasUnread, isTrue);
    expect(groups.first.noteId, isEmpty);
    expect(groups.first.noteContent, isEmpty);
    expect(groups.first.activityIds, ['sub-1']);
  });
}
