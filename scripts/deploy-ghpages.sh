#!/bin/bash
# 把 .aptly/public 的内容推送到 gh-pages 分支（适合本地手动部署）。
# 注意：会强制改写 gh-pages 历史；先 commit 本地改动再运行。
set -euo pipefail
cd "$(dirname "$0")/.."
PUBDIR="$PWD/.aptly/public"

[[ -d "$PUBDIR/dists" ]] || { echo "❌ 未找到 .aptly/public/dists，请先运行 scripts/publish.sh"; exit 1; }
[[ -n "$(git remote -v)" ]] || { echo "❌ 还没有 git remote，先创建 GitHub 仓库并 git remote add origin ..."; exit 1; }

# 确保在干净的 main 上
git checkout main

# 创建/切到 gh-pages 孤儿分支
if git show-ref --verify --quiet refs/heads/gh-pages; then
    git checkout gh-pages
else
    git checkout --orphan gh-pages
fi
git rm -rf . >/dev/null 2>&1 || true

cp -a "$PUBDIR"/. .
git add -A
git commit -m "Update APT repo $(date +%Y-%m-%d)" || echo "没有变更，跳过提交"
git push -f origin gh-pages

git checkout main
echo "✅ 已部署到 gh-pages，等待 GitHub Pages 生效: https://repo.freelamp.com/"
