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
#   arm : 逐格式构建并门禁 arm64 的 tar.gz/deb/rpm/AppImage
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
# Electron 22 的 install.js 不读惯用的 ELECTRON_CACHE：它传给 @electron/get
# 的是 electron_config_cache。所有缓存从同一根目录派生，容器工作流会将其挂载
# 到与 npm 生命周期进程相同 UID/GID 可写的位置，避免镜像预置 /root 缓存的权限影响。
ELECTERM_CACHE_ROOT="${ELECTERM_CACHE_ROOT:-/tmp/electerm-cache-$(id -u)}"
ELECTRON_CACHE="${ELECTRON_CACHE:-${ELECTERM_CACHE_ROOT%/}/electron}"
NPM_CACHE="${NPM_CACHE:-${npm_config_cache:-${ELECTERM_CACHE_ROOT%/}/npm}}"
export ELECTERM_CACHE_ROOT ELECTRON_CACHE NPM_CACHE
export electron_config_cache="$ELECTRON_CACHE"
export npm_config_electron_config_cache="$ELECTRON_CACHE"
export npm_config_cache="$NPM_CACHE"
# prepare-electron-build.js 保留了上游 electron-builder.json 中的
# ${env.WORKFLOW_NAME}。本 CI 不经由上游组合脚本启动，因此必须显式提供
# 一个稳定名称；否则 electron-builder 在读取配置时会直接拒绝打包。
WORKFLOW_NAME="${WORKFLOW_NAME:-electerm-linux-arm64-legacy}"
export WORKFLOW_NAME
ELECTERM_VERSION="unknown"
BUILD_RC=1
VERIFY_OK=0
# 任何正常失败都会由 EXIT trap 写入 BUILD-INFO；这些默认值可区分“尚未走到
# 产物门禁”与“产物缺失”，避免最终状态步骤只留下无上下文的 build_status=1。
BUILD_PHASE="initialization"
FAIL_REASON=""
missing_artifacts="not-reached"

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
    echo "electron_cache=${ELECTRON_CACHE}"
    echo "npm_cache=${NPM_CACHE}"
    echo "workflow_name=${WORKFLOW_NAME}"
    echo "package_lock_present=$(test -f "$SRC_DIR/package-lock.json" && echo yes || echo no)"
    echo "effective_uid=$(id -u)"
    echo "effective_gid=$(id -g)"
    echo "home=${HOME:-}"
    echo "build_container=zxdong262/electerm-builder-legacy (Ubuntu 18.04 / Node 16 / GCC 8)"
    echo "max_glibc_ceiling=${MAX_GLIBC}"
    echo "max_glibcxx_ceiling=${MAX_GLIBCXX}"
    echo "build_phase=${BUILD_PHASE}"
    echo "failure_reason=${FAIL_REASON:-none}"
    echo "build_rc=${BUILD_RC}"
    echo "missing_artifacts=${missing_artifacts}"
    echo "glibc_verify_ok=${VERIFY_OK}"
  } > "$ART_DIR/BUILD-INFO.txt"
}

