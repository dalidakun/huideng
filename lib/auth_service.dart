import 'dart:async';
import 'dart:math';

import 'package:cloudbase_flutter/cloudbase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloudbase_config.dart';
import 'cloud_notes_service.dart';

/// 认证相关错误，message 可直接展示给用户。
class AuthException implements Exception {
  final String code;
  final String message;

  AuthException(this.code, this.message);

  @override
  String toString() => message;
}

/// 当前登录用户的信息。
class AuthUser {
  final String id;
  final String? mobilePhoneNumber;
  final String? nickname;
  final String? tagline;

  const AuthUser({
    required this.id,
    this.mobilePhoneNumber,
    this.nickname,
    this.tagline,
  });

  /// 展示用昵称，未设置时回退到默认文案。
  String get displayName =>
      (nickname != null && nickname!.isNotEmpty) ? nickname! : '同修';

  /// 手机尾号（用于默认昵称，如「同修 1234」）。
  String get phoneTail {
    final p = mobilePhoneNumber ?? '';
    if (p.isEmpty) return '';
    final digits = p.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    return digits.length >= 4 ? digits.substring(digits.length - 4) : digits;
  }
}

/// 全局认证服务：登录 / 注册 / 退出 / 会话保持。
///
/// 基于腾讯云开发 CloudBase（cloudbase_flutter SDK）实现：
///  - 手机号 + 短信验证码登录（新号码自动注册）
///  - 会话由 SDK 自动持久化，[restoreSession] 用于 App 启动时恢复
///  - 登录态通过 [currentUser]（ValueNotifier）广播，UI 监听它刷新即可
class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  final ValueNotifier<AuthUser?> currentUser = ValueNotifier<AuthUser?>(null);

  bool get isLoggedIn => currentUser.value != null;

  /// 本地签名（tagline），CloudBase 不存此字段，保留本地。
  String _localTagline = '与经为伴，与法同行';

  CloudBase? _app;

  /// 最近一次 [requestSmsCode] 返回的验证码校验回调，用于 [loginWithSmsCode]。
  Future<SignInRes> Function(VerifyOtpParams params)? _pendingVerifyOtp;
  String? _pendingPhone;

  /// 最近一次 [requestPhoneChange] 返回的换绑校验回调，用于 [confirmPhoneChange]。
  Future<GetUserRes> Function(UpdateUserVerifyParams params)? _pendingPhoneChangeVerify;

  /// 初始化（惰性）。未配置环境时返回 null。
  Future<CloudBase?> _ensureApp() async {
    if (_app != null) return _app;
    if (CloudBaseAppConfig.envId.isEmpty) return null;
    _app = await CloudBase.init(
      env: CloudBaseAppConfig.envId,
      region: CloudBaseAppConfig.region,
      accessKey: CloudBaseAppConfig.accessKey.isEmpty
          ? null
          : CloudBaseAppConfig.accessKey,
    );
    return _app;
  }

  /// 初始化并返回 CloudBase 实例（供云函数等服务使用），未配置环境时返回 null。
  Future<CloudBase?> ensureApp() => _ensureApp();

  /// 当前登录会话的 access token，用于云函数侧校验调用者身份。
  /// 未登录或取不到时返回 null。
  Future<String?> getAccessToken() async {
    final app = await _ensureApp();
    if (app == null) return null;
    try {
      final res = await app.auth.getSession();
      if (!res.isSuccess) return null;
      final token = res.data?.session?.accessToken;
      return (token == null || token.isEmpty) ? null : token;
    } catch (_) {
      return null;
    }
  }

  /// 初始化并确保已配置环境，否则抛出用户可读错误。
  Future<CloudBase> _requireApp() async {
    final app = await _ensureApp();
    if (app == null) {
      throw AuthException('no_config', '尚未配置云环境，请填写 cloudbase_config.dart');
    }
    return app;
  }

  void _throwIfFailed(CloudBaseResponse<dynamic> res) {
    if (!res.isSuccess) {
      throw AuthException(
        res.error?.code ?? 'error',
        res.error?.message ?? '请求失败，请稍后重试',
      );
    }
  }

  AuthUser _toAuthUser(User user) {
    final meta = user.userMetadata;
    return AuthUser(
      id: user.id ?? '',
      mobilePhoneNumber: user.phone,
      nickname: meta?.nickName,
      tagline: _localTagline,
    );
  }

  /// App 启动时调用：从本地恢复会话并校验有效性。
  /// 未配置环境、会话失效或网络失败时静默清除，不阻塞启动。
  Future<void> restoreSession() async {
    final app = await _ensureApp();
    if (app == null) return;
    await _loadLocalTagline();
    try {
      final res = await app.auth.getSession();
      if (!res.isSuccess) {
        throw AuthException(
          res.error?.code ?? 'error',
          res.error?.message ?? '会话失效',
        );
      }
      final user = res.data?.user;
      // 匿名会话不算真实登录（浏览广场用），界面仍显示「未登录」。
      if (user == null || user.isAnonymous == true) {
        throw AuthException('no_user', '会话失效');
      }
      // 会话里缓存的用户可能是旧的（昵称等修改后未重新拉取），用服务器最新信息刷新。
      var freshUser = user;
      try {
        final ures = await app.auth.getUser();
        if (ures.data?.user != null) freshUser = ures.data!.user!;
      } catch (_) {}
      currentUser.value = _toAuthUser(freshUser);
      await _ensureDefaultNickname(freshUser);
      await _recordFirstJoin();
      unawaited(_ensureDefaultAccount(user.phone ?? ''));
    } catch (_) {
      currentUser.value = null;
    }
  }

  /// 确保存在一个可用于调用云函数的会话：
  ///  - 已登录：直接返回
  ///  - 已有会话（含匿名）：复用
  ///  - 否则：匿名登录，仅用于浏览公开内容（广场），不会改变 [currentUser]。
  Future<void> ensureAnonymousForBrowse() async {
    if (isLoggedIn) return;
    final app = await _ensureApp();
    if (app == null) return;
    try {
      final res = await app.auth.getSession();
      if (res.isSuccess && res.data?.session != null) return;
    } catch (_) {}
    try {
      await app.auth.signInAnonymously();
    } catch (_) {
      // 匿名登录失败（未开通/网络异常）则静默，保持未登录态。
    }
  }

  /// 发送手机号验证码（用于登录/注册）。
  /// 新手机号验证通过后会自动注册。
  Future<void> requestSmsCode(String phone) async {
    final app = await _requireApp();
    final res = await app.auth.signInWithOtp(SignInWithOtpReq(phone: phone));
    _throwIfFailed(res);
    _pendingVerifyOtp = res.data?.verifyOtp;
    _pendingPhone = phone;
  }

  /// 手机号 + 验证码登录。需先调用 [requestSmsCode]。
  Future<void> loginWithSmsCode(String phone, String smsCode) async {
    await _requireApp();
    final verify = _pendingVerifyOtp;
    if (verify == null || _pendingPhone != phone) {
      throw AuthException('no_pending_otp', '请先获取验证码');
    }
    _pendingVerifyOtp = null;
    _pendingPhone = null;
    final res = await verify(VerifyOtpParams(token: smsCode.trim()));
    _throwIfFailed(res);
    final user = res.data?.user;
    if (user == null) {
      throw AuthException('no_user', '登录失败，未获取到用户信息');
    }
    await _loadLocalTagline();
    currentUser.value = _toAuthUser(user);
    await _ensureDefaultNickname(user);
    await _recordFirstJoin();
    await _ensureDefaultAccount(phone);
  }

  /// 更新当前用户昵称/签名。
  /// 昵称同步到云端；签名（tagline）仅保存本地。
  Future<void> updateProfile({String? nickname, String? tagline}) async {
    final app = await _ensureApp();
    if (tagline != null) {
      _localTagline = tagline;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_tagline', tagline);
    }
    if (nickname != null && nickname.isNotEmpty && app != null) {
      final res = await app.auth
          .updateUser(UpdateUserReq(nickname: nickname));
      if (!res.isSuccess) {
        throw AuthException(
          res.error?.code ?? 'error',
          res.error?.message ?? '昵称更新失败',
        );
      }
      final u = res.data?.user;
      if (u != null) currentUser.value = _toAuthUser(u);
    }
    final current = currentUser.value;
    if (current != null && nickname != null && nickname.isNotEmpty) {
      currentUser.value = AuthUser(
        id: current.id,
        mobilePhoneNumber: current.mobilePhoneNumber,
        nickname: nickname,
        tagline: _localTagline,
      );
    }
  }

  /// 退出登录：通知云端并清除本地登录态。
  Future<void> logout() async {
    _pendingVerifyOtp = null;
    _pendingPhone = null;
    _pendingPhoneChangeVerify = null;
    final app = await _ensureApp();
    if (app != null) {
      try {
        await app.auth.signOut();
      } catch (_) {}
    }
    currentUser.value = null;
  }

  /// 设置/修改账号名称与密码（需已登录）。
  /// 账号名称全局唯一，成功后缓存本地用于展示。
  /// [password] 可空：为空表示仅修改账号名称、保留原密码（编辑资料页场景）。
  Future<void> setAccount({
    required String username,
    String password = '',
  }) async {
    if (!isLoggedIn) {
      throw AuthException('not_logged_in', '请先登录');
    }
    final res = await CloudNotesService.instance
        .callApi('setAccount', params: {'username': username, 'password': password});
    final name = res['username']?.toString();
    if (name != null && name.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_account_name', name);
    }
  }

  /// 忘记密码：通过手机验证码验证后重置登录密码（未登录也可使用）。
  /// 需先调用 [requestSmsCode] 向该手机号发送验证码；
  /// 校验通过后会用验证码完成登录（拿到账号身份），再把账号密码更新为新密码。
  Future<void> resetPassword({
    required String phone,
    required String smsCode,
    required String newPassword,
  }) async {
    if (newPassword.length < 6 || newPassword.length > 64) {
      throw AuthException('invalid_password', '密码长度需为 6-64 位');
    }
    final pending = _pendingVerifyOtp;
    if (pending == null || _pendingPhone != phone) {
      throw AuthException('no_pending_otp', '请先获取验证码');
    }
    // 校验验证码并建立登录会话（uid 由此确认），新手机号会顺带注册，但需本人持有手机号。
    await loginWithSmsCode(phone, smsCode);
    // 登录后必然存在账号名称（无则已由 _ensureDefaultAccount 自动创建），仅更新密码。
    final name = await getAccountName();
    if (name.isEmpty) {
      throw AuthException('no_account', '当前账号未设置账号名称，无法重置密码');
    }
    await setAccount(username: name, password: newPassword);
  }

  /// 使用账号名称 + 密码登录（兼注册）：
  /// 云函数校验通过后签发自定义登录票据，再用票据建立 CloudBase 会话。
  /// 返回 true 表示本次是首次设置密码（注册），false 表示普通登录。
  Future<bool> loginWithAccount({
    required String username,
    required String password,
  }) async {
    final app = await _requireApp();
    final res = await CloudNotesService.instance.callApi('loginWithAccount', params: {
      'username': username,
      'password': password,
    });
    final ticket = res['ticket']?.toString();
    if (ticket == null || ticket.isEmpty) {
      throw AuthException('no_ticket', '登录失败，请稍后重试');
    }
    final sr = await app.auth.signInWithCustomTicket(() async => ticket);
    _throwIfFailed(sr);
    final user = sr.data?.user;
    if (user == null) {
      throw AuthException('no_user', '登录失败，未获取到用户信息');
    }
    await _loadLocalTagline();
    currentUser.value = _toAuthUser(user);
    await _ensureDefaultNickname(user);
    await _recordFirstJoin();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('user_account_name', username.trim());
    return res['registered'] == true;
  }

  /// 查询当前登录用户的账号名称；未设置返回空串。失败时回退到本地缓存。
  Future<String> getAccountName() async {
    if (!isLoggedIn) return '';
    try {
      final res = await CloudNotesService.instance.callApi('getMyAccount');
      final name = res['username']?.toString() ?? '';
      if (name.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_account_name', name);
      }
      return name;
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('user_account_name') ?? '';
    }
  }

  /// 手机号登录后自动生成默认账号：4 位随机字母/数字 + 手机号后四位，并随机生成密码。
  /// 已有账号（含默认账号）则原样返回、不覆盖；用户可在「设置-安全-忘记密码」重置密码。
  Future<void> _ensureDefaultAccount(String phone) async {
    if (!isLoggedIn) return;
    final tail = _phoneTail(phone);
    if (tail.isEmpty) return;
    for (var i = 0; i < 5; i++) {
      final username = _randomChars(4) + tail;
      final password = _randomPassword();
      try {
        final res = await CloudNotesService.instance.callApi(
          'ensureDefaultAccount',
          params: {'username': username, 'password': password},
        );
        final name = res['username']?.toString();
        if (name != null && name.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('user_account_name', name);
        }
        return;
      } catch (_) {
        // 名称被占用则换一组随机数字重试。
      }
    }
  }

  /// 随机 n 位字母/数字（用于默认账号前缀）。
  String _randomChars(int n) {
    const chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
    final r = Random();
    return String.fromCharCodes(
        List.generate(n, (_) => chars.codeUnitAt(r.nextInt(chars.length))));
  }

  /// 随机密码：去掉易混淆字符的字母+数字，长度 10。
  String _randomPassword() {
    const chars = 'abcdefghjkmnpqrstuvwxyz23456789';
    final r = Random();
    return String.fromCharCodes(
        List.generate(10, (_) => chars.codeUnitAt(r.nextInt(chars.length))));
  }

  String _phoneTail(String phone) {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    return digits.length >= 4 ? digits.substring(digits.length - 4) : digits;
  }

  /// 更换绑定手机号第一步：向新手机号发送验证码。
  /// 校验回调保存在内部，随后用 [confirmPhoneChange] 提交验证码完成换绑。
  /// 注意：换绑前后是同一个账号，云端笔记等数据自动保留，无需迁移。
  Future<void> requestPhoneChange(String newPhone) async {
    final app = await _requireApp();
    final res = await app.auth.updateUser(UpdateUserReq(phone: newPhone));
    if (!res.isSuccess) {
      throw AuthException(
        res.error?.code ?? 'error',
        res.error?.message ?? '发送验证码失败',
      );
    }
    final verify = res.data?.verifyOtp;
    if (verify == null) {
      throw AuthException('no_verify_otp', '未获取到验证回调，请重试');
    }
    _pendingPhoneChangeVerify = verify;
  }

  /// 更换绑定手机号第二步：提交新手机号收到的验证码完成换绑。
  Future<void> confirmPhoneChange(String smsCode) async {
    final verify = _pendingPhoneChangeVerify;
    if (verify == null) {
      throw AuthException('no_pending_otp', '请先获取验证码');
    }
    _pendingPhoneChangeVerify = null;
    final res = await verify(UpdateUserVerifyParams(token: smsCode.trim()));
    if (!res.isSuccess) {
      throw AuthException(
        res.error?.code ?? 'error',
        res.error?.message ?? '验证码校验失败',
      );
    }
    final user = res.data?.user;
    if (user != null) currentUser.value = _toAuthUser(user);
  }

  /// 新用户首次登录时设置默认昵称「同修 + 手机尾号」。
  Future<void> _ensureDefaultNickname(User user) async {
    final meta = user.userMetadata;
    if (meta?.nickName != null && meta!.nickName!.isNotEmpty) return;
    final tail = AuthUser(
      id: user.id ?? '',
      mobilePhoneNumber: user.phone,
    ).phoneTail;
    if (tail.isEmpty) return;
    final app = _app;
    if (app == null) return;
    try {
      final res = await app.auth
          .updateUser(UpdateUserReq(nickname: '同修$tail'));
      if (!res.isSuccess) return;
      final u = res.data?.user;
      if (u != null) currentUser.value = _toAuthUser(u);
    } catch (_) {}
  }

  Future<void> _loadLocalTagline() async {
    final prefs = await SharedPreferences.getInstance();
    _localTagline = prefs.getString('user_tagline') ?? '与经为伴，与法同行';
  }

  Future<void> _recordFirstJoin() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey('user_created_at')) return;
    await prefs.setInt('user_created_at', DateTime.now().millisecondsSinceEpoch);
  }
}
