import 'cloud_notes_service.dart';

/// 祈福功课的一种方式，如「念佛 108声」。
class BlessingMethod {
  final String category;
  final String name;
  final String count;
  final String unit;

  const BlessingMethod({
    this.category = '',
    this.name = '',
    this.count = '',
    this.unit = '',
  });

  factory BlessingMethod.fromJson(Map<String, dynamic> m) => BlessingMethod(
        category: (m['category'] ?? '').toString(),
        name: (m['name'] ?? '').toString(),
        count: (m['count'] ?? '').toString(),
        unit: (m['unit'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() =>
      {'category': category, 'name': name, 'count': count, 'unit': unit};

  /// 展示文案：如「念佛 108声」。
  String get label {
    final t = name.isNotEmpty ? name : category;
    if (t.isEmpty) return '';
    return count.isNotEmpty ? '$t $count$unit' : t;
  }
}

/// 一个祈福项目（共修事由）。
class BlessingProject {
  final String id;
  final String title;
  final String target;
  final String templateKey;
  final String dedication;
  final int totalDays;
  final String startDate;
  final List<BlessingMethod> methods;
  final String visibility; // public | private
  final int joinerCount;
  final String status; // normal | closed
  final bool isOwner;

  const BlessingProject({
    required this.id,
    this.title = '',
    this.target = '',
    this.templateKey = '',
    this.dedication = '',
    this.totalDays = 0,
    this.startDate = '',
    this.methods = const [],
    this.visibility = 'public',
    this.joinerCount = 0,
    this.status = 'normal',
    this.isOwner = false,
  });

  factory BlessingProject.fromJson(Map<String, dynamic> m) {
    final rawMethods = m['methods'];
    final methods = <BlessingMethod>[];
    if (rawMethods is List) {
      for (final e in rawMethods) {
        if (e is Map) methods.add(BlessingMethod.fromJson(e.cast<String, dynamic>()));
      }
    }
    return BlessingProject(
      id: (m['_id'] ?? m['id'] ?? '').toString(),
      title: (m['title'] ?? '').toString(),
      target: (m['target'] ?? '').toString(),
      templateKey: (m['templateKey'] ?? '').toString(),
      dedication: (m['dedication'] ?? '').toString(),
      totalDays: m['totalDays'] is num
          ? (m['totalDays'] as num).toInt()
          : int.tryParse('${m['totalDays']}') ?? 0,
      startDate: (m['startDate'] ?? '').toString(),
      methods: methods,
      visibility: (m['visibility'] ?? 'public').toString(),
      joinerCount: m['joinerCount'] is num
          ? (m['joinerCount'] as num).toInt()
          : int.tryParse('${m['joinerCount']}') ?? 0,
      status: (m['status'] ?? 'normal').toString(),
      isOwner: m['isOwner'] == true,
    );
  }

  bool get isPrivate => visibility == 'private';
}

/// 我对某个祈福的参与与打卡进度。
class BlessingProgress {
  final bool joined;
  final int doneCount;
  final String status; // active | done
  final int joinedAt;
  final String lastDate;
  final List<String> doneDates;

  const BlessingProgress({
    this.joined = false,
    this.doneCount = 0,
    this.status = 'active',
    this.joinedAt = 0,
    this.lastDate = '',
    this.doneDates = const [],
  });

  factory BlessingProgress.fromJson(Map<String, dynamic> m) {
    final dates = <String>[];
    final raw = m['doneDates'];
    if (raw is List) {
      for (final e in raw) {
        final s = e.toString();
        if (s.isNotEmpty) dates.add(s);
      }
    }
    return BlessingProgress(
      joined: m['joined'] != false,
      doneCount: m['doneCount'] is num
          ? (m['doneCount'] as num).toInt()
          : int.tryParse('${m['doneCount']}') ?? 0,
      status: (m['status'] ?? 'active').toString(),
      joinedAt: m['joinedAt'] is num
          ? (m['joinedAt'] as num).toInt()
          : int.tryParse('${m['joinedAt']}') ?? 0,
      lastDate: (m['lastDate'] ?? '').toString(),
      doneDates: dates,
    );
  }

  bool get isDone => status == 'done';

  /// 今天是否已祈福。
  bool doneToday([String? today]) =>
      doneDates.contains(today ?? BlessingService.today()) ||
      lastDate == (today ?? BlessingService.today());
}

/// 列表中的一条：项目 + 我的进度（未参与时为 null）。
class BlessingItem {
  final BlessingProject project;
  final BlessingProgress? progress;

  const BlessingItem(this.project, this.progress);
}

/// 详情：项目 + 参与人数 + 我的进度。
class BlessingDetail {
  final BlessingProject project;
  final BlessingProgress? progress;
  final int joinerCount;

  const BlessingDetail(this.project, this.progress, this.joinerCount);
}

/// 祈福共修云接口封装，全部经 CloudNotesService 的统一入口调用。
class BlessingService {
  BlessingService._();

  static final BlessingService instance = BlessingService._();

  CloudNotesService get _svc => CloudNotesService.instance;

  /// 客户端本地今天（yyyy-MM-dd），与云端东八区日期一致。
  static String today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  List<BlessingItem> _parseItems(dynamic raw) {
    final out = <BlessingItem>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          final m = e.cast<String, dynamic>();
          final prog = m['progress'];
          out.add(BlessingItem(
            BlessingProject.fromJson(m),
            prog is Map ? BlessingProgress.fromJson(prog.cast<String, dynamic>()) : null,
          ));
        }
      }
    }
    return out;
  }

