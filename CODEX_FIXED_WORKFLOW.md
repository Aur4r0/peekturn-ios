# 双 Codex 固定开发流程

本流程适用于使用两个 Codex 会话协作开发的 Git 项目：

- Builder：实现功能、编写测试、提交代码。
- Reviewer：审查固定提交、运行验证、给出通过或退回结论。
- main：只保存已审查并批准的提交。

核心原则：Reviewer 审查 Git 提交 SHA，不审查会继续变化的分支或未提交工作区。

## 一、角色和目录

建议准备三个工作树：

    <project>/                 main 工作树，只用于查看和合并
    <project>-builder-<name>/  Builder 工作树，用于开发
    <project>-reviewer-<sha>/  Reviewer 工作树，detached 状态

每个完整功能使用一个独立 feature 分支和一个独立 Builder worktree。小范围的连续修改可以包含多个提交，但交给 Reviewer 后必须固定一个最终 SHA。

推荐命名：

    feat/<功能名称>
    fix/<问题名称>
    refactor/<重构名称>
    docs/<文档名称>

不要长期复用已经完成的 feature 分支。Reviewer worktree 建议使用短 SHA 命名，避免误用旧提交。

## 二、一次开发周期

### 1. 记录基线

在 main 工作树执行：

    cd <PROJECT_MAIN>

    git fetch origin
    test -z "$(git status --porcelain)"
    test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"

    BASE_SHA="$(git rev-parse HEAD)"
    echo "$BASE_SHA"

如果工作区不干净，或本地 main 没有与远程 main 同步，先处理这些问题，不要开始新功能。

### 2. 创建 Builder 分支和 worktree

    FEATURE=<功能名称>
    BUILDER=<PROJECT>-builder-<功能名称>

    cd <PROJECT_MAIN>
    git worktree add "$BUILDER" -b "feat/$FEATURE" origin/main
    git -C "$BUILDER" push -u origin "feat/$FEATURE"

### 3. Builder 开发

Builder 只修改自己的 worktree，并遵守以下要求：

- 先明确功能范围、验收标准和不包含的内容。
- 先阅读相关代码和文档，再制定修改计划。
- 为纯逻辑、数据处理和失败场景添加测试。
- UI 功能补充必要的模拟器或真机验证。
- 不修改 main 工作树。
- 不把临时文件、凭据或本地配置提交到 Git。
- 不在交接后继续修改已交接的提交。

### 4. Builder 交接

Builder 在提交前执行：

    cd <BUILDER>

    git status --short --branch
    git diff --check
    <项目验证命令>

    git add <本次功能涉及的文件>
    git diff --cached --check
    git commit -m "<清晰的提交信息>"
    git push origin <功能分支>

    REVIEW_SHA="$(git rev-parse HEAD)"
    git status --short --branch
    printf 'REVIEW_SHA=%s\n' "$REVIEW_SHA"

交接信息至少包含：

    功能名称：
    基线 SHA：
    审查 SHA：
    功能分支：
    变更范围：
    不包含内容：
    验证命令：
    验证结果：
    工作区状态：

交接后禁止对该 SHA 执行 amend、rebase、reset 或强制推送。需要修复时，创建新提交并使用新 SHA 重新审查。

### 5. Reviewer 创建固定 worktree

    REVIEW_SHA=<Builder 交接的完整 SHA>
    REVIEWER=<PROJECT>-reviewer-<短 SHA>

    cd <PROJECT_MAIN>
    git worktree add --detach "$REVIEWER" "$REVIEW_SHA"

    test "$(git -C "$REVIEWER" rev-parse HEAD)" = "$REVIEW_SHA"
    test -z "$(git -C "$REVIEWER" status --porcelain)"
    git -C "$REVIEWER" diff --check
    git -C "$REVIEWER" diff --stat "<BASE_SHA>..$REVIEW_SHA"

Reviewer 只审查这个固定 SHA，不跟随 Builder 分支后续变化。

### 6. Reviewer 审查和验证

Reviewer 至少检查：

- 功能是否符合本轮范围和验收标准。
- 是否引入明显的逻辑、数据一致性或权限问题。
- 异常、失败、空数据和边界条件是否处理。
- 测试是否覆盖关键逻辑。
- 构建、单元测试和受影响的 UI 测试是否实际执行。
- git diff --check 是否通过。
- 验证结果是否准确记录实际环境和限制。

Reviewer 结论必须包含：

    审查对象：<完整 SHA>
    审查结果：通过 / 退回
    工作树 HEAD：
    工作区状态：
    变更检查：
    验证命令：
    验证结果：
    问题清单：
    合并建议：

### 7. 退回处理

Reviewer 退回时：

1. Builder 在原功能分支上修复。
2. 创建新的提交。
3. 推送新的功能分支状态。
4. 把新的完整 SHA 交给 Reviewer。
5. Reviewer 创建新的 detached worktree，重新审查。

禁止修改已经被 Reviewer 审查过的旧 SHA。

### 8. 合并到 main

只有 Reviewer 明确通过后，才能合并：

    REVIEW_SHA=<Reviewer 已通过的完整 SHA>
    BASE_SHA=<本轮记录的基线 SHA>

    cd <PROJECT_MAIN>
    git fetch origin

    test -z "$(git status --porcelain)"
    test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
    test "$(git rev-parse HEAD)" = "$BASE_SHA"
    git merge-base --is-ancestor "$BASE_SHA" "$REVIEW_SHA"

    git merge --ff-only "$REVIEW_SHA"
    git push origin main

如果任一检查失败，停止合并并重新确认基线、审查对象和远程状态。不要直接合并移动中的 feature 分支。

### 9. 合并后检查和清理

    cd <PROJECT_MAIN>
    git status --short --branch
    git log --oneline --decorate -5
    git ls-remote --heads origin main

确认远程 main 指向 Reviewer 批准的 SHA 后，再决定是否清理：

    git worktree remove <当前 Reviewer worktree>
    git worktree prune
    git push origin --delete <功能分支>

历史证据仍有价值时，保留旧 Reviewer worktree 和功能分支。

## 三、两个 Codex 会话之间的交接

Codex 会话之间不依赖复制完整对话内容。推荐只传递以下固定信息：

    仓库路径：
    基线 SHA：
    审查 SHA：
    功能分支：
    功能范围：
    验收标准：
    验证命令及结果：

Git 提交 SHA 是交接的唯一事实来源。分支名称、对话内容和口头描述都不能替代 SHA 校验。

## 四、验证记录要求

报告验证结果时，准确写出：

- 实际运行的命令。
- 实际使用的模拟器或真机。
- 通过了哪些单元测试和 UI 测试。
- 哪些测试因为环境原因未执行。
- 是否存在 CoreSimulator、签名、依赖或网络限制。

构建通过不等于测试通过，单元测试通过不等于真实设备验证通过。任何未执行的检查都必须明确标注。

## 五、固定协作循环

    确定功能范围
    → 记录 main 基线
    → 创建 Builder 分支和 worktree
    → Builder 开发并测试
    → 提交固定 SHA
    → Reviewer detached 审查固定 SHA
    → 退回则创建新提交并重新审查
    → 通过则 fast-forward 合并 main
    → 推送 main
    → 验证远程状态
    → 开始下一项功能
