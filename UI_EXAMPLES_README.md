# 佛经阅读器 UI 完整示例

## 文件说明

### 1. `lib/theme.dart` - 主题定义
完整的 Material 3 主题配置，包含所有颜色和样式定义。

**关键颜色：**
- AppBar 背景: #ededed
- 主要文字: #212121
- 次要文字: #424242
- 分隔线: #BDBDBD
- 选中/高亮: #5D4037

### 2. `lib/main.dart` - 应用入口和主页面
包含完整的 MaterialApp 配置和 BottomNavigationBar 示例。
使用 IndexedStack 保持页面状态。

**BottomNavigationBar 配置：**
- 两个标签页："经文" 和 "讨论"
- 选中颜色: #5D4037
- 未选中颜色: #424242
- 背景色: #ededed，无阴影

### 3. `lib/sutra_list_page.dart` - 经文列表页
完整的佛经目录列表页面，带搜索框和文件添加功能。

**搜索框样式：**
- 圆角设计 (borderRadius: 24)
- 背景色: #f7f7f7
- 提示语: "搜索标题"，字号14px，颜色 #212121
- 支持实时搜索过滤

**加号按钮：**
- 圆角背景，颜色 #5D4037
- 点击可打开本地文件选择器
- 支持 .txt 和 .md 文件格式
- 添加成功后显示提示消息

**列表项样式：**
- 白色卡片背景，轻微阴影 (elevation: 1.5)
- 每项间距: vertical: 4, horizontal: 12
- 点击水波纹效果: #F5F5F5
- 分隔线: #BDBDBD, thickness: 0.5
完整的佛经目录列表页面，使用 ListView.builder 和 Card 组件。

**列表项样式：**
- 白色卡片背景，轻微阴影 (elevation: 1.5)
- 每项间距: vertical: 4, horizontal: 12
- 点击水波纹效果: #F5F5F5
- 分隔线: #BDBDBD, thickness: 0.5

### 4. `lib/sutra_reader_page.dart` - 阅读页示例
展示佛经阅读界面的文本样式。支持动态标题。

**阅读样式：**
- 字体大小: 18
- 行高: 1.8
- 字体: 'Noto Serif SC'
- 首行缩进或段落间距，舒适阅读
- AppBar标题根据经文名动态显示

### 5. `lib/discussion_page.dart` - 讨论页占位
简单的讨论区占位页面。

## 使用方法

1. 运行应用：
```bash
flutter run
```

2. 搜索功能：
   - 在搜索框中输入关键词，列表会实时过滤显示匹配的佛经标题

3. 添加本地文件：
   - 点击搜索框右侧的加号按钮
   - 选择本地的 .txt 或 .md 文件
   - 文件名（不含扩展名）将作为经文标题添加到列表中

4. 阅经：
   - 点击列表项可跳转到阅读页查看阅读样式
   - AppBar标题显示当前经文名称

5. 切换页面：
   - 切换底部导航栏可查看不同页面（经文/讨论）

## 所有颜色格式

所有颜色均使用 `Color(0xFFxxxxxx)` 格式，确保主题一致性。
