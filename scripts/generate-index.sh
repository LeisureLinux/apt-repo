#!/bin/bash
# generate-index.sh: 从 aptly 发布产物（.aptly/public）自动生成
#   1) 根 index.html   —— 可用软件包列表（自动更新）
#   2) dists/index.html —— 指向各发行版/架构索引
#   3) pool/index.html  —— 指向各包的 .deb 文件
# 这样 GitHub Pages 上 /dists/ 和 /pool/ 不再 404。
set -euo pipefail
cd "$(dirname "$0")/.."
PUBDIR="$PWD/.aptly/public"

[[ -d "$PUBDIR/dists" ]] || { echo "❌ 未找到 $PUBDIR/dists，请先运行 scripts/publish.sh"; exit 1; }

# ---- 用 jq 组装包列表（从 bookworm 的 amd64 Packages 读取，版本去重取最新） ----
PKG_JSON="$PUBDIR/.pkgs.json"
PKGS=$(find "$PUBDIR/dists" -path "*/main/binary-amd64/Packages" | head -1)
if [[ -z "$PKGS" ]]; then
    echo "❌ 找不到 binary-amd64/Packages，无法生成包列表"
    exit 1
fi

# 解析 Packages（字段用单个空行分隔）→ JSON 数组
awk -v RS='' -v FS='\n' '
  {
    pkg=""; ver=""; arch=""; desc=""; filename=""
    for (i=1;i<=NF;i++) {
      if ($i ~ /^Package: /) pkg=substr($i,10)
      else if ($i ~ /^Version: /) ver=substr($i,10)
      else if ($i ~ /^Architecture: /) arch=substr($i,15)
      else if ($i ~ /^Description: /) desc=substr($i,14)
      else if ($i ~ /^Filename: /) filename=substr($i,11)
    }
    if (pkg != "") {
      # 用 gsub 转义 JSON 特殊字符
      gsub(/\\/,"\\\\",desc); gsub(/"/,"\\\"",desc)
      printf "%s|%s|%s|%s|%s\n", pkg, ver, arch, filename, desc
    }
  }
' "$PKGS" > "$PUBDIR/.pkgs.txt"

