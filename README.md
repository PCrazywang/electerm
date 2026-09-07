# electerm 多架构 GitHub Actions 构建（UOS 20 / Ubuntu 兼容）

参考 mysql 项目已验证的 `build-linux-uos20.yml` 结构，用 GitHub Actions 构建
**electerm 2.10.26**（及其同系列版本）的多架构 Linux 安装包，产物经 **Debian 10
（UOS 20 ABI 基线）真机验证**，可直接安装用于 **SSH / SFTP / Telnet / 串口** 连接。

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

## 工作流结构（对应 mysql 的 build-linux-uos20.yml）

| 任务 | 做什么 | 对应 mysql |
|---|---|---|
| `build` | 矩阵构建：x64（ubuntu-latest）与 arm64（ubuntu-22.04-arm 原生），均跑在官方 legacy 构建容器里，产出 tar.gz/deb/rpm/AppImage | `build` |
| `verify-uos20` | 在 **Debian 10**（glibc 2.28，与 UOS 20 同基线）容器中 `apt` 安装 deb、检查全部 ELF 依赖、启动冒烟 | `verify-uos20` |
| `release` | 推 `v*` tag 时，把通过验证的产物发布为 GitHub Release（tag 与版本不符则拒绝） | `release` |

**额外的 glibc 静态校验**（构建任务内）：解包每个 tar.gz，用 `readelf` 扫描全部 ELF
的 **UND 符号**，要求 `GLIBC_ ≤ 2.28`、`GLIBCXX_ ≤ 3.4.25`、且不引用
`__libc_single_threaded`（上游 glibc 2.32 才加入，UOS 20 没有）。校验结果写入
`artifacts/BUILD-INFO.txt`。

## 目录结构

```
.
├── .github/workflows/build-linux-uos20.yml  # GitHub Actions 工作流
├── ci/build-legacy.sh                       # 容器内构建+校验脚本（勿改行尾为 CRLF）
├── .gitattributes                           # 保证 sh/yml 以 LF 提交
└── README.md
```

## 触发方式

- **push** 到 `master` / `main`：自动构建
- **pull_request** 到 `master` / `main`：自动构建
- **tag** 推 `v*`（如 `v2.10.26`）：构建 → Debian 10 验证 → 发布 GitHub Release
- **手动**：Actions → `Linux electerm (UOS 20 compatible)` → Run workflow

手动触发参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| electerm_ref | `v2.10.26` | 分支或 tag，改版本号即可构建其他版本 |
| source_repo | `electerm/electerm` | 构建源，可改为自己的 fork（如 `你的名字/electerm`） |

构建矩阵（改 `strategy.matrix.include` 即可增删架构）：

| 架构 | runner | 构建容器 | 产物（每种架构 4 个） |
|---|---|---|---|
| x64 | ubuntu-latest | legacy 镜像 amd64 | `electerm-2.10.26-linux-amd64-legacy.deb`、`-linux-x64-legacy.tar.gz`、`-linux-x86_64-legacy.rpm`、`-linux-x86_64-legacy.AppImage` |
| arm64 | ubuntu-22.04-arm | legacy 镜像 arm64 | `-linux-arm64-legacy.deb` `.tar.gz` `.AppImage`、`-linux-aarch64-legacy.rpm` |
| armv7l（随 arm64 任务） | 同上 | 同上 | `-linux-armv7l-legacy.deb` `.tar.gz` `.rpm` `.AppImage` |

> 官方 v2.10.26 release 中即有同名 legacy 产物，可对照
> <https://github.com/electerm/electerm/releases/tag/v2.10.26> 验证命名。

## 安装与使用

### UOS 20（Debian 系）

```bash
sudo dpkg -i electerm-2.10.26-linux-amd64-legacy.deb
sudo apt-get -f install -y
```

若还缺运行库，补装：

```bash
sudo apt install -y libnss3 libgtk-3-0 libasound2 libxss1 libxtst6
```

### Ubuntu（18.04 及以上）

```bash
sudo apt install ./electerm-2.10.26-linux-amd64-legacy.deb
```

### AppImage（免安装）

```bash
chmod +x electerm-2.10.26-linux-x86_64-legacy.AppImage
./electerm-2.10.26-linux-x86_64-legacy.AppImage
# 老系统缺 FUSE 时:
sudo apt install -y libfuse2
```

### tar.gz（绿色解压版）

```bash
tar -xzf electerm-2.10.26-linux-x64-legacy.tar.gz
cd electerm-2.10.26-linux-x64-legacy
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
| `verify-uos20` 装 deb 时 apt 报依赖缺失 | buster 仓库缺个别依赖（少见）；可改在验证任务里改从 tar.gz 解压运行 |
| 冒烟测试无版本号输出 | 看日志中 electerm 的报错；多为缺运行库，`apt install` 对应库后重跑 |
| arm64 任务无法使用 `ubuntu-22.04-arm` | 把该矩阵项 runner 改为 `ubuntu-latest` 并在其前加 `docker/setup-qemu-action@v3`（模拟运行较慢） |
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
