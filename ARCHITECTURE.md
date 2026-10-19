# Peekturn iOS Architecture

## Current status

当前项目是 Xcode 创建的 SwiftUI 初始项目，包含：

- App 入口
- `ContentView`
- 单元测试目标
- UI 测试目标

后续按 MVP 逐步增加模块。

## Target structure

```text
peekturn-ios/
├── Domain/
├── Data/
├── Reader/
├── Learning/
├── Speech/
└── UI/
```

## Layer ownership

### Domain

负责稳定的数据模型和纯业务规则。

示例：

- `Book`
- `ReadingPosition`
- `ReaderPreferences`
- EPUB 导入结果
- 阅读进度计算

Domain 不依赖 SwiftUI、数据库或网络框架。

### Data

负责本地数据和持久化。

示例：

- EPUB 文件复制和删除
- 书籍元数据保存
- 阅读位置保存
- 阅读统计保存
- 用户设置
- Keychain 凭据

界面不能直接访问数据库或文件系统，应通过 Repository 获取数据。

### Reader

负责 EPUB 阅读器集成。

示例：

- 打开 EPUB
- 创建阅读器
- 获取当前阅读位置
- 恢复阅读位置
- 处理阅读器回调

EPUB 阅读内核通过适配器接入，避免让业务代码依赖具体框架细节。

### Learning

负责阅读辅助能力。

示例：

- 选中文本
- 构造上下文
- 离线词典
- AI 请求
- 流式响应解析
- 解释结果校验
- 解释缓存

### Speech

负责发音和连续朗读。

示例：

- 单词发音
- 例句发音
- 句子切分
- 音频播放
- 播放状态
- 后台播放

### UI

负责 SwiftUI 界面。

示例：

- 书库页面
- 阅读页面容器
- 设置页面
- 解释弹窗
- 错误提示
- 加载状态

UI 只消费状态并发送用户操作，不负责业务规则和数据持久化。

## Main data flows

### Import flow

```text
Document Picker
    ↓
BookImporter
    ↓
Private Book Storage
    ↓
BookRepository
    ↓
Library State
    ↓
Library View
```

### Reading flow

```text
Library View
    ↓
Reader ViewModel
    ↓
EpubEngineAdapter
    ↓
EPUB Reader
```

### Position flow

```text
Reader reports current locator
    ↓
Reader ViewModel
    ↓
BookRepository
    ↓
Local Storage
```

### Learning flow

```text
Native selection
    ↓
LookupContext
    ↓
Dictionary or ExplanationClient
    ↓
Validated Explanation
    ↓
Learning Popup
```

## Important decisions

- 书籍文件存放在 App 私有目录。
- 书籍元数据和阅读位置与 EPUB 文件分开保存。
- 阅读位置使用阅读器提供的稳定 locator，不使用固定页码作为唯一依据。
- API Key 使用 Keychain 保存。
- 解释缓存不保存私人凭据。
- 网络请求、解析和 UI 显示分开实现。
- 外部服务失败时，界面必须显示真实失败状态，不能展示假答案。

## Testing strategy

- Domain：测试纯函数和数据转换。
- Data：测试导入、保存、读取、删除和失败清理。
- Reader：测试位置保存和恢复。
- Learning：测试上下文裁剪、响应解析、错误和缓存。
- UI：测试关键页面能够启动和完成主要交互。
- 真机或模拟器：验证 EPUB 打开、阅读位置恢复和真实界面行为。

### UI design system

UI 使用统一的设计令牌和可复用组件，避免每个页面单独决定视觉样式。

设计令牌至少包括：

- 颜色角色：背景、表面、主要文字、次要文字、强调色、错误色和边框色。
- 字体层级：页面标题、章节标题、正文、辅助信息和按钮文字。
- 间距层级：页面边距、区块间距、列表间距和控件内部间距。
- 形状规则：卡片、按钮、输入框和弹窗的圆角与边框。
- 阴影和层级：只在确实需要区分层级时使用。
- 图标规则：保持尺寸、笔画和语义一致。

界面设计原则：

- 阅读内容优先，功能控件保持克制。
- 优先使用原生 SwiftUI 组件和系统交互。
- 页面必须考虑浅色、深色、动态字体和小屏幕。
- 状态必须完整，包括加载、空状态、错误、禁用和完成。
- UI 层只负责展示状态，视觉规则集中在主题和可复用组件中。
