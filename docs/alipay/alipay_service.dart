/// 支付宝 App 支付客户端（参考实现，未联调）。
///
/// 依赖原生通道 `huideng/alipay`（见 `docs/alipay/AlipayChannel.kt`），
/// 通道只做两件事：调起收银台、判断支付宝是否安装。
/// 下单、验签、确认到账全部在云函数完成，客户端不接触私钥。
///
/// 实际接入时放到 `lib/alipay_service.dart`，并把 import 改成
/// `import 'cloud_notes_service.dart';`（同目录）。
import 'package:flutter/services.dart';

import 'cloud_notes_service.dart';

/// 原生 SDK 的返回码。
/// 9000 成功；8000/6004 结果待确认；6001 用户取消；其余为失败/未知。
class AlipayResult {
  final String resultStatus;
  final String memo;
  final String raw;

  const AlipayResult({
    required this.resultStatus,
    required this.memo,
    required this.raw,
  });

  bool get succeeded => resultStatus == '9000';
  bool get canceled => resultStatus == '6001';
  bool get needsConfirm => resultStatus == '8000' || resultStatus == '6004';

  String get message {
    switch (resultStatus) {
      case '9000':
        return '支付成功';
      case '8000':
        return '支付结果确认中';
      case '4000':
        return '支付失败';
      case '5000':
        return '重复请求，请稍后查看资助记录';
      case '6001':
        return '已取消支付';
      case '6002':
        return '网络连接异常';
      case '6004':
        return '支付结果未知，请稍后查看';
      default:
        return memo.isNotEmpty ? memo : '支付未完成（$resultStatus）';
    }
  }
}

enum PayStatus { paid, pending, closed, canceled, failed }

class PayOutcome {
  final PayStatus status;
  final String outTradeNo;
  final int amountFen;
  final String message;

  const PayOutcome({
    required this.status,
    this.outTradeNo = '',
    this.amountFen = 0,
    this.message = '',
  });

  bool get isPaid => status == PayStatus.paid;
}

class PayException implements Exception {
  final String message;
  const PayException(this.message);
  @override
  String toString() => message;
}

class AlipayService {
  AlipayService._();

  static final AlipayService instance = AlipayService._();

  static const MethodChannel _channel = MethodChannel('huideng/alipay');

  /// 设备是否安装支付宝（Android 11+ 需要在 Manifest 的 queries 里声明包名）。
  Future<bool> isInstalled() async {
    try {
      return await _channel.invokeMethod<bool>('isInstalled') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 完整流程：云函数下单 → 调起收银台 → 服务端确认到账。
  /// 返回 paid 才代表真的收到钱；其余状态只用于界面提示。
  Future<PayOutcome> donate({
    required int amountFen,
    String client = 'android',
  }) async {
    if (amountFen < 100 || amountFen > 200000) {
      return const PayOutcome(
        status: PayStatus.failed,
        message: '金额需在 1–2000 元之间',
      );
    }

    final Map<String, dynamic> created;
    try {
      created = await CloudNotesService.instance.callApi(
        'createPayOrder',
        params: {'amountFen': amountFen, 'client': client},
      );
    } on CloudApiException catch (e) {
      return PayOutcome(status: PayStatus.failed, message: e.message);
    } catch (_) {
      return const PayOutcome(status: PayStatus.failed, message: '下单失败，请稍后重试');
    }

    final outTradeNo = created['outTradeNo']?.toString() ?? '';
    final orderStr = created['orderStr']?.toString() ?? '';
    if (outTradeNo.isEmpty || orderStr.isEmpty) {
      return const PayOutcome(status: PayStatus.failed, message: '下单失败，请稍后重试');
    }

    final AlipayResult result;
    try {
      result = await _invokePay(orderStr);
    } on MissingPluginException {
      return PayOutcome(
        status: PayStatus.failed,
        outTradeNo: outTradeNo,
        message: '当前版本缺少支付宝支付通道，请升级 App',
      );
    } on PayException catch (e) {
      return PayOutcome(
        status: PayStatus.failed,
        outTradeNo: outTradeNo,
        message: e.message,
      );
    } on PlatformException catch (e) {
      return PayOutcome(
        status: PayStatus.failed,
        outTradeNo: outTradeNo,
        message: e.message ?? '调起支付宝失败',
      );
    }

    if (result.canceled) {
      return PayOutcome(
        status: PayStatus.canceled,
        outTradeNo: outTradeNo,
        amountFen: amountFen,
        message: result.message,
      );
    }
    if (!result.succeeded && !result.needsConfirm) {
      return PayOutcome(
        status: PayStatus.failed,
        outTradeNo: outTradeNo,
        amountFen: amountFen,
        message: result.message,
      );
    }

    // 9000 也不代表服务端已入账：以查单结果为准（通知可能延迟或丢失）。
    return _confirm(outTradeNo, amountFen);
  }

  /// 手动刷新某笔订单（用于「结果确认中」页面的重试按钮）。
  Future<PayOutcome> refresh(String outTradeNo, {int amountFen = 0}) {
    return _confirm(outTradeNo, amountFen, attempts: 1);
  }

  Future<AlipayResult> _invokePay(String orderStr) async {
    final map = await _channel.invokeMapMethod<String, String>(
      'pay',
      {'orderStr': orderStr},
    );
    if (map == null) throw const PayException('支付未返回结果');
    return AlipayResult(
      resultStatus: map['resultStatus'] ?? '',
      memo: map['memo'] ?? '',
      raw: map['result'] ?? '',
    );
  }

  Future<PayOutcome> _confirm(
    String outTradeNo,
    int amountFen, {
    int attempts = 3,
  }) async {
    const delays = <Duration>[
      Duration(milliseconds: 800),
      Duration(milliseconds: 1600),
      Duration(seconds: 3),
    ];

    for (var i = 0; i < attempts; i++) {
      await Future<void>.delayed(delays[i < delays.length ? i : delays.length - 1]);
      try {
        final r = await CloudNotesService.instance.callApi(
          'queryPayOrder',
          params: {'outTradeNo': outTradeNo},
        );
        final status = r['status']?.toString();
        if (status == 'paid') {
          return PayOutcome(
            status: PayStatus.paid,
            outTradeNo: outTradeNo,
            amountFen: amountFen,
            message: '资助成功，感谢您',
          );
        }
        if (status == 'closed') {
          return PayOutcome(
            status: PayStatus.closed,
            outTradeNo: outTradeNo,
            amountFen: amountFen,
            message: '订单已关闭',
          );
        }
      } catch (_) {
        // 网络抖动：继续下一次查询。
      }
    }

    return PayOutcome(
      status: PayStatus.pending,
      outTradeNo: outTradeNo,
      amountFen: amountFen,
      message: '支付结果确认中，可在「资助记录」查看',
    );
  }
}
