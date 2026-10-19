import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'checkin_goals_page.dart';
import 'checkin_settings_page.dart';

/// 功课设置合并页：由功课打卡卡片右上角按钮打开。
/// 顶部两个选项——「每日功课设置」与「打卡目标设置」，分别对应两个 Tab。
class CheckInHubPage extends StatefulWidget {
  const CheckInHubPage({super.key});

  @override
  State<CheckInHubPage> createState() => _CheckInHubPageState();
}

class _CheckInHubPageState extends State<CheckInHubPage>
    with SingleTickerProviderStateMixin {
  final GlobalKey<CheckInSettingsPageState> _settingsKey = GlobalKey();
  late final TabController _tab = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        title: Text('功课设置',
            style: TextStyle(
                color: p.text, fontSize: 18, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.text),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          AnimatedBuilder(
            animation: _tab,
            builder: (_, __) => _tab.index == 0
                ? Padding(
                    padding: const EdgeInsets.only(right: 26),
                    child: GestureDetector(
                      onTap: () => _settingsKey.currentState?.save(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 7),
                        decoration: BoxDecoration(
                          color: p.primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text('保存',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: p.primary)),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: p.primary,
          labelColor: p.primary,
          unselectedLabelColor: p.textSec,
          labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          unselectedLabelStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          tabs: const [
            Tab(text: '每日功课设置'),
            Tab(text: '打卡目标设置'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          CheckInSettingsPage(key: _settingsKey, embedded: true),
          const CheckInGoalsPage(embedded: true),
        ],
      ),
      floatingActionButton: AnimatedBuilder(
        animation: _tab,
        builder: (_, __) {
          if (_tab.index != 0) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SizedBox(
              width: 42,
              height: 42,
              child: FloatingActionButton(
                onPressed: () => _settingsKey.currentState?.addCustomType(),
                heroTag: 'checkin_hub_fab',
                backgroundColor: p.card,
                elevation: 8,
                highlightElevation: 12,
                shape: const CircleBorder(),
                child: Icon(Icons.add,
                    size: 20, color: const Color(0xFF71867A)),
              ),
            ),
          );
        },
      ),
    );
  }
}
