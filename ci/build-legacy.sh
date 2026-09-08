#!/usr/bin/env bash
# =====================================================================
# electerm legacy 构建脚本 (在 zxdong262/electerm-builder-legacy 容器内运行)
# ---------------------------------------------------------------------
# 宿主机挂载工作区后调用, 例如:
#   docker run --rm --platform linux/arm64 \
#     -v "${{ github.workspace }}:/workspace" -w /workspace \
#     -e ELECTERM_REF -e ELECTERM_SRC_REL -e MAX_GLIBC -e MAX_GLIBCXX \
#     -e USE_SYSTEM_FPM -e KEEP_FILE -e PACKAGE_PLATFORM \
#     zxdong262/electerm-builder-legacy:latest \
#     bash /workspace/ci/build-legacy.sh arm
#
# 用法: bash ci/build-legacy.sh x64 | arm
#   x64 : 构建 x64 的 tar.gz/deb/rpm/AppImage (build-linux-legacy.js)
#   arm : 构建 arm64 + armv7l 的 tar.gz/deb/rpm/AppImage (build-linux-arm-legacy.js)
#
# 环境变量 (由 workflow 提供):
#   ELECTERM_SRC_REL 源码相对工作区的路径, 默认 source
#   ELECTERM_REF     构建的 ref, 写入 BUILD-INFO.txt
#   MAX_GLIBC        UOS 20 兼容的 glibc 上限 (默认 2.28)
#   MAX_GLIBCXX      UOS 20 兼容的 libstdc++ 符号上限 (默认 3.4.25)
#   USE_SYSTEM_FPM   true 时使用容器内 ruby/fpm 打 deb/rpm
#   KEEP_FILE        true 时每轮 dist 产物改名保留, 不互相覆盖
#
# 产物: artifacts/ (安装包 + BUILD-INFO.txt + SHA256SUMS.txt)
# 状态: build_status (0=全部成功, 非0=有失败但已产出物仍保留)
#
# 退出约定 (workflow 依赖):
#   脚本一进来就把 build_status 写成 1, 并建好 artifacts/; 正常失败路径 (npm
#   安装失败、编译失败等) 都至少留下状态文件和 BUILD-INFO.txt, 由 workflow 的
#   门禁步骤统一判定红绿。只有跑到最后且构建与校验都通过才会写 0。
# =====================================================================
set -uo pipefail

ARCH_TARGET="${1:-x64}"
WORKSPACE="$(pwd)"
SRC_DIR="$WORKSPACE/${ELECTERM_SRC_REL:-source}"
ART_DIR="$WORKSPACE/artifacts"
STATUS_FILE="$WORKSPACE/build_status"
MAX_GLIBC="${MAX_GLIBC:-2.28}"
MAX_GLIBCXX="${MAX_GLIBCXX:-3.4.25}"
ELECTERM_VERSION="unknown"
BUILD_RC=1
VERIFY_OK=0

# 首次建立诊断目录; 解析出源码后会清掉旧产物并重新初始化
mkdir -p "$ART_DIR"
echo "1" > "$STATUS_FILE"

# BUILD-INFO.txt 与 SHA256SUMS.txt 无论怎么退出都要写出来, 否则 workflow 的
# 门禁与 release 守卫只能看到"什么都没有"。
write_build_info() {
  local glibc_info gcc_info node_info
  glibc_info="$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
  gcc_info="$(gcc --version 2>/dev/null | head -n 1 || true)"
  node_info="$(node --version 2>/dev/null || true)"
  {
    echo "package_platform=linux-${PACKAGE_PLATFORM:-${ARCH_TARGET}}"
    echo "electerm_version=${ELECTERM_VERSION}"
    echo "electerm_ref=${ELECTERM_REF:-}"
    echo "source_path=${ELECTERM_SRC_REL:-source}"
    echo "machine=$(uname -m)"
    echo "glibc=${glibc_info}"
    echo "gcc=${gcc_info}"
    echo "node=${node_info}"
    echo "build_container=zxdong262/electerm-builder-legacy (Ubuntu 18.04 / Node 16 / GCC 8)"
    echo "max_glibc_ceiling=${MAX_GLIBC}"
    echo "max_glibcxx_ceiling=${MAX_GLIBCXX}"
    echo "build_rc=${BUILD_RC}"
    echo "glibc_verify_ok=${VERIFY_OK}"
  } > "$ART_DIR/BUILD-INFO.txt"
}

