# electerm ARM64 GitHub Actions 构建（UOS 20 / Ubuntu 兼容）

参考 mysql 项目已验证的 `build-linux-uos20.yml` 结构，用 GitHub Actions 构建
**electerm 2.10.26**（及其同系列版本）的 **arm64** Linux 安装包，产物经 **Debian 10
（UOS 20 ABI 基线）真机验证**，可直接安装用于 **SSH / SFTP / Telnet / 串口** 连接。

> 按「单个 yml 只配置一个架构」的原则，本文件只做 **arm64**（含官方脚本顺带产出的
> armv7l，可忽略）。需要 x64 时复制本文件另存一份，改两处即可，见下文。

## 为什么需要 "legacy" 构建

electerm 的 SSH/SFTP 依赖 `node-pty`、`serialport` 等**原生模块**。它们在较新系统
（Ubuntu 22/24）编译时会链接新版 glibc 符号，而 **UOS 20 / Ubuntu 18 的 glibc 很旧
（< 2.34）**，装上去无法启动。官方因此维护 legacy 兼容构建：在 **Ubuntu 18.04
（glibc 2.27）+ Node 16 + GCC 8** 的旧环境里降级依赖，产物对 glibc 的要求不高于
UOS 20 的 **2.28**。

| 组件 | 官方正式版 | legacy 版 |
|---|---|---|
| electron | 38.2.2 | **22.3.27** |
| node-pty | 1.1.0-beta34 | **0.10.1** |
| serialport | 13.0.0 | **10.5.0** |
| vite | 7.3.1 | **4** |

## 为什么 build 任务用 `docker run` 而不是 `container:`

GitHub Actions 的 **JS actions（checkout / upload-artifact 等）在 job 容器内执行**，
运行器需要 glibc ≥ 2.28。legacy 构建容器是 Ubuntu 18.04（glibc **2.27**），把 job
的 `container` 设为它会导致 `checkout@v6` 这类步骤直接报
`GLIBC_2.28' not found (required by node)`。

因此 build 任务**不设 job 容器**：checkout、上传产物等 JS actions 跑在宿主机
（node24 正常），真正编译打包在容器里通过 `docker run` 完成；基线确认也移进了
`ci/build-legacy.sh` 的 `[0/6]`。verify 任务用的 `debian:10-slim` 正好是
glibc 2.28，所以可以直接用 `container:`。

## 工作流结构（对应 mysql 的 build-linux-uos20.yml）

| 任务 | 做什么 | 对应 mysql |
|---|---|---|
| `build` | arm64 原生 runner（ubuntu-22.04-arm），宿主机跑 JS actions + `docker run` legacy 容器构建，产出 tar.gz/deb/rpm/AppImage | `build` |
| `verify-uos20` | 在 **Debian 10**（glibc 2.28，与 UOS 20 同基线）容器中 `apt` 安装 deb、检查全部 ELF 依赖、启动冒烟 | `verify-uos20` |
| `release` | 推 `v*` tag 时，把通过验证的产物发布为 GitHub Release（tag 与版本不符则拒绝） | `release` |

**额外的 glibc 静态校验**（构建任务内）：解包每个 tar.gz，用 `readelf` 扫描全部 ELF
的 **UND 符号**，要求 `GLIBC_ ≤ 2.28`、`GLIBCXX_ ≤ 3.4.25`、且不引用
`__libc_single_threaded`（上游 glibc 2.32 才加入，UOS 20 没有）。校验结果写入
`artifacts/BUILD-INFO.txt`。

## 目录结构

```
.
├── .github/workflows/build-linux-uos20.yml  # GitHub Actions 工作流（单架构：arm64）
├── ci/build-legacy.sh                       # 容器内构建+校验脚本（勿改行尾为 CRLF）
├── .gitattributes                           # 保证 sh/yml 以 LF 提交
└── README.md
```

## 触发方式

- **push** 到 `master` / `main`：自动构建
- **pull_request** 到 `master` / `main`：自动构建
- **tag** 推 `v*`（如 `v2.10.26`）：构建 → Debian 10 验证 → 发布 GitHub Release
- **手动**：Actions → `Linux electerm ARM64 (UOS 20 compatible)` → Run workflow

手动触发参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| electerm_ref | `v2.10.26` | 分支或 tag，改版本号即可构建其他版本 |
| source_repo | `electerm/electerm` | 构建源，可改为自己的 fork（如 `你的名字/electerm`） |

### 产物

