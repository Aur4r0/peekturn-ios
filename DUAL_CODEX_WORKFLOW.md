# 双 Codex Git Worktree 协作流程

## 角色

- Builder：在 `feat/ios-reader-next` 工作树中实现一个明确范围的功能，提交后交接固定 SHA。
- Reviewer：从固定 SHA 创建独立 detached worktree，审查代码、运行验证，并决定是否合并。
- `main`：只在 Reviewer 批准后更新，不作为 Builder 的编辑目录。

## 一次协作的安全顺序

### 1. 记录基线

在 `/Users/aur4r0/VibeCodeProject/peekturn-ios` 中确认主工作树干净，并记录：

```sh
BASE_SHA="$(git rev-parse main)"
git status --short
printf '%s\n' "$BASE_SHA"
```

基线记录后，Builder 和 Reviewer 都不应修改 `main`。

### 2. Builder 实现并交接

Builder 只在 `/Users/aur4r0/VibeCodeProject/peekturn-ios-builder` 中工作：

```sh
git status --short --branch
git diff --check
./scripts/verify.sh
git add <本次功能涉及的文件>
git diff --cached --check
git commit -m "<功能提交信息>"
REVIEW_SHA="$(git rev-parse HEAD)"
git status --short
printf '%s\n' "$REVIEW_SHA"
```

交接后不得 amend、rebase 或继续修改该 SHA。需要修复时，应创建新提交并重新交接。

### 3. Reviewer 固定审查

Reviewer 从完整 SHA 创建 detached worktree：

```sh
git worktree add --detach /Users/aur4r0/VibeCodeProject/peekturn-ios-reviewer "$REVIEW_SHA"
cd /Users/aur4r0/VibeCodeProject/peekturn-ios-reviewer
test "$(git rev-parse HEAD)" = "$REVIEW_SHA"
git status --short --branch
git diff --stat "$BASE_SHA..$REVIEW_SHA"
git diff --check "$BASE_SHA..$REVIEW_SHA"
./scripts/verify.sh
```

Reviewer 的结论必须绑定 `REVIEW_SHA`。Builder 分支后续移动不会改变本次审查对象。

### 4. Reviewer 合并

Reviewer 批准后回到 `/Users/aur4r0/VibeCodeProject/peekturn-ios`：

```sh
test -z "$(git status --porcelain)"
test "$(git rev-parse main)" = "$BASE_SHA"
git merge-base --is-ancestor "$BASE_SHA" "$REVIEW_SHA"
git merge --ff-only "$REVIEW_SHA"
```

任一前置检查失败，说明基线或审查对象发生变化，应停止合并并重新审查。不要直接合并移动中的 `feat/ios-reader-next`。

## 当前项目的审查重点

本项目的 EPUB 导入实现包含手写 ZIP 和 XML 解析，Reviewer 需要重点检查：

- 畸形压缩包、异常压缩尺寸和资源消耗限制。
- 临时文件、最终文件和 `library.json` 的失败清理与一致性。
- EPUB 文件名的路径校验。
- App 重启后的书库读取。
- 导入失败、保存失败和删除失败时的真实错误状态。
- 实现范围是否与 `SPEC.md` 中本次功能的验收标准一致。
