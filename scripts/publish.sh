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
DEBS_ALL=("$ROOT"/incoming/*.deb)
if [[ ${#DEBS_ALL[@]} -eq 0 ]]; then
    echo "❌ incoming/ 下没有 .deb"
    echo "   放入 .deb 后重试，或用 debs.list + CI 自动拉取"
    exit 1
fi

# --- 按包名+架构去重：同一包名同一架构只保留版本最高的 .deb ---
# incoming/ 是 git 持久化目录，历史文件会残留；全量加入会让旧版本反复入库。
# 注意键必须是 包名+架构：同包名的 amd64 与 arm64 是两个不同的包，不能互相淘汰。
declare -A BEST=() BEST_VER=() SEEN_NAMES=()
for d in "${DEBS_ALL[@]}"; do
    pname="$(dpkg-deb -f "$d" Package)"
    pver="$(dpkg-deb -f "$d" Version)"
    parch="$(dpkg-deb -f "$d" Architecture)"
    if [[ -z "$pname" ]]; then echo "⚠️  跳过无法解析的包: $d"; continue; fi
    key="${pname}/${parch}"
    if [[ -z "${BEST[$key]:-}" ]] || dpkg --compare-versions "$pver" gt "${BEST_VER[$key]}"; then
        BEST[$key]="$d"; BEST_VER[$key]="$pver"; SEEN_NAMES[$pname]=1
    fi
done
DEBS=()
for d in "${BEST[@]}"; do DEBS+=("$d"); done
echo "📦 待入库 ${#DEBS[@]} 个包（已按 包名+架构 去重，只取最新版本）:"
for d in "${DEBS[@]}"; do basename "$d"; done

# --- 按 XB-Suites 分组：全发行版包 / 限定发行版包 ---
# XB-Suites 是 deb-builder 按 recipe 的 suites 字段写进 control 的自定义字段
# （逗号分隔的 codename，如 "trixie"）。
#   没有该字段 → 发到 conf/distros.txt 里的全部发行版（既有 200+ 个包都是这种）
#   有该字段   → 只发到列出的发行版
# 之所以让它跟着 .deb 走而不是在这里维护名单：只有 recipe（构建端）知道这个包的
# 依赖/内核约束，apt-repo 不必也不该知道 recipe 的存在。
declare -A GROUP_DEBS=()          # suites 组合 → 该组的 .deb（换行分隔）
FULL_DEBS=()                      # 不带 XB-Suites 的包
declare -A INCOMING_NAMES=()      # 包名/架构 → 1，供跨 repo 清理使用
for d in "${DEBS[@]}"; do
    pname="$(dpkg-deb -f "$d" Package)"
    parch="$(dpkg-deb -f "$d" Architecture)"
    INCOMING_NAMES["${pname}/${parch}"]=1
    suites="$(dpkg-deb -f "$d" XB-Suites 2>/dev/null || true)"
    suites="${suites//[[:space:]]/}"          # 去掉全部空白："trixie, bookworm" → "trixie,bookworm"
    if [[ -z "$suites" ]]; then
        FULL_DEBS+=("$d")
    else
        GROUP_DEBS["$suites"]+="${d}"$'\n'
    fi
done

if [[ ${#GROUP_DEBS[@]} -gt 0 ]]; then
    echo "🎯 限定发行版的包:"
    for key in "${!GROUP_DEBS[@]}"; do
        files=""
        while IFS= read -r one; do
            [[ -n "$one" ]] && files+="$(basename "$one") "
        done <<< "${GROUP_DEBS[$key]}"
        printf '   [%s] %s\n' "$key" "${files% }"
    done
fi

# --- 建立/复用一个 aptly repo 并入库 ---
# repo 名：全量用 freelamp（沿用历史名字），限定组用 freelamp-s-<suites>。
# 每个 repo 入库前先移除 incoming 里出现过的所有包名：
#   * 旧版本必须清掉（aptly 以 包名+版本+架构 为主键，不清会残留旧版本）；
#   * 包如果换了分组（比如去掉了 suites），也要从旧 repo 里清出去，否则两个 repo
#     都有它，merge 时会因为同名包冲突而失败。
ingest_repo() {
    local rname="$1"; shift
    local n pname
    if ! apt repo show "$rname" >/dev/null 2>&1; then
        apt repo create -distribution=bookworm -component=main "$rname" >/dev/null
    fi
    for n in "${!INCOMING_NAMES[@]}"; do
        pname="${n%%/*}"
        if apt repo search "$rname" "$pname" 2>/dev/null | grep -q .; then
            if apt repo remove "$rname" "$pname" 2>/dev/null; then
                echo "♻️  $rname: 已移除 $pname 的所有旧版本"
            fi
        fi
    done
    apt repo add "$rname" "$@" >/dev/null
    echo "📥 $rname: 入库 $# 个包"
}

declare -A SNAP_OF=()             # suites 组合 → 快照名
SNAP_TS="$(date +%Y%m%d%H%M%S)"
FULL_SNAP=""
if [[ ${#FULL_DEBS[@]} -gt 0 ]]; then
    ingest_repo freelamp "${FULL_DEBS[@]}"
    FULL_SNAP="freelamp-${SNAP_TS}"
    echo "📸 快照: $FULL_SNAP（全发行版，${#FULL_DEBS[@]} 个包）"
    apt snapshot create "$FULL_SNAP" from repo freelamp >/dev/null
fi

for key in "${!GROUP_DEBS[@]}"; do
    rname="freelamp-s-${key//,/-}"
    group=()
    while IFS= read -r one; do
        [[ -n "$one" ]] && group+=("$one")
    done <<< "${GROUP_DEBS[$key]}"
    [[ ${#group[@]} -eq 0 ]] && continue
    ingest_repo "$rname" "${group[@]}"
    snap="${rname}-${SNAP_TS}"
    echo "📸 快照: $snap（仅 ${key}，${#group[@]} 个包）"
    apt snapshot create "$snap" from repo "$rname" >/dev/null
    SNAP_OF["$key"]="$snap"
done

# --- 发布/更新到每个发行版 ---
# 某个发行版该看到哪些包 = 全量快照 + 所有把该发行版列进 XB-Suites 的快照，
# 用 aptly 的快照合并拼出目标快照。只有一个来源时直接用它，省掉一次 merge。
while read -r distro; do
    [[ -z "$distro" || "$distro" == \#* ]] && continue
    need=()
    [[ -n "$FULL_SNAP" ]] && need+=("$FULL_SNAP")
    for key in "${!SNAP_OF[@]}"; do
        IFS=',' read -ra wanted <<< "$key"
        for w in "${wanted[@]}"; do
            if [[ "$w" == "$distro" ]]; then need+=("${SNAP_OF[$key]}"); break; fi
        done
    done
    if [[ ${#need[@]} -eq 0 ]]; then
        echo "⏭️  跳过 $distro：没有适用于它的包"
        continue
    fi
    target="${need[0]}"
    if [[ ${#need[@]} -gt 1 ]]; then
        target="freelamp-${distro}-${SNAP_TS}"
        echo "🧩 合并快照 → $target（${need[*]}）"
        apt snapshot merge "$target" "${need[@]}" >/dev/null
    fi
    if apt publish show "$distro" >/dev/null 2>&1; then
        echo "🔄 更新发行版 $distro ..."
        apt publish switch -gpg-key="$KEYID" "$distro" "$target"
    else
        echo "🚀 首次发布 $distro ..."
        apt publish snapshot -gpg-key="$KEYID" -distribution="$distro" -component=main "$target"
    fi
done < conf/distros.txt

# --- 写入 CNAME（自定义域名）与公钥，方便直接部署 ---
mkdir -p .aptly/public
cp CNAME .aptly/public/CNAME
cp keys/apt.key .aptly/public/apt.key

# --- 自动生成 index.html / dists/index.html / pool/index.html ---
bash scripts/generate-index.sh

# --- 生成 extrepo 数据源（index.yaml + 签名），随 GitHub Pages 一起发布 ---
bash scripts/generate-extrepo-data.sh

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 发布完成，产物在 .aptly/public/"
echo "   本地预览:  cd .aptly/public && python3 -m http.server 8080"
echo "   部署到 GitHub Pages: bash scripts/deploy-ghpages.sh"
apt publish list


# 注意：incoming/*.deb 绝不能清理！它是本源的全量数据库——
# aptly 状态不持久化，每次发布都用 incoming 里的全部 .deb 重建整个仓库。
# （历史教训：2026-08-25 清理导致线上仓库缩水到 3 个包）
# 旧版本由上面的"按包名 remove 再 add 最新版"机制自然淘汰。
