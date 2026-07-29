import 'reading_page.dart';

void main() {
  // 测试 ReadingPage 是否可以访问
  ReadingPage page = const ReadingPage(
    title: '测试',
    fromAssistant: false,
  );
  
  print('ReadingPage 可以正常访问');
}