# sha256sum --check 必须能通过: 校验和文件自身不能出现在清单里, 否则
# "先创建空文件 -> find 把它也算进去 -> 写入后内容变了" 会让校验永远 FAILED。
write_checksums() {
  local tmp="$WORKSPACE/.sha256sums.tmp"
  ( cd "$ART_DIR" && find . -maxdepth 1 -type f ! -name 'SHA256SUMS.txt' \
      -printf '%P\n' | sort | xargs -r sha256sum ) > "$tmp"
  mv "$tmp" "$ART_DIR/SHA256SUMS.txt"
}

on_exit() {
  local rc=$?
  # trap 可能在 MANIFEST_BACKUP 初始化前触发, 所以只在变量存在时恢复
  if [ -n "${MANIFEST_BACKUP:-}" ]; then
    restore_source_manifests || true
  fi
  write_build_info
  write_checksums
  if [ "$rc" -ne 0 ] && [ "$(cat "$STATUS_FILE" 2>/dev/null)" = "0" ]; then
    echo "1" > "$STATUS_FILE"
  fi
  echo "--- artifacts/ ---"
  ls -lh "$ART_DIR" || true
  echo "--- BUILD-INFO.txt ---"
  cat "$ART_DIR/BUILD-INFO.txt" || true
  echo "build_status=$(cat "$STATUS_FILE" 2>/dev/null)"
  echo "BUILD_DONE"
  # 容器退出码保持 0: 红绿由 workflow 读 build_status 决定, 这样产物一定能上传
  exit 0
}
trap on_exit EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

echo "================================================================"
echo "[0/7] 确认 UOS 20 兼容构建基线"
echo "================================================================"
case "$ARCH_TARGET" in
  arm) EXPECT_ARCH="aarch64" ;;
  x64) EXPECT_ARCH="x86_64" ;;
  *) fail "未知架构目标: $ARCH_TARGET (可选: x64 | arm)" ;;
esac
test "$(uname -m)" = "$EXPECT_ARCH" \
  || fail "uname -m=$(uname -m), 期望 $EXPECT_ARCH (arm64 构建必须在 arm64 主机/容器内进行)"

# 构建容器 glibc 必须不高于 UOS 20 的 2.28 (legacy 镜像是 Ubuntu 18.04, 即 2.27)
build_glibc="$(getconf GNU_LIBC_VERSION | awk '{print $2}')"
echo "build glibc: $build_glibc (ceiling $MAX_GLIBC)"
test "$(printf '%s\n' "$MAX_GLIBC" "$build_glibc" | sort -V | tail -n 1)" = "$MAX_GLIBC" \
  || fail "构建环境 glibc $build_glibc 高于 $MAX_GLIBC, 产物无法在 UOS 20 运行; 请确认用的是 legacy 镜像"

# readelf 是 [7/7] 符号校验的前提, 一并在这里确认, 免得跑 40 分钟后才发现缺
for tool in node npm python3 gcc fpm readelf tar; do
  command -v "$tool" >/dev/null 2>&1 || fail "构建镜像里缺少 $tool"
done
node --version
python3 --version
gcc --version | head -n 1
fpm --version

[ -f "$SRC_DIR/package.json" ] \
  || fail "未找到 $SRC_DIR/package.json; workflow 传入的 ELECTERM_SRC_REL=${ELECTERM_SRC_REL:-source} 不是有效的 electerm 源码目录"

cd "$SRC_DIR"
ELECTERM_VERSION="$(node -p "require('./package.json').version")"
[ -n "$ELECTERM_VERSION" ] || fail "无法从 package.json 读出版本号"
echo "electerm version: $ELECTERM_VERSION"
# 打包脚本可能重复沿用工作区里上一次生成的 dist*; 每次构建必须先清掉,
# 否则本次打包失败时仍可能把旧包当成本次产物上传。
find "$SRC_DIR" -maxdepth 1 -type d -name 'dist*' -exec rm -rf {} +
rm -rf "$ART_DIR"
mkdir -p "$ART_DIR"
write_build_info

# 修改依赖前先备份源码里的 manifest。仓库内 vendored source/ 与 clone 两种布局
# 都可能跑在自托管 runner 上; 无论成功失败都恢复, 避免污染后续构建。
MANIFEST_BACKUP="$WORKSPACE/.electerm-package.json.original"
LOCK_BACKUP="$WORKSPACE/.electerm-package-lock.json.original"
cp package.json "$MANIFEST_BACKUP"
if [ -f package-lock.json ]; then
  cp package-lock.json "$LOCK_BACKUP"
else
  rm -f "$LOCK_BACKUP"
fi

