import 'package:flutter/material.dart';

/// 消息页：当前为空白占位页，后续接入消息/通知功能。
class MessagePage extends StatelessWidget {
  const MessagePage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF5EDE3),
      body: SizedBox.expand(),
    );
  }
}
