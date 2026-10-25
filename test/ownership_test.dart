import 'package:flutter_test/flutter_test.dart';

import 'package:my_flutter_app/auth_service.dart';
import 'package:my_flutter_app/ownership.dart';

/// 「置顶 / 编辑 / 删除」只针对自己的内容：归属判定的回归测试。
void main() {
  setUp(() {
    AuthService.instance.currentUser.value = null;
  });

  test('登录后：自己的帖子判定为本人，他人帖子不是', () {
    AuthService.instance.currentUser.value =
        const AuthUser(id: 'me-uid', nickname: '我');

    expect(isOwnContent('me-uid'), isTrue);
    expect(isOwnContent('other-uid'), isFalse);
  });

  test('未登录 / 归属为空：一律按「不是自己的」处理（不显示置顶/编辑/删除）', () {
    expect(isOwnContent('me-uid'), isFalse);
    expect(isOwnContent(''), isFalse);
    expect(isOwnContent(null), isFalse);
  });

  test('当前用户 id 变化后判定随之变化（登出后不再认为自己的）', () {
    AuthService.instance.currentUser.value = const AuthUser(id: 'me-uid');
    expect(isOwnContent('me-uid'), isTrue);

    AuthService.instance.currentUser.value = null;
    expect(isOwnContent('me-uid'), isFalse);

    AuthService.instance.currentUser.value = const AuthUser(id: 'next-uid');
    expect(isOwnContent('me-uid'), isFalse);
    expect(isOwnContent('next-uid'), isTrue);
  });
}