restore_source_manifests() {
  if [ -f "$MANIFEST_BACKUP" ]; then
    cp "$MANIFEST_BACKUP" "$SRC_DIR/package.json"
    rm -f "$MANIFEST_BACKUP"
  fi
  if [ -f "$LOCK_BACKUP" ]; then
    cp "$LOCK_BACKUP" "$SRC_DIR/package-lock.json"
    rm -f "$LOCK_BACKUP"
  else
    rm -f "$SRC_DIR/package-lock.json"
  fi
}

echo "================================================================"
echo "[1/7] 降级依赖 (electron 22.3.27 / node-pty 0.10.1 / serialport 10.5.0 / vite 4)"
echo "      原因: UOS 20 / Ubuntu 18 等旧 glibc 系统跑不了新版原生模块"
echo "================================================================"
node -e "
const fs = require('fs');
const pkg = JSON.parse(fs.readFileSync('package.json', 'utf8'));
pkg.devDependencies.electron = '22.3.27';
pkg.devDependencies['@electron/rebuild'] = '3.7.2';
pkg.dependencies['node-pty'] = '0.10.1';
pkg.dependencies.serialport = '10.5.0';
pkg.devDependencies.vite = '4';
// @electerm/electerm-resource@1.3.7 在 npm registry 上不存在 (1.3.6 之后直接
// 跳到 2.x), 而 2.10.26 的 package.json 引用了它; 就近修正为同系列的 1.3.6。
if (pkg.devDependencies['@electerm/electerm-resource'] === '1.3.7') {
  pkg.devDependencies['@electerm/electerm-resource'] = '1.3.6';
}
fs.writeFileSync('package.json', JSON.stringify(pkg, null, 2) + '\n');
" || fail "修改 package.json 失败"
rm -f package-lock.json

echo "================================================================"
echo "[2/7] 安装 npm 依赖 (registry 抖动时自动重试)"
echo "================================================================"
npm config set legacy-peer-deps true
npm config set cache /tmp/.npm
# 旧 Node 16 + 老 registry 组合下网络抖动很常见, 让 npm 自己多试几次,
# 外面再套一层整体重试; 否则一次 ECONNRESET 就是一次红叉。
npm config set fetch-retries 5
npm config set fetch-retry-mintimeout 20000
npm config set fetch-retry-maxtimeout 120000

npm_install_ok=0
for attempt in 1 2 3; do
  echo "--- npm i (第 $attempt 次) ---"
  if npm i; then
    npm_install_ok=1
    break
  fi
  echo "npm i 第 $attempt 次失败, 30s 后重试" >&2
  sleep 30
done
[ "$npm_install_ok" -eq 1 ] || fail "npm i 连续 3 次失败, 见上方日志 (多为 registry 网络或某个依赖版本已下架)"

npm i -S @electron/rebuild@3.7.2 || fail "安装 @electron/rebuild@3.7.2 失败"

echo "================================================================"
echo "[3/7] 编译应用 (npm run b = clean + compile + prepare-file)"
echo "================================================================"
npm run b || fail "npm run b 失败 (前端编译或资源准备阶段)"

echo "================================================================"
echo "[4/7] 准备 electron-builder 配置 (npm run pb)"
echo "================================================================"
npm run pb || fail "npm run pb 失败 (electron-builder 配置生成阶段)"

echo "================================================================"
echo "[5/7] 构建 legacy 安装包 (tar.gz / deb / rpm / AppImage)"
echo "================================================================"
# 这一步的失败是"部分失败": armv7l 交叉打包经常挂, 但 arm64 产物照样有用,
# 所以不 fail, 只记录 rc, 后面照常汇总与校验。
case "$ARCH_TARGET" in
  arm) node build/bin/build-linux-arm-legacy ;;
  x64) node build/bin/build-linux-legacy ;;
esac
BUILD_RC=$?
echo "打包脚本退出码: RC=$BUILD_RC"

echo "================================================================"
echo "[6/7] 汇总产物到 artifacts/"
echo "================================================================"
for d in dist*/; do
  [ -d "$d" ] || continue
  find "$d" -maxdepth 1 -type f \
    \( -name '*.deb' -o -name '*.rpm' -o -name '*.AppImage' -o -name '*.tar.gz' \) \
    -exec cp -v {} "$ART_DIR/" \;
done
produced="$(find "$ART_DIR" -maxdepth 1 -type f \
  \( -name '*.deb' -o -name '*.rpm' -o -name '*.AppImage' -o -name '*.tar.gz' \) | wc -l)"
