import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/video_catalog.dart';

void main() {
  group('resolveVideoUrl', () {
    test('相对路径补全为 R2 地址', () {
      expect(
        resolveVideoUrl('videos/v001/index.m3u8'),
        '$kVideoBaseUrl/videos/v001/index.m3u8',
      );
    });

    test('以斜杠开头的路径不会拼出双斜杠', () {
      expect(
        resolveVideoUrl('/posters/v001.jpg'),
        '$kVideoBaseUrl/posters/v001.jpg',
      );
    });

    test('绝对地址原样返回', () {
      expect(
        resolveVideoUrl('https://example.com/a.mp4'),
        'https://example.com/a.mp4',
      );
    });

    test('空串保持为空', () {
      expect(resolveVideoUrl('   '), '');
    });
  });

  group('VideoCatalog.fromJson', () {
    test('解析标题、时长、封面与多档清晰度', () {
      final catalog = VideoCatalog.fromJson({
        'updatedAt': '2026-10-28',
        'videos': [
          {
            'id': 'v001',
            'title': '佛说无量寿经',
            'subtitle': 'Aputi 动画 · 4K 修复版',
            'description': '简介',
            'durationSec': 2490,
            'cover': 'posters/v001.jpg',
            'sources': [
              {'label': '自动', 'auto': true, 'path': 'videos/v001/master.m3u8'},
              {'label': '480P', 'path': 'videos/v001/480p.m3u8', 'height': 480},
              {'label': '720P', 'path': 'videos/v001/index.m3u8', 'height': 720},
            ],
          },
        ],
      });

      expect(catalog.updatedAt, '2026-10-28');
      expect(catalog.videos, hasLength(1));
      final video = catalog.videos.single;
      expect(video.title, '佛说无量寿经');
      expect(video.duration, const Duration(seconds: 2490));
      expect(video.coverUrl, '$kVideoBaseUrl/posters/v001.jpg');
      expect(video.sources.map((s) => s.label), ['自动', '480P', '720P']);
      // 有「自动」档时优先用它（多码率自适应），卡片上的清晰度仍显示 720P。
      expect(video.defaultSource?.label, '自动');
      expect(video.defaultSource?.auto, isTrue);
      expect(video.qualityLabel, '720P');

      final manual = VideoItem.fromJson({
        'id': 'v003',
        'title': '手动档',
        'sources': [
          {'label': '480P', 'url': 'a.m3u8', 'height': 480},
          {'label': '720P', 'url': 'b.m3u8', 'height': 720},
        ],
      });
      expect(manual.defaultSource?.label, '720P');
    });

    test('解析网盘直链与文件大小（下载后本地播放）', () {
      final video = VideoItem.fromJson({
        'id': 'v004',
        'title': '光鸭直链',
        'downloadUrl': 'https://example.com/v004.mp4',
        'fileSize': 403000000,
      });
      expect(video.downloadFirst, isTrue);
      expect(video.playable, isTrue);
      expect(video.downloadUrl, 'https://example.com/v004.mp4');
      expect(video.fileSize, 403000000);

      final relative = VideoItem.fromJson({
        'id': 'v005',
        'title': '相对直链',
        'download': 'videos/v005.mp4',
      });
      expect(relative.downloadUrl, '$kVideoBaseUrl/videos/v005.mp4');
    });

    test('解析分片直链（每片 <100MB，下载后拼接）', () {
      final video = VideoItem.fromJson({
        'id': 'v006',
        'title': '分片视频',
        'parts': [
          {'url': 'https://example.com/p1.mp4', 'size': 94371840},
          {'url': 'https://example.com/p2.mp4', 'size': 94371840},
          {'url': 'https://example.com/p3.mp4', 'size': 50000000},
        ],
      });
      expect(video.downloadFirst, isTrue);
      expect(video.parts, hasLength(3));
      expect(video.parts.first.size, 94371840);
      expect(video.expectedBytes, 94371840 * 2 + 50000000);
      expect(video.parts.first.url, 'https://example.com/p1.mp4');
    });

    test('解析手动下载（网盘分享页 + 分片大小）', () {
      final video = VideoItem.fromJson({
        'id': 'v007',
        'title': '手动下载',
        'shareUrl': 'https://movies.lanzouq.com/i0QdY4dwc87c',
        'partSizes': [94371840, 94371840, 44928098],
      });
      expect(video.manualDownload, isTrue);
      expect(video.downloadFirst, isTrue);
      expect(video.playable, isTrue);
      expect(video.parts, isEmpty);
      expect(video.expectedBytes, 94371840 * 2 + 44928098);
    });

    test('兼容只写一个 url 的简写清单', () {
      final catalog = VideoCatalog.fromJson({
        'videos': [
          {
            'id': 'v002',
            'title': '简写视频',
            'url': 'videos/v002/index.m3u8',
            'quality': '720P',
          },
        ],
      });

      final video = catalog.videos.single;
      expect(video.sources, hasLength(1));
      expect(video.sources.single.url, '$kVideoBaseUrl/videos/v002/index.m3u8');
      expect(video.duration, Duration.zero);
    });

    test('没有可播放源的条目会被跳过', () {
      final catalog = VideoCatalog.fromJson({
        'videos': [
          {'id': 'bad', 'title': '没有源'},
          {'id': 'v001', 'title': '正常', 'sources': [{'url': 'a.mp4'}]},
        ],
      });
      expect(catalog.videos.map((v) => v.id), ['v001']);
    });
  });
}
