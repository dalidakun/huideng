import 'dart:async';
import 'dart:convert';
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
  String _localTagline = '燃一盏灯，看见自己，照亮别人。';

  /// 本地昵称缓存：云端同步未完成/失败时兜底，保证重启后昵称不丢失。
  String? _localNickname;

  CloudBase? _app;
  Future<CloudBase?>? _appFuture;

  /// 启动会话恢复是否已完成（结束即置 true，避免启动期抢先匿名登录覆盖真实会话）。
  bool _restoreCompleted = false;

  /// 启动会话恢复任务（单飞）：同一进程只执行一次，供各处等待恢复完成，
  /// 避免并发恢复/并发刷新 token 相互干扰导致请求 401。
  Future<void>? _restoreFuture;

  /// 会话恢复失败后是否已安排过后台重试（每个进程只重试一次）。
  bool _restoreRetried = false;

  /// 串行化并发刷新：避免多个调用同时用同一个 refresh token 刷新，
  /// 轮换竞争导致其中一个拿到 invalid_grant 被误判为会话失效。
  Future<bool>? _refreshLock;

  /// 当前 [currentUser] 是否为本地缓存兜底身份（真实会话恢复成功前）。
  bool _currentUserIsCached = false;

  /// 本地登录身份缓存（uid/手机号/昵称）：会话恢复失败时兜底保持登录态。
  AuthUser? _cachedLogin;

  static const String _kCachedUid = 'user_login_uid';
  static const String _kCachedPhone = 'user_login_phone';
  static const String _kCachedNickname = 'user_login_nickname';

  /// 会话修复备份：过期 access token 修复时暂存会话 JSON，失败时恢复原会话。
  static const String _kSessionBackupKey = 'auth_session_backup';

  /// 最近一次 [requestSmsCode] 返回的验证码校验回调，用于 [loginWithSmsCode]。
  Future<SignInRes> Function(VerifyOtpParams params)? _pendingVerifyOtp;
  String? _pendingPhone;

  /// 最近一次 [requestPhoneChange] 返回的换绑校验回调，用于 [confirmPhoneChange]。
  Future<GetUserRes> Function(UpdateUserVerifyParams params)?
      _pendingPhoneChangeVerify;

  /// 初始化（惰性，幂等）。未配置环境时返回 null。
  /// 用 Future 缓存保证全进程只创建「一个」CloudBase 实例：启动时
  /// [restoreSession] 与各页面云调用会并发走到这里，若初始化两次，
  /// 后初始化的实例读到的是已被前一次刷新轮换掉的旧 refresh token，
  /// 会导致该实例上所有请求 401、会话被判定失效。
  Future<CloudBase?> _ensureApp() {
    return _appFuture ??= _initApp();
  }

  Future<CloudBase?> _initApp() async {
    if (CloudBaseAppConfig.envId.isEmpty) return null;
    final app = await CloudBase.init(
      env: CloudBaseAppConfig.envId,
      region: CloudBaseAppConfig.region,
      accessKey: CloudBaseAppConfig.accessKey.isEmpty
          ? null
          : CloudBaseAppConfig.accessKey,
    );
    _app = app;
    return app;
  }

  /// 初始化并返回 CloudBase 实例（供云函数等服务使用），未配置环境时返回 null。
  Future<CloudBase?> ensureApp() => _ensureApp();

  /// 当前登录会话的 access token，用于云函数侧校验调用者身份。
  /// 未登录或取不到时返回 null。
  /// 刷新失败时同样返回 null——绝不把过期 token 交给云调用，
  /// 否则请求会被网关判为 unauthenticated、SDK 直接删除本地真实会话，
  /// 导致下次启动被强制登出、需要重新登录。
  Future<String?> getAccessToken() async {
    final app = await _ensureApp();
    if (app == null) return null;
    try {
      final ok = await ensureFreshSession();
      if (!ok) {
        debugPrint('[auth] getAccessToken: 会话刷新失败，返回 null');
        return null;
      }
      final res = await app.auth.getSession();
      if (!res.isSuccess) return null;
      final token = res.data?.session?.accessToken;
      return (token == null || token.isEmpty) ? null : token;
    } catch (_) {
      return null;
    }
  }

  /// 确保当前 access token 未过期：临近过期（<10 分钟）或无法确认时主动刷新。
  ///
  /// 背景：服务端登录/刷新响应只带 `expires_in`、不带 `expires_at`，
  /// SDK 的 `_isTokenExpired` 在 `expiresAt == null` 时永远返回 false，
  /// 因此 SDK 永远不会自动刷新；access token 2 小时过期后，任何请求都会
  /// 收到 401，SDK 会把会话直接从本地存储删除——
  /// 这就是「重新打开就需要重新登录」的根因。这里在 App 侧补上主动刷新，
  /// 并用互斥锁串行化并发刷新，避免同刷新令牌轮换竞争被误判失效。
  ///
  /// 返回是否持有可用会话。
  Future<bool> ensureFreshSession() {
    final lock = _refreshLock ??= _ensureFreshSession();
    // 并发调用复用同一次刷新结果；完成后释放锁。
    return lock.whenComplete(() => _refreshLock = null);
  }

  Future<bool> _ensureFreshSession() async {
    final app = await _ensureApp();
    if (app == null) return false;
    try {
      // access token 已过期时先修复：SDK 带过期 token 去刷新会被网关判为
      // unauthenticated 并删除本地会话（→ 下次启动强制登出）。这里先清空
      // 会话让后续请求用 publishable key 作合法 header 再刷新，可彻底避免。
      await _repairExpiredSession(app);
      final res = await app.auth.getSession();
      if (!res.isSuccess || res.data?.session == null) return false;
      final session = res.data!.session!;
      final exp = _tokenExpiry(session.accessToken);
      if (exp != null && exp.difference(DateTime.now()).inSeconds > 600) {
        _syncUserFromSession(session);
        return true;
      }
      // token 仍有效但临近过期（<10 分钟）：此时 header 合法，可安全刷新。
      // 如果 token 已过期（exp 在过去），绝不能再调 refreshSession()——
      // 它会带着过期 header 去刷新，被网关判 unauthenticated 删会话。
      // _repairExpiredSession 已经尝试过合法 header 刷新，失败就保持现状，
      // 等下次网络恢复再刷新，绝不冒险删会话。
      if (exp != null && !DateTime.now().isAfter(exp)) {
        final rr = await app.auth.refreshSession();
        if (rr.isSuccess) {
          _syncUserFromSession(rr.data?.session);
          return true;
        }
        debugPrint('[auth] refresh failed: '
            '${rr.error?.code}/${rr.error?.message}');
        await Future.delayed(const Duration(milliseconds: 1200));
        final rr2 = await app.auth.refreshSession();
        if (rr2.isSuccess) {
          _syncUserFromSession(rr2.data?.session);
          return true;
        }
        debugPrint('[auth] refresh retry failed: '
            '${rr2.error?.code}/${rr2.error?.message}');
      }
      debugPrint('[auth] ensureFreshSession: token 已过期且修复失败，保持缓存身份不删会话');
      return false;
    } catch (e) {
      debugPrint('[auth] ensureFreshSession error: $e');
      return false;
    }
  }

  /// 修复"过期 access token"：服务端刷新接口会校验 Authorization header，
  /// 冷启动/后台恢复时本地 access token 已过期（2 小时），SDK 用这个过期
  /// token 作 header 去刷新会被网关判为 `unauthenticated`（实测确认）并删除
  /// 本地会话，导致下次启动 `_retryRestoreSession` 强制登出、需要重新登录。
  ///
  /// 做法：备份会话 JSON → 清空内存会话（下一次请求改用 publishable key 作
  /// 合法 header）→ 用备份的 refresh token 走 `setSession` 重新建立会话；
  /// 失败则恢复原会话，绝不让会话凭空丢失。修复中途被杀时，下次启动从
  /// 备份重建会话再继续刷新。
  Future<void> _repairExpiredSession(CloudBase app) async {
    // ignore: invalid_use_of_visible_for_testing_member
    var session = app.httpClient.currentSession;
    if (session == null) {
      // 上次修复中途被杀：从备份重建会话，再走下面的刷新修复。
      try {
        final prefs = await SharedPreferences.getInstance();
        final backup = prefs.getString(_kSessionBackupKey);
        if (backup != null && backup.isNotEmpty) {
          session = Session.fromJson(jsonDecode(backup));
          // ignore: invalid_use_of_visible_for_testing_member
          app.httpClient.currentSession = session;
        }
      } catch (_) {}
      if (session == null) return;
    }
    final rt = session.refreshToken;
    if (rt == null || rt.isEmpty) return;
    final exp = _tokenExpiry(session.accessToken);
    final now = DateTime.now();
    if (exp != null && now.isBefore(exp.subtract(const Duration(minutes: 5)))) {
      return; // access token 仍有效，无需修复。
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final backup = jsonEncode(session.toJson());
      await prefs.setString(_kSessionBackupKey, backup);
      // 清空会话：后续请求（刷新）会用 publishable key 作 Authorization，
      // 避免带过期 access token 被网关判 unauthenticated 删除会话。
      // ignore: invalid_use_of_visible_for_testing_member
      app.httpClient.currentSession = null;
      final sr = await app.auth.setSession(SetSessionReq(refreshToken: rt));
      if (sr.isSuccess) {
        debugPrint('[auth] 过期会话已用合法 header 重新刷新');
        // 同步备份最新会话，防止修复刚完成后被杀读到旧 refresh token。
        try {
          final prefs2 = await SharedPreferences.getInstance();
          // ignore: invalid_use_of_visible_for_testing_member
          final ns = app.httpClient.currentSession;
          if (ns != null) {
            await prefs2
                .setString(_kSessionBackupKey, jsonEncode(ns.toJson()));
          }
        } catch (_) {}
        return;
      }
      debugPrint(
          '[auth] setSession 刷新失败：${sr.error?.code}/${sr.error?.message}');
    } catch (e) {
      debugPrint('[auth] repair expired session error: $e');
    }
    // 失败：恢复原会话，避免会话被误删后彻底丢失。
    try {
      final prefs = await SharedPreferences.getInstance();
      final backup = prefs.getString(_kSessionBackupKey);
      if (backup != null && backup.isNotEmpty) {
        // ignore: invalid_use_of_visible_for_testing_member
        app.httpClient.currentSession = Session.fromJson(jsonDecode(backup));
      }
    } catch (_) {}
  }

  /// 会话健康时把真实用户同步到 [currentUser]：启动恢复被瞬时失败跳过
  /// （当前是缓存兜底身份或未登录）时，一旦会话恢复成功立即补齐真实登录态，
  /// 避免「会话明明有效却一直显示未登录」。
  void _syncUserFromSession(Session? session) {
    final user = session?.user;
    if (user == null || user.isAnonymous == true) return;
    if (currentUser.value != null && !_currentUserIsCached) return;
    _currentUserIsCached = false;
    unawaited(_applyUser(user));
  }

  /// 解析 access token（JWT）的 exp 过期时间；解析失败返回 null。
  DateTime? _tokenExpiry(String? token) {
    if (token == null || token.isEmpty) return null;
    try {
      final parts = token.split('.');
      if (parts.length < 2) return null;
      final payload =
          jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      final exp = payload['exp'];
      if (exp is int) {
        return DateTime.fromMillisecondsSinceEpoch(exp * 1000);
      }
    } catch (_) {}
    return null;
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
    final serverNick = meta?.nickName;
    final nick = (serverNick != null && serverNick.isNotEmpty)
        ? serverNick
        : (_localNickname != null && _localNickname!.isNotEmpty
            ? _localNickname
            : null);
    return AuthUser(
      id: user.id ?? '',
      mobilePhoneNumber: user.phone,
      nickname: nick,
      tagline: _localTagline,
    );
  }

  /// 等待启动会话恢复完成：已在恢复中则复用，已结束则立即返回，未开始则启动一次。
  /// 各云调用在发起前应先等待它，避免会话未恢复/未刷新完成时请求被云函数
  /// 判定为未授权，导致首次打开页面「加载失败」。
  Future<void> get restoreDone {
    if (_restoreCompleted) return Future.value();
    return _restoreFuture ??= _restoreSession();
  }

  /// App 启动时调用：从本地恢复会话并校验有效性。
  /// 恢复失败（网络/瞬时异常）时不会直接登出：优先用本地缓存的登录身份兜底，
  /// 并延迟重试一次真正的恢复，避免「第二天打开就需要重新登录」。
  Future<void> restoreSession() => _restoreFuture ??= _restoreSession();

  Future<void> _restoreSession() async {
    final app = await _ensureApp();
    if (app == null) return;
    await _loadLocalTagline();
    await _loadLocalNickname();
    _cachedLogin = await _loadCachedLogin();
    try {
      // 先主动刷新：SDK 不会自动刷新，若拿着昨天过期（2h）的 access token
      // 直接调 getUser，服务端会回 401 unauthenticated 并被 SDK 清掉会话。
      if (!await ensureFreshSession()) {
        throw AuthException('session_expired', '会话失效');
      }
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
      await _applyUser(freshUser);
      unawaited(_ensureDefaultAccount(user.phone ?? ''));
    } catch (e) {
      // 恢复失败：有本地登录身份缓存时保持登录态并安排一次后台重试，
      // 避免瞬时网络/会话刷新失败把用户踢下线；确无缓存才显示未登录。
      debugPrint('[auth] restoreSession failed: $e');
      final cached = _cachedLogin;
      if (cached != null) {
        _currentUserIsCached = true;
        currentUser.value = cached;
        if (!_restoreRetried) {
          _restoreRetried = true;
          unawaited(_retryRestoreSession());
        }
      } else {
        currentUser.value = null;
      }
    } finally {
      _restoreCompleted = true;
    }
  }

  /// 后台重试一次会话恢复：成功则自愈为真实用户。
  /// **绝不因瞬时失败强制登出**：只要本地缓存身份还在，就保持登录态，
  /// 后续任意一次 ensureFreshSession 成功都会自动补齐真实会话。
  /// 只有 refresh token 真正失效（7/31 天）才需要用户手动重新登录。
  Future<void> _retryRestoreSession() async {
    await Future.delayed(const Duration(seconds: 4));
    try {
      final app = await _ensureApp();
      if (app == null) return;
      // 尝试刷新恢复会话：成功时 _syncUserFromSession 已补齐真实登录态。
      await ensureFreshSession();
    } catch (_) {
      // 网络等瞬时异常：保持缓存身份，之后的调用会通过 ensureFreshSession 自愈。
    }
  }

  /// 把一次真实登录会话应用到当前状态：写缓存身份、广播登录态、补默认昵称。
  Future<void> _applyUser(User user) async {
    final authUser = _toAuthUser(user);
    _cachedLogin = authUser;
    await _saveCachedLogin(authUser);
    _currentUserIsCached = false;
    currentUser.value = authUser;
    await _ensureDefaultNickname(user);
    await _recordFirstJoin();
  }

  /// 确保存在一个可用于调用云函数的会话：
  ///  - 已登录：直接返回
  ///  - 已有会话（含匿名）：复用
  ///  - 否则：匿名登录，仅用于浏览公开内容（广场），不会改变 [currentUser]。
  Future<void> ensureAnonymousForBrowse() async {
    // 启动时的会话恢复还在进行：等它结束再决定是否需要匿名会话，
    // 避免抢先匿名登录把本地已持久化的真实会话覆盖掉；
    // 也避免在真实会话恢复完成前就带着过期/无效 token 发请求。
    // 注意：不按 [isLoggedIn] 提前返回——缓存身份兜底但真实会话已失效时，
    // 也必须能建匿名会话，否则重新登录等云函数调用会因无 token 全部失败。
    if (!_restoreCompleted) {
      await restoreDone;
    }
    final app = await _ensureApp();
    if (app == null) return;
    // 已有真实登录身份（含缓存兜底）时绝不建匿名会话：匿名登录会覆盖本地
    // 存储的真实会话（credentials_<envId>），真实 refresh token 一旦被换掉，
    // 下次启动会话恢复就会被判定为「仅剩匿名会话」而清掉缓存身份强制登出、
    // 需要重新登录——这正是「登录后几小时/第二天再打开就掉线」的根因。
    // 会话短暂失效时保持缓存身份，由后续 ensureFreshSession 自愈；
    // 云调用走 publishable key 匿名级即可到达云函数，登录相关接口不受影响。
    if (isLoggedIn) {
      await ensureFreshSession();
      return;
    }
    try {
      final res = await app.auth.getSession();
      if (res.isSuccess && res.data?.session != null) return;
    } catch (_) {
      // 无会话（SDK getSession 抛 no_session）→ 走到下面的匿名登录兜底。
    }
    // 兜底建匿名会话前再查一次：防止与登录流程竞态——登录刚把真实会话
    // 写入存储/内存时，这里的匿名登录把它覆盖掉，导致登录态与真实会话脱节。
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
    // 尽力刷新：已登录但 access token 过期时，直接用旧 token 发验证码会 401
    // 并把会话清掉。
    await ensureFreshSession();
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
    await ensureFreshSession();
    final res = await verify(VerifyOtpParams(token: smsCode.trim()));
    _throwIfFailed(res);
    final user = res.data?.user;
    if (user == null) {
      throw AuthException('no_user', '登录失败，未获取到用户信息');
    }
    await _loadLocalTagline();
    await _loadLocalNickname();
    await _applyUser(user);
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
      await ensureFreshSession();
      _localNickname = nickname;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_nickname', nickname);
      final res = await app.auth.updateUser(UpdateUserReq(nickname: nickname));
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
    _cachedLogin = null;
    await _clearCachedLogin();
    _restoreRetried = false;
    _currentUserIsCached = false;
    _restoreCompleted = true;
    currentUser.value = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kSessionBackupKey);
    } catch (_) {}
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
    final res = await CloudNotesService.instance.callApi('setAccount',
        params: {'username': username, 'password': password});
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
    final res =
        await CloudNotesService.instance.callApi('loginWithAccount', params: {
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
    await _loadLocalNickname();
    await _applyUser(user);
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

  /// 手机号登录后自动生成默认账号：4 位随机小写字母 + 手机号后四位，并随机生成密码。
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

  /// 随机 n 位小写字母（用于默认账号前缀）。
  String _randomChars(int n) {
    const chars = 'abcdefghjkmnpqrstuvwxyz';
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
    await ensureFreshSession();
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
    await ensureFreshSession();
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
    // 重读本地昵称：重装/清数据后云同步可能已把用户设置过的昵称恢复到 prefs，
    // 避免把它误判为空而用「同修+尾号」覆盖云端昵称。
    await _loadLocalNickname();
    // 本地已保存自定义昵称（云端同步可能未完成/失败）时不覆盖默认昵称。
    if (_localNickname != null && _localNickname!.isNotEmpty) return;
    final tail = AuthUser(
      id: user.id ?? '',
      mobilePhoneNumber: user.phone,
    ).phoneTail;
    if (tail.isEmpty) return;
    final app = _app;
    if (app == null) return;
    try {
      await ensureFreshSession();
      final res = await app.auth.updateUser(UpdateUserReq(nickname: '同修$tail'));
      if (!res.isSuccess) return;
      final u = res.data?.user;
      if (u != null) currentUser.value = _toAuthUser(u);
    } catch (_) {}
  }

  Future<void> _loadLocalTagline() async {
    final prefs = await SharedPreferences.getInstance();
    _localTagline = prefs.getString('user_tagline') ?? '燃一盏灯，看见自己，照亮别人。';
  }

  Future<void> _loadLocalNickname() async {
    final prefs = await SharedPreferences.getInstance();
    _localNickname = prefs.getString('user_nickname');
  }

  /// 云同步把本地资料（昵称/签名）恢复到 prefs 后调用：重新读取本地昵称/
  /// 签名并刷新当前登录态，让界面立即显示恢复后的资料，而不是启动时读到的默认值。
  ///
  /// 背景：启动时 [restoreSession] 先于云同步读取 prefs，此时重装/清数据后的
  /// prefs 为空，昵称/签名会被读成默认值；云同步完成恢复 prefs 后若不刷新，
  /// 界面会一直显示默认签名，直到重新登录。
  Future<void> reloadLocalProfile() async {
    await _loadLocalTagline();
    await _loadLocalNickname();
    final current = currentUser.value;
    if (current == null) return;
    final nick = (_localNickname != null && _localNickname!.isNotEmpty)
        ? _localNickname
        : current.nickname;
    final tag = _localTagline;
    if (nick == current.nickname && tag == current.tagline) return;
    currentUser.value = AuthUser(
      id: current.id,
      mobilePhoneNumber: current.mobilePhoneNumber,
      nickname: nick,
      tagline: tag,
    );
  }

  Future<AuthUser?> _loadCachedLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getString(_kCachedUid);
    if (uid == null || uid.isEmpty) return null;
    return AuthUser(
      id: uid,
      mobilePhoneNumber: prefs.getString(_kCachedPhone),
      nickname: prefs.getString(_kCachedNickname),
      tagline: _localTagline,
    );
  }

  Future<void> _saveCachedLogin(AuthUser user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCachedUid, user.id);
    if (user.mobilePhoneNumber != null) {
      await prefs.setString(_kCachedPhone, user.mobilePhoneNumber!);
    }
    if (user.nickname != null && user.nickname!.isNotEmpty) {
      await prefs.setString(_kCachedNickname, user.nickname!);
    }
  }

  Future<void> _clearCachedLogin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCachedUid);
    await prefs.remove(_kCachedPhone);
    await prefs.remove(_kCachedNickname);
  }

  Future<void> _recordFirstJoin() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey('user_created_at')) return;
    await prefs.setInt(
        'user_created_at', DateTime.now().millisecondsSinceEpoch);
  }
}
