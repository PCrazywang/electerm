# electerm ARM64 GitHub Actions 构建（UOS 20 / Ubuntu 兼容）

参考 mysql 项目已验证的 `build-linux-uos20.yml` 结构，用 GitHub Actions 构建
**electerm 2.10.26**（及其同系列版本）的 **arm64** Linux 安装包。构建产物会在
**Ubuntu 20.04 用户态**中安装、检查依赖并启动冒烟；这不是 UOS 内核验证，旧系统
兼容性由构建期的 ELF 符号上限检查保证。可直接安装用于 **SSH / SFTP / Telnet / 串口** 连接。

> 按「单个 yml 只配置一个架构」的原则，本文件只做 **arm64**。上游 ARM 脚本会
> 把 arm64 与 armv7l 绑在一次运行中，armv7l 交叉重编译失败会连带中断；本 CI
> 因而按格式直接构建并门禁 4 个 arm64 产物。需要 x64 时复制本文件另存一份，见下文。

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
`ci/build-legacy.sh` 的 `[0/7]`。verify 任务使用 `ubuntu:20.04` 用户态，因此也可以直接用 `container:`；但 Docker 容器共享 GitHub runner 的内核，这只是一项 Ubuntu 用户态冒烟检查，不能替代真实 UOS ARM64 安装验证。

## 工作流结构（对应 mysql 的 build-linux-uos20.yml）

