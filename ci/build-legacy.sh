#!/usr/bin/env bash
# =====================================================================
# electerm legacy 构建脚本 (在 zxdong262/electerm-builder-legacy 容器内运行)
# 用法: bash ci/build-legacy.sh x64 | arm
#   x64 : 构建 x64 的 tar.gz/deb/rpm/AppImage (build-linux-legacy.js)
#   arm : 构建 arm64 + armv7l 的 tar.gz/deb/rpm/AppImage (build-linux-arm-legacy.js)
# 环境变量 (由 workflow 提供):
#   ELECTERM_REF     构建的 ref, 写入 BUILD-INFO.txt
#   MAX_GLIBC        UOS 20 兼容的 glibc 上限 (默认 2.28)
#   MAX_GLIBCXX      UOS 20 兼容的 libstdc++ 符号上限 (默认 3.4.25)
#   USE_SYSTEM_FPM   true 时使用容器内 ruby/fpm 打 deb/rpm
#   KEEP_FILE        true 时每轮 dist 产物改名保留, 不互相覆盖
# 产物: artifacts/ (安装包 + BUILD-INFO.txt + SHA256SUMS.txt)
# 状态: build_status (0=全部成功, 非0=有失败但已产出物仍保留)
# =====================================================================
set -euo pipefail

ARCH_TARGET="${1:-x64}"
WORKSPACE="$(pwd)"
SRC_DIR="$WORKSPACE/build_src"
ART_DIR="$WORKSPACE/artifacts"
STATUS_FILE="$WORKSPACE/build_status"
MAX_GLIBC="${MAX_GLIBC:-2.28}"
MAX_GLIBCXX="${MAX_GLIBCXX:-3.4.25}"

cd "$SRC_DIR"
ELECTERM_VERSION="$(node -p "require('./package.json').version")"

echo "================================================================"
echo "[1/6] 降级依赖版本 (electron 22.3.27 / node-pty 0.10.1 / serialport 10.5.0 / vite 4)"
echo "      原因: UOS 20 / Ubuntu 18 等旧 glibc 系统无法运行新版原生模块"
echo "================================================================"
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.devDependencies.electron = '22.3.27';
pkg.devDependencies['@electron/rebuild'] = '3.7.2';
pkg.dependencies['node-pty'] = '0.10.1';
pkg.dependencies.serialport = '10.5.0';
pkg.devDependencies.vite = '4';
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
"
rm -f package-lock.json

echo "================================================================"
echo "[2/6] 安装 npm 依赖"
echo "================================================================"
npm config set legacy-peer-deps true
npm config set cache /tmp/.npm
npm i
npm i -S @electron/rebuild@3.7.2

echo "================================================================"
echo "[3/6] 编译应用 (npm run b = clean + compile + prepare-file)"
echo "================================================================"
npm run b

echo "================================================================"
echo "[4/6] 准备 electron-builder 配置 (npm run pb)"
echo "================================================================"
npm run pb

echo "================================================================"
echo "[5/6] 构建 legacy 安装包 (tar.gz / deb / rpm / AppImage)"
echo "================================================================"
set +e
case "$ARCH_TARGET" in
  arm)
    node build/bin/build-linux-arm-legacy
    ;;
  x64)
    node build/bin/build-linux-legacy
    ;;
  *)
    echo "未知架构目标: $ARCH_TARGET (可选: x64 | arm)" >&2
    exit 2
    ;;
esac
RC=$?
set -e

echo "================================================================"
echo "[6/6] 汇总产物、校验 glibc 兼容性、生成校验和"
echo "================================================================"
rm -rf "$ART_DIR"
mkdir -p "$ART_DIR"
for d in dist*/; do
  [ -d "$d" ] || continue
  find "$d" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' -o -name '*.AppImage' -o -name '*.tar.gz' \) -exec cp {} "$ART_DIR/" \;
done
cd "$ART_DIR"
find . -maxdepth 1 -type f -exec sha256sum {} \; > SHA256SUMS.txt

