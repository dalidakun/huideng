import 'package:flutter/material.dart';

/// 消息页：当前为空白占位页，后续接入消息/通知功能。
class MessagePage extends StatelessWidget {
  const MessagePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5EDE3),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF5EDE3),
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF5d4037)),
        title: Row(
          children: const [
            Text(
              '消息',
              style: TextStyle(
                color: Color(0xFF5d4037),
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            SizedBox(width: 6),
            Text(
              '·',
              style: TextStyle(
                color: Color(0xFF9E9588),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 6),
            Flexible(
              child: Text(
                '诸行无常，一切皆苦；诸法无我，寂灭为乐。',
                style: TextStyle(
                  color: Color(0xFF9E9588),
                  fontSize: 10.5,
                ),
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: const SizedBox.expand(),
    );
  }
}