| 任务 | 做什么 | 对应 mysql |
|---|---|---|
| `build` | arm64 原生 runner（ubuntu-22.04-arm），宿主机跑 JS actions + `docker run` legacy 容器逐格式构建 arm64，明确门禁 tar.gz/deb/rpm/AppImage；即使失败也上传 `BUILD-INFO.txt` 诊断 artifact | `build` |
| `verify-ubuntu2004` | 在 **Ubuntu 20.04 用户态**中 `apt` 安装 deb、检查全部 ELF 依赖、启动冒烟；这不是 UOS 运行时测试，发布前仍需真实 UOS ARM64 安装验证 | Ubuntu 20.04 用户态冒烟 |
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
├── README.md
└── source/                                  # 可选：仓库内 electerm 完整源码
```

> **源码解析顺序**：工作流优先编译仓库 `source/` 下的完整源码（需有
> `package.json` 与 `build/bin/`，布局与 mysql 项目一致）；若仓库没有 `source/`，
> 则按 `electerm_ref` 从 `source_repo` 克隆。默认构建官方
> `electerm/electerm@v2.10.26`，因此仅维护 CI 配置时不必额外提交整份源码。

## 触发方式

- **push** 到 `master` / `main`：自动构建
- **pull_request** 到 `master` / `main`：自动构建
- **tag** 推 `v*`（如 `v2.10.26`）：构建 → Ubuntu 20.04 用户态验证 → 发布 GitHub Release
- **手动**：Actions → `Linux electerm ARM64 (UOS 20 compatible)` → Run workflow

手动触发参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| electerm_ref | `v2.10.26` | 仓库没有可用 `source/` 时克隆的 tag/分支，同时写入 `BUILD-INFO.txt` |
| source_repo | `electerm/electerm` | 仓库没有可用 `source/` 时的克隆来源，可指定自己的公开 fork |

### 产物

| 架构 | runner | 构建方式 | 必需产物（4 个） |
|---|---|---|---|
| arm64 | ubuntu-22.04-arm | docker run legacy 镜像 (arm64)，逐格式打包 | `electerm-2.10.26-linux-arm64-legacy.deb`、`.tar.gz`、`.AppImage`，以及 `-linux-aarch64-legacy.rpm` |

> armv7l 不属于本工作流目标。这样可避免上游组合脚本在 arm64 已成功后因
> `electron-rebuild --arch armv7l` 失败而整体返回非零；CI 仍会严格要求上述 4 个
> arm64 文件均存在且非空，并对 arm64 tar.gz 做 ABI 校验。

> 官方 v2.10.26 release 中即有同名 legacy 产物，可对照
> <https://github.com/electerm/electerm/releases/tag/v2.10.26> 验证命名。

### 增加 x64（单独一个 yml 文件）

复制 `build-linux-uos20.yml` 为 `build-linux-x64.yml`，改三处：

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

同时将镜像预检步骤中的 `docker pull --platform linux/arm64`、架构断言 `arm64`
对应改为 `linux/amd64`、`amd64`。其余 verify/release 中的 runner 与 deb 文件名也要
对应 x64 调整。artifact 使用与 run 绑定的唯一名称，不需要按架构手工修改。

## 安装与使用

### UOS 20（arm64）

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

- 发布前强制经过 build + verify-ubuntu2004 两个任务；
- tag 与产物实际版本不符时（`BUILD-INFO.txt` 里的 `electerm_version`）会拒绝发布；
- Release 已存在时只补充上传缺失资产（--clobber 覆盖同名）。

## 故障排查

| 现象 | 处理 |
|---|---|
| 日志显示仓库没有 `source/` | 正常：工作流会自动从 `source_repo@electerm_ref` 克隆；若克隆也失败，检查 ref、仓库名与网络 |
| `no matching manifest for linux/arm64` | legacy 镜像没有 ARM64 manifest；镜像预检会提前失败并显示可用平台，需改用带 ARM64 的镜像或改走 x64 工作流 |
| 报 `No matching version found for @electerm/electerm-resource@1.3.7` | 该版本在 npm 不存在，`ci/build-legacy.sh` 会自动修正为 1.3.6；如源码引用其他失效版本，在脚本的依赖调整处固定到实际存在的版本 |
| `electron` 安装报 `EACCES ... electron/...zip` 或 `EACCES ... .ci-electerm-cache/...` | 工作流会以工作区所有者运行容器，并将 `HOME`、npm 与 Electron 缓存统一到工作区的 `.ci-electerm-cache/`。下载 `BUILD-LOG.txt`，确认 `Cache identity` 与缓存目录权限；若嵌套写入探针失败，检查自托管 runner 的工作区挂载权限与 Docker UID/GID 映射，而不要依赖 npm 重试。 |
| `electron-builder` 报 `cannot expand pattern "${env.WORKFLOW_NAME}"` | 上游生成的 `electron-builder.json` 使用 `WORKFLOW_NAME` 作为构建元数据。本 CI 逐格式直接调用 builder，已在容器与脚本中固定传入 `electerm-linux-arm64-legacy`；若仍报错，确认日志的 `WORKFLOW_NAME:` 行不是空值，并确认 Actions 正在运行包含该修复的提交。 |
| `actions/checkout@v6` 报 `GLIBC_2.28 not found` | build 任务误用了 glibc < 2.28 的 `container:`；必须保持宿主机 + `docker run`（本工作流已如此） |
| `sha256sum --check` 校验 `SHA256SUMS.txt` 自身失败 | 使用旧脚本生成了自包含清单；当前脚本显式排除 `SHA256SUMS.txt`，重新构建即可 |
| `verify-ubuntu2004` 的 `xvfb-run` 报 `xauth command not found` | Ubuntu 20.04 使用 `--no-install-recommends` 时要显式安装 `xauth`（本工作流已列出） |
| `verify-ubuntu2004` 装 deb 时 apt 报依赖缺失 | Ubuntu 20.04 仓库缺个别依赖（少见）；可改从 tar.gz 解压运行 |
| 冒烟测试无版本号输出 | 看日志中 electerm 的报错；多为缺运行库，`apt install` 对应库后重跑 |
| 构建任务在「检查构建状态」标红 | `container_build=success` 仅表示诊断脚本正常收尾。查看 `BUILD-INFO.txt` 的 `build_phase`、`failure_reason`、`build_rc`、`missing_artifacts`、`glibc_verify_ok`；同一 artifact 的 `BUILD-LOG.txt` 含完整容器日志，状态门禁也会打印其最后 200 行。当前流程逐格式构建 arm64，某一格式失败不会阻止其他格式上传，但缺任何一个必需文件仍会标红 |
| Release 被拒绝发布 | tag 与 `BUILD-INFO.txt` 的 `electerm_version` 不一致；确认 tag 写成 `v<版本号>` |
| 产物过期 | artifact 保留 14 天；要长期保存请用 tag 发布 Release |
| 报 `build-linux-legacy.js` 不存在 | 所选 ref 太旧，官方还没引入 legacy 构建脚本；选 v2.10.26 或更新版本 |

## 验证方式

- 构建任务内：`readelf` 静态校验全部 ELF 的 glibc/libstdc++ 符号上限（≤ 2.28 / 3.4.25）；
- 验证任务内：在 **Ubuntu 20.04 用户态**上 `apt` 安装 deb、`sha256sum` 校验、逐文件 `ldd` 检查依赖、启动冒烟；这是 Ubuntu 用户态证据，不能等同于 UOS 运行时验证，发布前仍应在真实 UOS 20 ARM64 环境实际安装；
- 每次构建生成排除自身的 `SHA256SUMS.txt`，可在产物目录执行 `sha256sum -c SHA256SUMS.txt` 校验；
- 建议在真机 UOS 20 / Ubuntu 上安装后做一次 SSH 连接冒烟测试。