# sha256sum --check 必须能通过: 校验和文件自身不能出现在清单里。BUILD-LOG.txt
# 会持续被 tee 追加直到 EXIT trap 结束，也不能入清单，否则其摘要会立刻失效。
write_checksums() {
  local tmp="$WORKSPACE/.sha256sums.tmp"
  ( cd "$ART_DIR" && find . -maxdepth 1 -type f \
      ! -name 'SHA256SUMS.txt' ! -name 'BUILD-LOG.txt' \
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
  FAIL_REASON="$*"
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
# 在清理成功后才开始镜像输出，避免旧运行日志混入本次 diagnostics artifact。
exec > >(tee "$ART_DIR/BUILD-LOG.txt") 2>&1
write_build_info

# 修改依赖和构建配置前先备份源码文件。仓库内 vendored source/ 与 clone 两种
# 布局都可能跑在自托管 runner 上; 无论成功失败都恢复, 避免污染后续构建。
MANIFEST_BACKUP="$WORKSPACE/.electerm-package.json.original"
LOCK_BACKUP="$WORKSPACE/.electerm-package-lock.json.original"
BUILDER_CONFIG_BACKUP="$WORKSPACE/.electerm-builder.json.original"
INSTALL_SRC_BACKUP="$WORKSPACE/.electerm-install-src.js.original"
cp package.json "$MANIFEST_BACKUP"
if [ -f package-lock.json ]; then
  cp package-lock.json "$LOCK_BACKUP"
else
  rm -f "$LOCK_BACKUP"
fi
if [ -f electron-builder.json ]; then
  cp electron-builder.json "$BUILDER_CONFIG_BACKUP"
else
  rm -f "$BUILDER_CONFIG_BACKUP"
fi
if [ -f work/app/lib/install-src.js ]; then
  cp work/app/lib/install-src.js "$INSTALL_SRC_BACKUP"
else
  rm -f "$INSTALL_SRC_BACKUP"
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
  if [ -f "$BUILDER_CONFIG_BACKUP" ]; then
    cp "$BUILDER_CONFIG_BACKUP" "$SRC_DIR/electron-builder.json"
    rm -f "$BUILDER_CONFIG_BACKUP"
  else
    rm -f "$SRC_DIR/electron-builder.json"
  fi
  if [ -f "$INSTALL_SRC_BACKUP" ]; then
    cp "$INSTALL_SRC_BACKUP" "$SRC_DIR/work/app/lib/install-src.js"
    rm -f "$INSTALL_SRC_BACKUP"
  else
    rm -f "$SRC_DIR/work/app/lib/install-src.js"
  fi
}

echo "================================================================"
echo "[1/7] 降级依赖 (electron 22.3.27 / node-pty 0.10.1 / serialport 10.5.0 / vite 4)"
echo "      原因: UOS 20 / Ubuntu 18 等旧 glibc 系统跑不了新版原生模块"
echo "================================================================"
BUILD_PHASE="dependency-rewrite"
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
# 不删除上游 lockfile：它锁定了与 2.10.26 源码相匹配的纯 JS 依赖（尤其
# trzsz2 的 cjs-full 导出）。native 依赖改写后由 npm install 按 lockfile 的
# 既有依赖树补全更新；删除 lockfile 会解析到新版 trzsz2，导致运行时主进程崩溃。

echo "================================================================"
echo "[2/7] 安装 npm 依赖 (registry 抖动时自动重试)"
echo "================================================================"
BUILD_PHASE="npm-config"
# 缓存根可能是 workflow 预建的 workspace 挂载目录，不能 rm -rf 根目录，否则
# Docker bind mount 的上层权限与诊断路径都可能被破坏。只清理本次 Electron 子缓存。
mkdir -p "$ELECTERM_CACHE_ROOT" "$NPM_CACHE"
chmod 700 "$ELECTERM_CACHE_ROOT" "$NPM_CACHE" 2>/dev/null || true
rm -rf "$ELECTRON_CACHE"
mkdir -p "$ELECTRON_CACHE"
chmod 700 "$ELECTRON_CACHE" 2>/dev/null || true
cache_probe="$ELECTRON_CACHE/.write-probe-$$"
echo "Cache identity: uid=$(id -u) gid=$(id -g) HOME=${HOME:-<unset>}"
printf 'Electron cache: %s\nNpm cache: %s\nWORKFLOW_NAME: %s\n' "$ELECTRON_CACHE" "$NPM_CACHE" "$WORKFLOW_NAME"
ls -ld "$ELECTERM_CACHE_ROOT" "$ELECTRON_CACHE" "$NPM_CACHE" || true
if ! mkdir "$cache_probe"; then
  fail "Electron 缓存不可创建子目录: $ELECTRON_CACHE (uid=$(id -u) gid=$(id -g)); 请检查 workflow 的 --user 与挂载目录所有权"
fi
if ! rmdir "$cache_probe"; then
  fail "Electron 缓存探针无法清理: $cache_probe"
fi
# 容器的预置 /root/.cache/electron 可能有不同 UID/权限留下的 zip；Electron 22
# 必须使用下方明确传入的 electron_config_cache，而不是镜像默认缓存。
npm config set legacy-peer-deps true
npm config set cache "$NPM_CACHE"
# 旧 Node 16 + 老 registry 组合下网络抖动很常见, 让 npm 自己多试几次,
# 外面再套一层整体重试; 否则一次 ECONNRESET 就是一次红叉。
npm config set fetch-retries 5
npm config set fetch-retry-mintimeout 20000
npm config set fetch-retry-maxtimeout 120000

BUILD_PHASE="npm-install"
npm_install_ok=0
for attempt in 1 2 3; do
  echo "--- npm i (第 $attempt 次) ---"
  if npm i --cache "$NPM_CACHE"; then
    npm_install_ok=1
    break
  fi
  npm_eacces_logs="$(find "$NPM_CACHE/_logs" -type f -name '*-debug-0.log' \
    -exec grep -lE 'EACCES.*(electron|cache)|EACCES: permission denied' {} + \
    2>/dev/null || true)"
  if [ -n "$npm_eacces_logs" ]; then
    printf '%s\n' "$npm_eacces_logs" >&2
    fail "npm i 因 Electron/npm 缓存权限被拒绝而失败; 检查上方 Cache identity、目录权限与 npm debug log（重试无法修复 EACCES）"
  fi
  echo "npm i 第 $attempt 次失败, 30s 后重试" >&2
  sleep 30
done
[ "$npm_install_ok" -eq 1 ] || fail "npm i 连续 3 次失败, 见上方日志（可能是 registry 网络、依赖版本或 Node 版本兼容性）"

# 2.10.26 主进程直接 require('trzsz2/cjs-full')；构建时把该导出作为门禁，
# 防止包能启动但新建 SSH 会话时因 npm 解析到不兼容版本而崩溃。
node - <<'NODE' || fail "trzsz2 版本与 electerm 2.10.26 不兼容：缺少 trzsz2/cjs-full 导出"
const fs = require('fs');
if (!fs.existsSync('node_modules/trzsz2/package.json')) {
  console.error('trzsz2 dependency is missing after npm install');
  process.exit(1);
}
const trzszPackage = JSON.parse(fs.readFileSync('node_modules/trzsz2/package.json', 'utf8'));
try {
  require.resolve('trzsz2/cjs-full');
} catch (error) {
  console.error(`trzsz2@${trzszPackage.version} does not export cjs-full`);
  process.exit(1);
}
console.log(`trzsz2@${trzszPackage.version} exports cjs-full`);
NODE

BUILD_PHASE="electron-rebuild-install"
npm i -S @electron/rebuild@3.7.2 || fail "安装 @electron/rebuild@3.7.2 失败"

echo "================================================================"
echo "[3/7] 编译应用 (npm run b = clean + compile + prepare-file)"
echo "================================================================"
BUILD_PHASE="application-compile"
npm run b || fail "npm run b 失败 (前端编译或资源准备阶段)"

echo "================================================================"
echo "[4/7] 准备 electron-builder 配置 (npm run pb)"
echo "================================================================"
BUILD_PHASE="builder-configuration"
npm run pb || fail "npm run pb 失败 (electron-builder 配置生成阶段)"

echo "================================================================"
echo "[5/7] 构建 legacy 安装包 (tar.gz / deb / rpm / AppImage)"
echo "================================================================"
BUILD_PHASE="package-build"
if [ "$ARCH_TARGET" = "arm" ]; then
  # 上游 build-linux-arm-legacy.js 把 arm64 与 armv7l 混在同一进程中。armv7l
  # electron-rebuild 没有 catch, 一旦失败便以 RC=1 中止，导致已成功的 arm64 包
  # 也被误判失败。本工作流只承诺 arm64，因此逐格式原生构建并独立记录结果。
  BUILDER="$SRC_DIR/node_modules/.bin/electron-builder"
  BUILDER_CONFIG="$SRC_DIR/electron-builder.json"
  [ -x "$BUILDER" ] || fail "electron-builder 不存在: $BUILDER"
  [ -f "$BUILDER_CONFIG" ] || fail "缺少 electron-builder 配置: $BUILDER_CONFIG"

# electron-builder 在 GitHub Actions 中会自动推断发布模式。此脚本的职责只是生成
# artifact，正式发布由 workflow 的 release job 在验证通过后用 gh release 完成。
# 显式禁用 builder 发布，避免它因没有 GH_TOKEN 在“打包完成后”把所有格式判失败。
BUILDER_PUBLISH_ARGS=(--publish never)

build_arm64_package() {
    local target="$1" install_src="$2"
    BUILD_PHASE="package-${target}"
    echo "--- build arm64 ${target}: ${install_src} ---"
    rm -rf "$SRC_DIR/dist"
    if ! node - "$BUILDER_CONFIG" "$target" "$install_src" <<'NODE'
const fs = require('fs')
const path = require('path')
const configPath = process.argv[2]
const target = process.argv[3]
const installSrc = process.argv[4]
const config = JSON.parse(fs.readFileSync(configPath, 'utf8'))
config.linux.target = [target]
if (config.artifactName) {
  config.artifactName = config.artifactName.replace(
    '${productName}-${version}-${os}-${arch}.${ext}',
    '${productName}-${version}-${os}-${arch}-legacy.${ext}'
  )
}
fs.writeFileSync(configPath, JSON.stringify(config, null, 2))
fs.writeFileSync(
  path.resolve(path.dirname(configPath), 'work/app/lib/install-src.js'),
  `module.exports = '${installSrc}'`
)
NODE
    then
      echo "FAIL: 无法为 arm64 ${target} 更新 electron-builder 配置" >&2
      return 1
    fi
    if "$BUILDER" --linux --arm64 "${BUILDER_PUBLISH_ARGS[@]}"; then
      find "$SRC_DIR/dist" -maxdepth 1 -type f \
        \( -name '*.deb' -o -name '*.rpm' -o -name '*.AppImage' -o -name '*.tar.gz' \) \
        -exec cp -v {} "$ART_DIR/" \;
      return 0
    fi
    echo "FAIL: arm64 ${target} 打包失败; 继续尝试其他格式以保留诊断产物" >&2
    return 1
  }

  BUILD_RC=0
  build_arm64_package tar.gz "linux-arm64-legacy.tar.gz" || BUILD_RC=1
  build_arm64_package deb "linux-arm64-legacy.deb" || BUILD_RC=1
  build_arm64_package rpm "linux-aarch64-legacy.rpm" || BUILD_RC=1
  build_arm64_package AppImage "linux-arm64-legacy.AppImage" || BUILD_RC=1
else
  node build/bin/build-linux-legacy
  BUILD_RC=$?
fi
echo "打包步骤汇总退出码: RC=$BUILD_RC"

echo "================================================================"
echo "[6/7] 汇总并校验必需产物"
echo "================================================================"
BUILD_PHASE="artifact-gate"
# x64 上游脚本仍使用 KEEP_FILE 保存到 dist*; arm64 已在每种格式完成时复制。
if [ "$ARCH_TARGET" = "x64" ]; then
  for d in dist*/; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f \
      \( -name '*.deb' -o -name '*.rpm' -o -name '*.AppImage' -o -name '*.tar.gz' \) \
      -exec cp -v {} "$ART_DIR/" \;
  done
fi

case "$ARCH_TARGET" in
  arm)
    required_artifacts="
      electerm-${ELECTERM_VERSION}-linux-arm64-legacy.tar.gz
      electerm-${ELECTERM_VERSION}-linux-arm64-legacy.deb
      electerm-${ELECTERM_VERSION}-linux-aarch64-legacy.rpm
      electerm-${ELECTERM_VERSION}-linux-arm64-legacy.AppImage"
    ;;
  x64)
    required_artifacts="
      electerm-${ELECTERM_VERSION}-linux-x64-legacy.tar.gz
      electerm-${ELECTERM_VERSION}-linux-amd64-legacy.deb
      electerm-${ELECTERM_VERSION}-linux-x86_64-legacy.rpm
      electerm-${ELECTERM_VERSION}-linux-x86_64-legacy.AppImage"
    ;;