# ---- glibc 兼容性静态校验 ----
# 解包每个 tar.gz, 扫描全部 ELF, 只统计"需要(UND)"的版本符号:
#   - GLIBC_ 上限不得超过 MAX_GLIBC (2.28), 否则 UOS 20 / Debian 10 无法加载
#   - GLIBCXX_ 上限不得超过 MAX_GLIBCXX (3.4.25, gcc 8 的 libstdc++)
# 不看库自身导出的版本, 避免 electron 自带 libstdc++ 的高版本导出被误判。
verify_tarball() {
  local tarball="$1" label="$2" rc=0
  local dir="$WORKSPACE/.verify/$label" syms="$WORKSPACE/.verify/$label.symbols"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xzf "$tarball" -C "$dir"
  { find "$dir" -type f -exec readelf --dyn-syms {} \; 2>/dev/null || true; } > "$syms"
  local glibc glibcxx
  glibc="$(awk '$7 == "UND" && $8 ~ /@GLIBC_/ { n=$8; sub(/^.*@GLIBC_/, "", n); if (n ~ /^[0-9]+(\.[0-9]+)*$/) print n }' "$syms" \
    | sort -Vu | tail -n 1)"
  glibcxx="$(awk '$7 == "UND" && $8 ~ /@GLIBCXX_/ { n=$8; sub(/^.*@GLIBCXX_/, "", n); if (n ~ /^[0-9]+(\.[0-9]+)*$/) print n }' "$syms" \
    | sort -Vu | tail -n 1)"
  echo "[verify] $label: required GLIBC_${glibc:-<none>} / GLIBCXX_${glibcxx:-<none>} (ceiling ${MAX_GLIBC} / ${MAX_GLIBCXX})"
  if [ -n "${glibc:-}" ] && [ "$(printf '%s\n' "$MAX_GLIBC" "$glibc" | sort -V | tail -n 1)" != "$MAX_GLIBC" ]; then
    echo "[verify] FAIL: $label requires GLIBC_${glibc} > ${MAX_GLIBC}" >&2
    rc=1
  fi
  if [ -n "${glibcxx:-}" ] && [ "$(printf '%s\n' "$MAX_GLIBCXX" "$glibcxx" | sort -V | tail -n 1)" != "$MAX_GLIBCXX" ]; then
    echo "[verify] FAIL: $label requires GLIBCXX_${glibcxx} > ${MAX_GLIBCXX}" >&2
    rc=1
  fi
  # __libc_single_threaded: RHEL 回移进 2.28, 上游 glibc 2.32 才加入,
  # UOS 20 / Debian 10 没有该符号, 出现即失败。
  if { find "$dir" -type f -exec readelf --dyn-syms {} \; 2>/dev/null || true; } \
      | grep -q '__libc_single_threaded'; then
    echo "[verify] FAIL: $label references __libc_single_threaded (not exported by upstream glibc 2.28)" >&2
    rc=1
  fi
  return "$rc"
}

verify_ok=1
if [ "$RC" -eq 0 ]; then
  for tarball in *-legacy.tar.gz; do
    [ -f "$tarball" ] || continue
    verify_tarball "$tarball" "${tarball%.tar.gz}" || verify_ok=0
  done
else
  echo "[verify] 跳过 glibc 校验 (构建本身已失败, RC=$RC)"
fi
rm -rf "$WORKSPACE/.verify"

# ---- BUILD-INFO.txt (与 mysql 项目的 BUILD-ENVIRONMENT.txt 对应) ----
{
  echo "package_platform=linux-${PACKAGE_PLATFORM:-${ARCH_TARGET}}"
  echo "electerm_version=${ELECTERM_VERSION}"
  echo "electerm_ref=${ELECTERM_REF:-}"
  echo "machine=$(uname -m)"
  echo "glibc=$(getconf GNU_LIBC_VERSION)"
  echo "gcc=$(gcc --version | head -n 1)"
  echo "build_container=zxdong262/electerm-builder-legacy (Ubuntu 18.04 / Node 16 / GCC 8)"
  echo "max_glibc_ceiling=${MAX_GLIBC}"
  echo "max_glibcxx_ceiling=${MAX_GLIBCXX}"
} > BUILD-INFO.txt

if [ "$RC" -eq 0 ] && [ "$verify_ok" -eq 1 ]; then
  echo "0" > "$STATUS_FILE"
  echo "构建成功: 全部目标已生成并通过 glibc 兼容性校验"
else
  echo "1" > "$STATUS_FILE"
  echo "警告: 构建或 glibc 校验存在失败 (RC=$RC verify_ok=$verify_ok)，已产出的包仍保留在 artifacts/"
fi

echo "--- 产物清单 ---"
ls -lh
echo "--- BUILD-INFO.txt ---"
cat BUILD-INFO.txt
echo "BUILD_DONE"
exit 0
