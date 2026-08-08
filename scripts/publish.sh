#!/bin/bash
# 用 aptly 生成 APT 仓库：
#   incoming/*.deb  → aptly repo → snapshot → 发布到 conf/distros.txt 里的每个发行版
# 产物输出到 .aptly/public/（即将来 gh-pages 分支的内容）
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# --- 生成 aptly 配置（rootDir 指向仓库内 .aptly，随机器移动也不怕） ---
sed "s|__ROOT__|$ROOT|g" conf/aptly.conf.tpl > aptly.conf
CFG="$ROOT/aptly.conf"
APTLY="${APTLY:-aptly}"
command -v "$APTLY" >/dev/null || { echo "❌ 未找到 aptly，请安装或设置 APTLY 环境变量"; exit 1; }
# 注意：aptly 1.5 不认 APTLY_CONFIG 环境变量，统一用 -config 参数
apt() { "$APTLY" -config="$CFG" "$@"; }

# --- 确保签名密钥（KEYID 从 init-gpg.sh 输出解析） ---
KEYID="$(bash scripts/init-gpg.sh | sed -n 's/^KEYID=//p' | tail -1)"

# --- 检查待入库包 ---
shopt -s nullglob
DEBS=("$ROOT"/incoming/*.deb)
if [[ ${#DEBS[@]} -eq 0 ]]; then
    echo "❌ incoming/ 下没有 .deb"
    echo "   放入 .deb 后重试，或用 debs.list + CI 自动拉取"
    exit 1
fi
echo "📦 待入库 ${#DEBS[@]} 个包:"
for d in "${DEBS[@]}"; do basename "$d"; done

# --- 创建/复用 aptly 仓库（组件 main） ---
if ! apt repo show freelamp >/dev/null 2>&1; then
    apt repo create -distribution=bookworm -component=main freelamp >/dev/null
fi

# --- 入库（增量累积：只加不删，多个项目的包共存） ---
# 如需彻底移除某个包，需在本地用 aptly 手工清理（aptly repo remove + 重新发布）
apt repo add freelamp "${DEBS[@]}"

# --- 打快照 ---
SNAP="freelamp-$(date +%Y%m%d%H%M%S)"
echo "📸 快照: $SNAP"
apt snapshot create "$SNAP" from repo freelamp

# --- 发布/更新到每个发行版 ---
while read -r distro; do
    [[ -z "$distro" || "$distro" == \#* ]] && continue
    if apt publish show "$distro" >/dev/null 2>&1; then
        echo "🔄 更新发行版 $distro ..."
        apt publish switch -gpg-key="$KEYID" "$distro" "$SNAP"
    else
        echo "🚀 首次发布 $distro ..."
        apt publish snapshot -gpg-key="$KEYID" -distribution="$distro" -component=main "$SNAP"
    fi
done < conf/distros.txt

# --- 写入 CNAME（自定义域名）与公钥，方便直接部署 ---
mkdir -p .aptly/public
cp CNAME .aptly/public/CNAME
cp keys/apt.key .aptly/public/apt.key
cp index.html .aptly/public/index.html

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 发布完成，产物在 .aptly/public/"
echo "   本地预览:  cd .aptly/public && python3 -m http.server 8080"
echo "   部署到 GitHub Pages: bash scripts/deploy-ghpages.sh"
apt publish list