esac
missing_artifacts=0
for name in $required_artifacts; do
  if [ ! -s "$ART_DIR/$name" ]; then
    echo "FAIL: 缺少必需产物或文件为空: $name" >&2
    missing_artifacts=1
  fi
done
produced="$(find "$ART_DIR" -maxdepth 1 -type f \
  \( -name '*.deb' -o -name '*.rpm' -o -name '*.AppImage' -o -name '*.tar.gz' \) | wc -l)"
echo "已汇总 $produced 个安装包; missing_artifacts=$missing_artifacts"
[ "$missing_artifacts" -eq 0 ] || BUILD_RC=1

echo "================================================================"
echo "[7/7] glibc / libstdc++ 兼容性静态校验"
echo "================================================================"
BUILD_PHASE="abi-validation"
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
case "$ARCH_TARGET" in
  arm) verify_pattern='*-linux-arm64-legacy.tar.gz' ;;
  x64) verify_pattern='*-linux-x64-legacy.tar.gz' ;;
esac
for tarball in $verify_pattern; do
  [ -f "$tarball" ] || continue
  scanned=$((scanned + 1))
  verify_tarball "$tarball" "${tarball%.tar.gz}" || VERIFY_OK=0
done
rm -rf "$WORKSPACE/.verify"

if [ "$scanned" -ne 1 ]; then
  # 必需架构必须恰好有一个 tar.gz，不能用其他架构的包代替 ABI 校验。
  echo "[verify] 期望 1 个 $verify_pattern, 实际找到 $scanned 个" >&2
  VERIFY_OK=0
else
  echo "[verify] 已扫描必需架构 tar.gz, verify_ok=$VERIFY_OK"
fi

if [ "$BUILD_RC" -eq 0 ] && [ "$missing_artifacts" -eq 0 ] && [ "$VERIFY_OK" -eq 1 ]; then
  BUILD_PHASE="complete"
  echo "0" > "$STATUS_FILE"
  echo "构建成功: 必需架构的 4 个目标均已生成并通过 glibc 兼容性校验"
else
  echo "1" > "$STATUS_FILE"
  echo "警告: 打包、产物门禁或 glibc 校验失败 (RC=$BUILD_RC missing=$missing_artifacts verify_ok=$VERIFY_OK), 已产出的包仍保留在 artifacts/" >&2
fi

# trap on_exit 会补齐 BUILD-INFO.txt / SHA256SUMS.txt 并打印清单
exit 0
