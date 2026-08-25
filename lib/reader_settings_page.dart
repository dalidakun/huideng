import 'package:flutter/material.dart';

import 'reader_preferences.dart';
import 'settings_widgets.dart';

import 'app_palette.dart';
/// 阅读偏好设置：字号、行距、背景、翻页方式。
/// 与阅读页共用同一套存储键（reader_preferences.dart），设置即时生效。
class ReaderSettingsPage extends StatefulWidget {
  const ReaderSettingsPage({super.key});

  @override
  State<ReaderSettingsPage> createState() => _ReaderSettingsPageState();
}

class _ReaderSettingsPageState extends State<ReaderSettingsPage> {
  double _fontSize = 16.0;
  double _lineHeight = 1.8;
  bool _dark = false;
  int _pageMode = ReaderPreferences.pageModeScroll;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _fontSize = await ReaderPreferences.getFontSize();
    _lineHeight = await ReaderPreferences.getLineHeight();
    _dark = await ReaderPreferences.isDarkMode();
    _pageMode = await ReaderPreferences.getPageMode();
    if (mounted) setState(() => _loaded = true);
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
      child: Text(text,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: sTextSec)),
    );
  }

  /// 顶部预览：背景随「背景」选择变化，不使用边框。
  Widget _buildPreview() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      decoration: BoxDecoration(
        color: _dark ? const Color(0xFF121212) : AppPalette.p.tintBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        '燃灯照我，慧海无涯。\n念念不忘，必有回响。',
        style: TextStyle(
          color: _dark ? Colors.white : const Color(0xFF212121),
          fontSize: _fontSize,
          height: _lineHeight,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  /// 滑块区：无卡片背景，只保留标签 + 数值 + 滑杆。
  Widget _buildSliderSection({
    required String label,
    required IconData icon,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Icon(icon, size: 18, color: sTextSec),
              const SizedBox(width: 8),
              Text(label, style: TextStyle(fontSize: 15, color: sText)),
              const Spacer(),
              Text(valueText,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: sGold)),
            ],
          ),
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions,
          activeColor: sGold,
          inactiveColor: sGold.withValues(alpha: 0.2),
          onChanged: onChanged,
        ),
      ],
    );
  }

  /// 单选行：无背景无边框，选中时显示对勾。
  Widget _plainOptionRow({
    required IconData icon,
    required String title,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: selected ? sGold : sTextHint),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  color: selected ? sText : sTextSec,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ),
            if (selected) Icon(Icons.check, size: 20, color: sGold),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const SettingsPageScaffold(
        title: '阅读偏好',
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return SettingsPageScaffold(
      title: '阅读偏好',
      child: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          _buildPreview(),

          _sectionLabel('字号'),
          _buildSliderSection(
            label: '字号大小',
            icon: Icons.text_fields,
            valueText: _fontSize.toStringAsFixed(0),
            value: _fontSize,
            min: 12,
            max: 32,
            divisions: 20,
            onChanged: (v) {
              setState(() => _fontSize = v);
              ReaderPreferences.setFontSize(v);
            },
          ),

          _sectionLabel('行距'),
          _buildSliderSection(
            label: '行间距',
            icon: Icons.format_line_spacing,
            valueText: _lineHeight.toStringAsFixed(1),
            value: _lineHeight,
            min: 1.2,
            max: 2.5,
            divisions: 13,
            onChanged: (v) {
              setState(() => _lineHeight = v);
              ReaderPreferences.setLineHeight(v);
            },
          ),

          _sectionLabel('背景'),
          _plainOptionRow(
            icon: Icons.wb_sunny_outlined,
            title: '米黄护眼',
            selected: !_dark,
            onTap: () {
              setState(() => _dark = false);
              ReaderPreferences.setDarkMode(false);
            },
          ),
          _plainOptionRow(
            icon: Icons.dark_mode_outlined,
            title: '深色护眼',
            selected: _dark,
            onTap: () {
              setState(() => _dark = true);
              ReaderPreferences.setDarkMode(true);
            },
          ),

          _sectionLabel('翻页方式'),
          _plainOptionRow(
            icon: Icons.view_agenda_outlined,
            title: '纵向滚动',
            selected: _pageMode == ReaderPreferences.pageModeScroll,
            onTap: () {
              setState(() => _pageMode = ReaderPreferences.pageModeScroll);
              ReaderPreferences.setPageMode(ReaderPreferences.pageModeScroll);
            },
          ),
          _plainOptionRow(
            icon: Icons.menu_book_outlined,
            title: '左右翻页',
            selected: _pageMode == ReaderPreferences.pageModeFlip,
            onTap: () {
              setState(() => _pageMode = ReaderPreferences.pageModeFlip);
              ReaderPreferences.setPageMode(ReaderPreferences.pageModeFlip);
            },
          ),
        ],
      ),
    );
  }
}