| 架构 | runner | 构建方式 | 产物（每种架构 4 个） |
|---|---|---|---|
| arm64 | ubuntu-22.04-arm | docker run legacy 镜像 (arm64) | `electerm-2.10.26-linux-arm64-legacy.deb` `.tar.gz` `.AppImage`、`-linux-aarch64-legacy.rpm` |
| armv7l（随 arm64 任务） | 同上 | 同上 | `-linux-armv7l-legacy.deb` `.tar.gz` `.rpm` `.AppImage` |

> 官方 v2.10.26 release 中即有同名 legacy 产物，可对照
> <https://github.com/electerm/electerm/releases/tag/v2.10.26> 验证命名。

### 增加 x64（单独一个 yml 文件）

复制 `build-linux-uos20.yml` 为 `build-linux-x64.yml`，改两处：

```yaml
name: Linux electerm X64 (UOS 20 compatible)   # 名字区分
jobs:
  build:
    runs-on: ubuntu-latest                      # x64 用普通 runner
    ...
    run: |
      docker run --rm --platform linux/amd64 \  # amd64 平台
        ... zxdong262/electerm-builder-legacy:latest \
        bash /workspace/ci/build-legacy.sh x64  # 构建参数 x64
```

其余（verify/release）对应改为 `ubuntu-latest` 与 x64 的 deb 文件名。

## 安装与使用

### UOS 20（Debian 系，arm64）

```bash
sudo dpkg -i electerm-2.10.26-linux-arm64-legacy.deb
sudo apt-get -f install -y
```

若还缺运行库，补装：

```bash
sudo apt install -y libnss3 libgtk-3-0 libasound2 libxss1 libxtst6
```

### Ubuntu（18.04 及以上，arm64）

```bash
sudo apt install ./electerm-2.10.26-linux-arm64-legacy.deb
```

### AppImage（免安装）

```bash
chmod +x electerm-2.10.26-linux-arm64-legacy.AppImage
./electerm-2.10.26-linux-arm64-legacy.AppImage
# 老系统缺 FUSE 时:
sudo apt install -y libfuse2
```

### tar.gz（绿色解压版）

```bash
tar -xzf electerm-2.10.26-linux-arm64-legacy.tar.gz
cd electerm-2.10.26-linux-arm64-legacy
./electerm
```

### SSH 使用提示

- 主界面「新建会话」选 **SSH**，填主机/IP、端口（默认 22）、用户名、密码或私钥即可。
- 系统安装包已注册 `ssh://`、`sftp://` 协议，点击网页/文档中的 `ssh://user@host`
  链接会直接唤起 electerm 连接。
- SFTP 文件传输、端口转发（隧道）、rz/sz、zmodem 均可用。

## 发布 Release

推一个与版本匹配的 tag 即可自动发布：

```bash
git tag v2.10.26
git push origin v2.10.26
```

- 发布前强制经过 build + verify-uos20 两个任务；
- tag 与产物实际版本不符时（`BUILD-INFO.txt` 里的 `electerm_version`）会拒绝发布；
- Release 已存在时只补充上传缺失资产（--clobber 覆盖同名）。

## 故障排查

| 现象 | 处理 |
|---|---|
| `actions/checkout@v6` 报 `GLIBC_2.28 not found` | 该 job 用了 `container:` 且容器 glibc < 2.28；build 任务必须走宿主机 + `docker run`（本文件已如此） |
| `verify-uos20` 装 deb 时 apt 报依赖缺失 | buster 仓库缺个别依赖（少见）；可改从 tar.gz 解压运行 |
| 冒烟测试无版本号输出 | 看日志中 electerm 的报错；多为缺运行库，`apt install` 对应库后重跑 |
| 构建任务在「检查构建状态」标红 | 日志有 `RC=` / `verify_ok=` 提示；armv7l 交叉构建失败属常见情况，arm64 产物不受影响 |
| Release 被拒绝发布 | tag 与 `BUILD-INFO.txt` 的 `electerm_version` 不一致；确认 tag 写成 `v<版本号>` |
| 产物过期 | artifact 保留 14 天；要长期保存请用 tag 发布 Release |
| 报 `build-linux-legacy.js` 不存在 | 所选 ref 太旧，官方还没引入 legacy 构建脚本；选 v2.10.26 或更新版本 |

## 验证方式

- 构建任务内：`readelf` 静态校验全部 ELF 的 glibc/libstdc++ 符号上限（≤ 2.28 / 3.4.25）；
- 验证任务内：在 **Debian 10**（与 UOS 20 同为 glibc 2.28）上 `apt` 安装 deb、
  `sha256sum` 校验、逐文件 `ldd` 检查依赖、启动冒烟；
- 每次构建生成 `SHA256SUMS.txt`，可 `sha256sum -c` 校验；
- 建议在真机 UOS 20 / Ubuntu 上安装后做一次 SSH 连接冒烟测试。