  /// 我参与的祈福（进行中 + 已完成）。
  Future<List<BlessingItem>> listMine({int page = 1, int pageSize = 30}) async {
    final res = await _svc.callApi('getBlessings',
        params: {'scope': 'mine', 'page': page, 'pageSize': pageSize});
    return _parseItems(res['items']);
  }

  /// 社区公开的祈福。
  Future<List<BlessingItem>> listCommunity({int page = 1, int pageSize = 30}) async {
    final res = await _svc.callApi('getBlessings',
        params: {'scope': 'all', 'page': page, 'pageSize': pageSize});
    return _parseItems(res['items']);
  }

  Future<BlessingDetail> getById(String id) async {
    final res = await _svc.callApi('getBlessingById', params: {'id': id});
    final pm = res['project'];
    final project = pm is Map
        ? BlessingProject.fromJson(pm.cast<String, dynamic>())
        : const BlessingProject(id: '');
    final prog = res['progress'];
    final count = res['joinerCount'] is num
        ? (res['joinerCount'] as num).toInt()
        : int.tryParse('${res['joinerCount']}') ?? project.joinerCount;
    return BlessingDetail(
      project,
      prog is Map ? BlessingProgress.fromJson(prog.cast<String, dynamic>()) : null,
      count,
    );
  }

  Future<String> create({
    required String title,
    String target = '',
    String templateKey = '',
    String dedication = '',
    int totalDays = 7,
    String startDate = '',
    List<BlessingMethod> methods = const [],
    bool isPrivate = false,
  }) async {
    final res = await _svc.callApi('createBlessing', params: {
      'title': title,
      'target': target,
      'templateKey': templateKey,
      'dedication': dedication,
      'totalDays': totalDays,
      'startDate': startDate.isEmpty ? today() : startDate,
      'methods': methods.map((e) => e.toJson()).toList(),
      'visibility': isPrivate ? 'private' : 'public',
    });
    return (res['id'] ?? '').toString();
  }

  Future<void> update(
    String id, {
    String? title,
    String? target,
    String? templateKey,
    String? dedication,
    int? totalDays,
    String? startDate,
    List<BlessingMethod>? methods,
    bool? isPrivate,
  }) async {
    await _svc.callApi('updateBlessing', params: {
      'id': id,
      if (title != null) 'title': title,
      if (target != null) 'target': target,
      if (templateKey != null) 'templateKey': templateKey,
      if (dedication != null) 'dedication': dedication,
      if (totalDays != null) 'totalDays': totalDays,
      if (startDate != null) 'startDate': startDate,
      if (methods != null) 'methods': methods.map((e) => e.toJson()).toList(),
      if (isPrivate != null) 'visibility': isPrivate ? 'private' : 'public',
    });
  }

  Future<void> delete(String id) async {
    await _svc.callApi('deleteBlessing', params: {'id': id});
  }

  Future<void> join(String id) async {
    await _svc.callApi('joinBlessing', params: {'id': id});
  }

  Future<void> leave(String id) async {
    await _svc.callApi('leaveBlessing', params: {'id': id});
  }

  /// 今日祈福打卡（每天一次）。
  Future<BlessingProgress> blessToday(String id, {String? date}) async {
    final res = await _svc.callApi('blessToday',
        params: {'id': id, 'date': date ?? today()});
    return BlessingProgress(
      joined: true,
      doneCount: res['doneCount'] is num
          ? (res['doneCount'] as num).toInt()
          : int.tryParse('${res['doneCount']}') ?? 0,
      status: (res['status'] ?? 'active').toString(),
    );
  }
}
