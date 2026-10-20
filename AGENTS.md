# Peekturn iOS Agent Instructions

## Project

Peekturn iOS 是一个帮助用户持续阅读英文 EPUB 原著的 iOS 阅读器。

当前项目处于 SwiftUI 初始模板阶段，后续按小功能逐步实现。

## Work boundaries

- 首版优先实现本地 EPUB 导入、书库、阅读和阅读位置恢复。
- 不要一开始实现 AI、连续朗读、网页导入、云同步和账号系统。
- 不要自行实现 EPUB 分页器，优先使用成熟的 EPUB 阅读内核。
- 不复用其他项目的代码、资源或私有数据。
- 正式界面必须展示真实的本地数据和真实的服务结果。
- 不使用假书籍、假答案或虚构的阅读统计。
- API Key、私人书籍内容和临时验证文件不能进入 Git 或普通日志。

## Code structure

采用分层结构：

- `Domain/`：纯数据模型、规则和数据转换。
- `Data/`：文件、数据库、设置和凭据。
- `Reader/`：EPUB 阅读内核和阅读位置。
- `Learning/`：词典、AI 解释和解释缓存。
- `Speech/`：单词、例句和句子朗读。
- `UI/`：SwiftUI 页面和界面状态。

规则：

- SwiftUI View 只负责显示界面和接收用户操作。
- View 不直接操作数据库、文件或网络请求。
- 复杂解析和业务规则放在独立类型中。
- 外部框架通过适配器接入。
- 同一条规则只能有一个实现。
- 一次改动尽量只涉及一个层级。
- 优先拆分小而清晰的类型，避免巨型 View 或巨型 ViewModel。

## Verification

- 纯规则和数据转换必须有单元测试。
- Repository 必须测试保存、读取和失败情况。
- UI 行为必须在 iOS 模拟器或真机上验证。
- 普通改动只运行受影响的测试。
- 大型重构才运行完整测试套件。
- 报告验证结果时，必须准确说明实际运行了哪些检查。
- 不能把单元测试通过描述成真实设备验证通过。

常用检查：

```sh
xcodebuild -project peekturn-ios.xcodeproj \
  -scheme peekturn-ios \
  -destination 'platform=iOS Simulator,name=<可用模拟器>' \
  test
```

## Change workflow

每个功能按以下顺序完成：

1. 明确功能目标和不包含的内容。
2. 先阅读相关代码和架构文档。
3. 让 AI 提出修改计划。
4. 先实现纯逻辑和数据结构。
5. 添加定向测试。
6. 接入 SwiftUI 或系统能力。
7. 在模拟器或真机验证。
8. 更新相关文档。

## Dual-Codex Git Worktree Workflow

本项目使用两个独立的 Codex 会话协作：Builder 编写代码，Reviewer 审查固定提交并负责合并。

### Worktree ownership

- 主工作树 `/Users/aur4r0/VibeCodeProject/peekturn-ios` 只用于 `main` 和最终合并。
- Builder 工作树 `/Users/aur4r0/VibeCodeProject/peekturn-ios-builder` 只用于 `feat/ios-reader-next`。
- Reviewer 必须从完整提交 SHA 创建 detached worktree，不直接审查 Builder 的未提交工作树。
- Builder 不得修改 `main`，Reviewer 未批准前不得合并或推送。

### Handoff rules

1. Builder 完成一个可交付范围后，先运行受影响测试和 `git diff --check`。
2. Builder 提交后输出完整 SHA、变更范围、验证命令和结果。
3. 输出 SHA 后，Builder 不得 amend、rebase 或继续修改该提交。
4. Reviewer 只审查该 SHA。需要修复时，Builder 创建新提交，Reviewer 重新审查新 SHA。
5. Reviewer 批准后，只能将已审查的 SHA 合并到 `main`。禁止直接合并可能继续移动的 feature 分支。

### Merge gate

合并前必须确认：

- 主工作树无未提交修改。
- `main` 仍然是 Builder 开始时记录的基线。
- Reviewer worktree 的 `HEAD` 等于交接时的完整 SHA。
- 构建、单元测试和受影响的 UI 测试均已在该 SHA 上完成。
- 合并使用 `git merge --ff-only <reviewed-sha>`；无法快进时必须重新审查。

### Verification command

Reviewer 可以使用 `scripts/verify.sh` 执行固定的构建和完整测试。模拟器可通过 `DESTINATION` 环境变量覆盖，DerivedData 可通过 `DERIVED_DATA_PATH` 环境变量覆盖。

## UI and visual design

界面应当简洁、好看并具有克制的高级感，优先服务阅读体验，不用装饰堆叠制造复杂感。

- 以阅读内容为视觉中心，减少无关按钮、卡片和装饰元素。
- 使用清晰的视觉层级、充足留白和稳定的间距系统。
- 建立统一的颜色、字体、字号、圆角、阴影和图标规范，不在页面中随意设置样式。
- 配色保持克制，优先使用少量主题色和语义化颜色。
- 避免无必要的渐变、强阴影、过度圆角、复杂背景和动画。
- 重要操作应当容易发现，次要操作保持安静，不与阅读内容竞争注意力。
- 页面应覆盖加载、空状态、错误、禁用和完成状态，不能只设计正常状态。
- 支持浅色、深色、动态字体大小和不同屏幕尺寸，文字不能被截断或遮挡。
- 交互控件应有足够的点击区域、清晰的反馈和合理的可访问性标签。
- 优先使用系统原生交互和 SwiftUI 组件，再通过统一设计令牌调整视觉表现。
- 新增页面前先确认它属于现有设计系统，不要为单个页面创建独立风格。