echo "已汇总 $produced 个安装包"
[ "$produced" -gt 0 ] || fail "没有产出任何安装包 (打包脚本 RC=$BUILD_RC), 见上方 electron-builder 日志"

echo "================================================================"
echo "[7/7] glibc / libstdc++ 兼容性静态校验"
echo "================================================================"
# 解包每个 tar.gz, 扫描全部 ELF, 只统计实际需要的版本符号:
#   - GLIBC_  上限不得超过 MAX_GLIBC (2.28), 否则 UOS 20 / Debian 10 加载不了
#   - GLIBCXX_ 上限不得超过 MAX_GLIBCXX (3.4.25, 即 gcc 8 的 libstdc++)
# readelf --version-info 的 Version needs section 不受 --dyn-syms 窄列截断影响。
verify_tarball() {
  local tarball="$1" label="$2" rc=0
  local dir="$WORKSPACE/.verify/$label" syms="$WORKSPACE/.verify/$label.symbols"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xzf "$tarball" -C "$dir" || { echo "[verify] FAIL: 无法解包 $tarball" >&2; return 1; }
  { find "$dir" -type f -exec readelf --version-info --wide {} \; 2>/dev/null || true; } > "$syms"

  local glibc glibcxx
  glibc="$(grep -o 'GLIBC_[0-9][0-9.]*' "$syms" | sed 's/GLIBC_//' \
    | sort -Vu | tail -n 1)"
  glibcxx="$(grep -o 'GLIBCXX_[0-9][0-9.]*' "$syms" | sed 's/GLIBCXX_//' \
    | sort -Vu | tail -n 1)"
  echo "[verify] $label: 需要 GLIBC_${glibc:-<none>} / GLIBCXX_${glibcxx:-<none>} (上限 ${MAX_GLIBC} / ${MAX_GLIBCXX})"

  if [ -n "${glibc:-}" ] && \
     [ "$(printf '%s\n' "$MAX_GLIBC" "$glibc" | sort -V | tail -n 1)" != "$MAX_GLIBC" ]; then
    echo "[verify] FAIL: $label 需要 GLIBC_${glibc} > ${MAX_GLIBC}" >&2
    rc=1
  fi
  if [ -n "${glibcxx:-}" ] && \
     [ "$(printf '%s\n' "$MAX_GLIBCXX" "$glibcxx" | sort -V | tail -n 1)" != "$MAX_GLIBCXX" ]; then
    echo "[verify] FAIL: $label 需要 GLIBCXX_${glibcxx} > ${MAX_GLIBCXX}" >&2
    rc=1
  fi
  # __libc_single_threaded: RHEL 回移进了 2.28, 上游 glibc 2.32 才加入,
  # UOS 20 / Debian 10 没有该符号, 一旦引用即判失败。此符号无 GLIBC_ 版本，
  # 必须另用动态符号表扫描。
  if { find "$dir" -type f -exec readelf --dyn-syms --wide {} \; 2>/dev/null || true; } \
      | grep -q '__libc_single_threaded'; then
    echo "[verify] FAIL: $label 引用了 __libc_single_threaded (上游 glibc 2.28 不导出)" >&2
    rc=1
  fi
  return "$rc"
}

VERIFY_OK=1
scanned=0
cd "$ART_DIR"
for tarball in *-legacy.tar.gz; do
  [ -f "$tarball" ] || continue
  scanned=$((scanned + 1))
  verify_tarball "$tarball" "${tarball%.tar.gz}" || VERIFY_OK=0
done
rm -rf "$WORKSPACE/.verify"

if [ "$scanned" -eq 0 ]; then
  # 没有 tar.gz 就没法做符号扫描, 这时不能声称"通过校验"
  echo "[verify] 没有找到 *-legacy.tar.gz, 无法做 glibc 静态校验" >&2
  VERIFY_OK=0
else
  echo "[verify] 已扫描 $scanned 个 tar.gz, verify_ok=$VERIFY_OK"
fi

if [ "$BUILD_RC" -eq 0 ] && [ "$VERIFY_OK" -eq 1 ]; then
  echo "0" > "$STATUS_FILE"
  echo "构建成功: 全部目标已生成并通过 glibc 兼容性校验"
else
  echo "1" > "$STATUS_FILE"
  echo "警告: 构建或 glibc 校验存在失败 (RC=$BUILD_RC verify_ok=$VERIFY_OK), 已产出的包仍保留在 artifacts/" >&2
fi

# trap on_exit 会补齐 BUILD-INFO.txt / SHA256SUMS.txt 并打印清单
exit 0