# 聚合：每个包名收集 (ver, arch)，版本号取最高的
jq -Rs '
  split("\n")
  | map(select(length>0))
  | map(split("|") | {pkg:.[0], ver:.[1], arch:.[2], file:.[3], desc:.[4]})
  | group_by(.pkg)
  | map({
      name: .[0].pkg,
      desc: (.[0].desc // ""),
      arches: ([.[].arch] | unique | sort | join(" ")),
      versions: ([.[] | {v:.ver, file:.file}] | unique_by(.v))
    })
  | sort_by(.name)
' "$PUBDIR/.pkgs.txt" > "$PKG_JSON"

# ---- 生成 HTML 片段 ----
PKG_HTML=""
BODY_HTML=""
while IFS= read -r pkg; do
  name=$(echo "$pkg" | jq -r '.name')
  desc=$(echo "$pkg" | jq -r '.desc')
  arches=$(echo "$pkg" | jq -r '.arches')
  PKG_HTML+="    <div class=\"pkg\"><span><span class=\"name\">${name}</span> <span class=\"badge\">${arches}</span></span><span class=\"desc\">${desc}</span></div>\n"
done < <(jq -c '.[]' "$PKG_JSON")

# 生成 pool 索引（列出所有 .deb）
POOL_HTML=""
while IFS= read -r file; do
  POOL_HTML+="    <div class=\"pkg\"><a href=\"/${file}\">${file}</a></div>\n"
done < <(find "$PUBDIR/pool" -name '*.deb' | sed "s|$PUBDIR/||" | sort)

# 生成 dists 索引（列出发行版 + 架构）
DISTS_HTML=""
for distdir in "$PUBDIR"/dists/*/; do
  [[ -d "$distdir" ]] || continue
  dist=$(basename "$distdir")
  archs=$(ls -d "$distdir"/main/binary-* 2>/dev/null | sed 's|.*binary-||' | paste -sd' ' -)
  DISTS_HTML+="    <div class=\"pkg\"><span class=\"name\">${dist}</span> <span class=\"badge\">${archs}</span> <a href=\"/dists/${dist}/\">索引</a></div>\n"
done

# ---- 支持的发行版说明（供首页展示） ----
# 用 shell 关联数组描述 codename → 系统名（未列出的照旧显示 codename 本身）
declare -A DIST_LABEL=(
  [bookworm]="Debian 12 (bookworm)"
  [trixie]="Debian 13 (trixie)"
  [bullseye]="Debian 11 (bullseye)"
  [buster]="Debian 10 (buster)"
  [jammy]="Ubuntu 22.04 LTS (jammy)"
  [noble]="Ubuntu 24.04 LTS (noble)"
  [resolute]="Ubuntu 26.04 (resolute)"
  [questing]="Ubuntu 25.10 (questing)"
)
DIST_INFO=""
for distdir in "$PUBDIR"/dists/*/; do
  [[ -d "$distdir" ]] || continue
  dist=$(basename "$distdir")
  label="${DIST_LABEL[$dist]:-$dist}"
  DIST_INFO+="    <div class=\"pkg\"><span class=\"name\">${label}</span></div>\n"
done

# ---- 自动取当前系统发行版代号；取不到/未发布则回退 bookworm ----
OS_CODENAME=""
[[ -f /etc/os-release ]] && OS_CODENAME="$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2)"
if [[ -z "$OS_CODENAME" || ! -d "$PUBDIR/dists/$OS_CODENAME" ]]; then
    OS_CODENAME="$(basename "$(find "$PUBDIR/dists" -maxdepth 1 -mindepth 1 -type d | head -1)")"
fi
OS_CODENAME="${OS_CODENAME:-bookworm}"
cat > "$PUBDIR/index.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Freelamp APT Repository</title>
<style>
  :root { --bg:#0f1115; --card:#171a21; --fg:#e6e8ee; --muted:#9aa3b2; --accent:#4f8cff; --border:#262c38; }
  * { box-sizing:border-box; margin:0; padding:0; }
  body { background:var(--bg); color:var(--fg); font:16px/1.6 system-ui,-apple-system,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif; padding:3rem 1rem; }
  .wrap { max-width:860px; margin:0 auto; }
  h1 { font-size:1.8rem; margin-bottom:.3rem; }
  h1 code { color:var(--accent); }
  .sub { color:var(--muted); margin-bottom:2rem; }
  .card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:1.4rem 1.6rem; margin-bottom:1.4rem; }
  h2 { font-size:1.1rem; margin-bottom:.8rem; color:var(--accent); }
  pre { background:#0b0d12; border:1px solid var(--border); border-radius:8px; padding:1rem; overflow-x:auto; font-size:.85rem; }
  code { font-family:ui-monospace,SFMono-Regular,Consolas,monospace; }
  .pkg { display:flex; justify-content:space-between; align-items:center; gap:1rem; padding:.5rem 0; border-bottom:1px dashed var(--border); flex-wrap:wrap; }
  .pkg:last-child { border-bottom:none; }
  .pkg .name { font-weight:600; }
  .pkg .desc { color:var(--muted); font-size:.9rem; }
  a { color:var(--accent); }
  .badge { display:inline-block; background:#1c2433; border:1px solid var(--border); color:var(--muted); border-radius:999px; padding:.1rem .6rem; font-size:.78rem; }
  footer { color:var(--muted); font-size:.85rem; margin-top:2rem; }
</style>
</head>
<body>
<div class="wrap">
  <h1>Freelamp <code>APT</code> Repository</h1>
  <p class="sub">LeisureLinux 的 Debian / Ubuntu 软件源 · GitHub Pages 托管 · GPG 签名</p>

  <div class="card">
    <h2>添加软件源</h2>
    <pre># 自动读取当前系统发行版代号（如 trixie / bookworm / noble）
codename=\$(grep -oP '^VERSION_CODENAME=\K.*' /etc/os-release)

# 安装签名公钥
curl -fsSL https://repo.freelamp.com/apt.key | sudo gpg --dearmor -o /usr/share/keyrings/freelamp.gpg

# ── 方式一：deb822 格式（Debian 12+ / Ubuntu 22.04+）──
sudo tee /etc/apt/sources.list.d/freelamp.sources >/dev/null &lt;&lt;SOURCE_EOF
Types: deb
URIs: https://repo.freelamp.com
Suites: \$codename
Components: main
Signed-By: /usr/share/keyrings/freelamp.gpg
SOURCE_EOF

# ── 方式二：传统一行格式（所有版本都支持）──
echo &quot;deb [signed-by=/usr/share/keyrings/freelamp.gpg] https://repo.freelamp.com \$codename main&quot; \
  | sudo tee /etc/apt/sources.list.d/freelamp.list

sudo apt update</pre>
  </div>

  <div class="card">
    <h2>可用软件包</h2>
$(echo -e "$PKG_HTML")
    <p style="margin-top:.8rem;color:var(--muted);font-size:.9rem">版本随项目发版自动更新（CI 自动同步）。安装：<code>sudo apt install &lt;包名&gt;</code></p>
  </div>

  <div class="card">
    <h2>支持的发行版 / 套件</h2>
$(echo -e "$DIST_INFO")
    <p style="margin-top:.8rem;color:var(--muted);font-size:.9rem">同一批 Go 静态二进制包发布到以上所有套件，任选与你的系统匹配的 <code>Suites:</code> 即可。</p>
  </div>

  <div class="card" style="border-color:#8a5a00;background:#1c1710;">
    <h2 style="color:#e8a33d;">⚠️ 使用警告</h2>
    <p>本仓库为 <strong>第三方社区源</strong>，非官方 Debian / Ubuntu 软件源。包由项目作者或本仓库维护者编译，未经过官方安全审计。</p>
    <ul style="margin:.6rem 0 0 1.2rem;color:var(--fg);">
      <li>安装即表示你自行承担风险（<code>at your own risk</code>）。</li>
      <li>安装前请核对软件包来源、校验 GPG 签名、并备份重要数据。</li>
      <li>仅在你信任维护者且了解用途的前提下使用。</li>
    </ul>
  </div>

  <div class="card">
    <h2>链接</h2>
    <p>签名公钥：<a href="/apt.key">apt.key</a> · 索引结构：<a href="/dists/">dists/</a> · 包文件：<a href="/pool/">pool/</a></p>
  </div>

  <footer>源码与发布脚本：github.com/LeisureLinux/apt-repo · 由 aptly 生成并 GPG 签名 · 包列表自动更新</footer>
</div>
</body>
</html>
HTML

# ---- dists/index.html ----
mkdir -p "$PUBDIR/dists"
cat > "$PUBDIR/dists/index.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>dists/ - Freelamp APT Repository</title>
<style>body{background:#0f1115;color:#e6e8ee;font:16px/1.6 system-ui,sans-serif;padding:2rem}.wrap{max-width:860px;margin:0 auto}h1{color:#4f8cff}.pkg{display:flex;gap:1rem;padding:.5rem 0;border-bottom:1px dashed #262c38;flex-wrap:wrap}.name{font-weight:600}.badge{background:#1c2433;border:1px solid #262c38;color:#9aa3b2;border-radius:999px;padding:.1rem .6rem;font-size:.78rem}a{color:#4f8cff}</style>
</head>
<body><div class="wrap">
<h1>dists/</h1>
<p style="color:#9aa3b2">各 Debian/Ubuntu 发行版仓库索引</p>
$(echo -e "$DISTS_HTML")
</div></body></html>
HTML


# ---- dists/<dist>/index.html（每个发行版的组件/架构入口） ----
for distdir in "$PUBDIR"/dists/*/; do
  [[ -d "$distdir" ]] || continue
  dist=$(basename "$distdir")
  comps=""
  for cdir in "$distdir"/*/; do
    [[ -d "$cdir" ]] || continue
    [[ -n "$(ls -d "$cdir"/binary-* 2>/dev/null | head -1)" ]] || continue
    comp=$(basename "$cdir")
    archs=$(ls -d "$cdir"/binary-* 2>/dev/null | sed 's|.*binary-||' | paste -sd' ' -)
    comps+="    <div class=\"pkg\"><span class=\"name\">${comp}</span> <span class=\"badge\">${archs}</span></div>\n"
  done
  mkdir -p "$distdir"
  cat > "$distdir/index.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>dists/${dist}/ - Freelamp APT Repository</title>
<style>body{background:#0f1115;color:#e6e8ee;font:16px/1.6 system-ui,sans-serif;padding:2rem}.wrap{max-width:860px;margin:0 auto}h1{color:#4f8cff}.pkg{display:flex;gap:1rem;padding:.5rem 0;border-bottom:1px dashed #262c38;flex-wrap:wrap}.name{font-weight:600}.badge{background:#1c2433;border:1px solid #262c38;color:#9aa3b2;border-radius:999px;padding:.1rem .6rem;font-size:.78rem}a{color:#4f8cff}</style>
</head>
<body><div class="wrap">
<h1>dists/${dist}/</h1>
<p style="color:#9aa3b2">${dist} 仓库组件与架构</p>
$(echo -e "$comps")
</div></body></html>
HTML
done

# ---- pool/index.html ----

mkdir -p "$PUBDIR/pool"
cat > "$PUBDIR/pool/index.html" <<HTML
<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>pool/ - Freelamp APT Repository</title>
<style>body{background:#0f1115;color:#e6e8ee;font:16px/1.6 system-ui,sans-serif;padding:2rem}.wrap{max-width:860px;margin:0 auto}h1{color:#4f8cff}.pkg{padding:.3rem 0;border-bottom:1px dashed #262c38}a{color:#4f8cff}</style>
</head>
<body><div class="wrap">
<h1>pool/</h1>
<p style="color:#9aa3b2">所有 .deb 包文件</p>
$(echo -e "$POOL_HTML")
</div></body></html>
HTML

rm -f "$PUBDIR/.pkgs.txt" "$PUBDIR/.pkgs.json"
echo "✅ 已生成 index.html / dists/index.html / pool/index.html"
ls -la "$PUBDIR"/index.html "$PUBDIR"/dists/index.html "$PUBDIR"/pool/index.html
