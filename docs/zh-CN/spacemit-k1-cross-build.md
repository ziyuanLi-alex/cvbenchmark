# SpacemiT K1 RVV 交叉编译与性能测试

本文记录本项目以 OpenCV `5.x` 分支为基准，在 Ubuntu x86_64 工作站上交叉编译，并在 SpacemiT K1 上运行性能测试的流程。

## 主机与环境变量

两台机器都通过 Tailscale 访问。主机名、IP 和用户名属于个人环境，不写入仓库；请在 shell rc（`~/.bashrc` 或 `~/.zshrc`）中导出：

```bash
export BUILD_HOST=<workstation>   # Ubuntu x86_64 开发工作站
export K1_HOST=<k1-board>         # SpacemiT K1，Bianbu / riscv64
```

也可以只用 `~/.ssh/config` 定义同名 Host 别名（含 `User`、`IdentityFile`），此时无需导出变量，直接把 `$BUILD_HOST` / `$K1_HOST` 替换成别名即可。下文统一用 `$BUILD_HOST` 与 `$K1_HOST` 指代两台机器。

## 流程概览

```text
本机编辑源码和工作流
        ↓ SSH / rsync
$BUILD_HOST：SpacemiT LLVM 工具链交叉编译
        ↓ 传送 RISC-V 二进制
$K1_HOST：在实体 K1 上运行 OpenCV perf 测试，生成 XML
        ↓ 取回 XML
本机或工作站：benchmark.py score 汇总分数
```

编译器运行在 Linux x86_64 上，用 SpacemiT Linux/glibc 工具链生成 RISC-V Linux ELF 程序。测试计时必须在实体 K1 上完成。

## 当前目录和源码状态

正式工作目录是工作站上的 `~/cvbenchmark` Git checkout。`~/cvbenchmark-k1-build` 是旧的 5.0.0 staging 目录，不作为 5.x 的源码或构建入口；保留旧构建产物作对照。

本地 `opencv` 和 `opencv_extra` 应分别检出各自的 `5.x` 分支。每次构建要记录两者的实际提交号。OpenCV 5.x 是滚动分支，单写 `5.x` 不足以唯一标识一份测量结果。正式构建应从父仓库的子模块指针或记录的 commit 构建，并将同一源码状态同步到工作站。

K1 原有测试数据仍来自 4.x checkout。正式跑分前应把工作站上 `opencv_extra` 5.x 的 `testdata/` 同步到独立目录，避免覆盖旧数据或误用旧版本：

```text
$K1_HOST:~/cvbenchmark-k1-5x/testdata
```

## SSH 检查

检查两台主机都能用密钥登录（Tailscale 需保持在线）：

```bash
ssh -o BatchMode=yes "$BUILD_HOST" 'hostname; uname -m'
ssh -o BatchMode=yes "$K1_HOST" 'hostname; uname -m'
```

期望工作站返回 `x86_64`，K1 返回 `riscv64`。公钥已安装，通常不需要重复运行 `ssh-copy-id`。若 `ssh` 无法解析主机名，检查 Tailscale 分配的 IP/主机名是否已写入 `~/.ssh/config` 或 shell rc。

## 同步源码和工作流文件

在本机仓库根目录编辑工作流后，将文件同步到工作站的正式 checkout：

```bash
rsync -a scripts/ "$BUILD_HOST":~/cvbenchmark/scripts/
rsync -a cmake/toolchains/spacemit-k1-llvm.cmake \
  "$BUILD_HOST":~/cvbenchmark/cmake/toolchains/
rsync -a docs/zh-CN/ "$BUILD_HOST":~/cvbenchmark/docs/zh-CN/
rsync -a benchmark.py "$BUILD_HOST":~/cvbenchmark/benchmark.py
```

确认工作站工作区没有要保留的未提交子模块修改后，初始化并检出两份 5.x 子模块：

```bash
ssh "$BUILD_HOST"
cd ~/cvbenchmark
git submodule update --init opencv opencv_extra
git -C opencv checkout 5.x
git -C opencv_extra checkout 5.x
```

如果工作站不能访问 GitHub，应通过本地 Git bundle 或源码归档传递对应提交；不要用旧的 5.0.0 staging 源码代替 5.x。

## 工作站交叉编译

SpacemiT 工具链包不入库，需自行下载解压。把解压目录写进 shell rc，避免在仓库里硬编码路径：

```bash
export SPACEMIT_TOOLCHAIN_ROOT="$HOME/toolchains/spacemit-toolchain-linux-glibc-x86_64-v1.2.4"
```

进入正式 checkout，设置工具链路径并构建 `core`、`imgproc`：

```bash
cd ~/cvbenchmark
export SPACEMIT_TOOLCHAIN_ROOT="$HOME/toolchains/spacemit-toolchain-linux-glibc-x86_64-v1.2.4"
OPENCV_VERSION=5.x PERF_MODULES=core,imgproc bash scripts/cross-build-k1.sh
```

脚本默认 OpenCV 版本为 `5.x`、构建类型为 `Release`。可通过 `JOBS=8` 限制并行编译任务数，通过 `PERF_MODULES=core,imgproc,features` 选择模块。完整模块列表为：

```text
core,imgproc,features,objdetect,calib,stereo,geometry,dnn
```

构建目录为 `build_k1_5.x_release/`，部署文件在 `bundle/`，压缩包为 `cvbenchmark-k1-5.x-release.tar.gz`。bundle 会保存 OpenCV 与 `opencv_extra` 的实际 commit 和模块清单。工具链以 K1/X60 参数启用 RVV，并使用匹配的 Linux/glibc sysroot。

## 部署并在 K1 上运行

从工作站将 bundle 同步到 K1：

```bash
rsync -a ~/cvbenchmark/build_k1_5.x_release/bundle/ \
  "$K1_HOST":~/cvbenchmark-k1-5x/
```

先将与 OpenCV 5.x 对应的测试数据同步到 K1（首次或测试数据有更新时执行）：

```bash
rsync -a ~/cvbenchmark/opencv_extra/testdata/ \
  "$K1_HOST":~/cvbenchmark-k1-5x/testdata/
```

在 K1 检查运行库并执行测试：

```bash
ssh "$K1_HOST"
cd ~/cvbenchmark-k1-5x
ldd bin/opencv_perf_core
OPENCV_TEST_DATA_PATH="$HOME/cvbenchmark-k1-5x/testdata" \
  CPU_MODEL="SpacemiT K1" bash run-perf.sh
```

`run-perf.sh` 按照 `modules.txt` 逐模块运行测试，默认每项强制采集 20 个样本。结果写入 `results/`，文件名形如 `core-SpacemiT K1.xml`。可设置 `PERF_THREADS` 固定测试线程数。长时间跑分前确认 `ldd` 没有缺库，并保持 K1 空闲、供电和散热状态稳定。

## 汇总分数

把 K1 XML 结果复制到对应版本目录。OpenCV 是滚动分支，建议目录名使用版本加 commit 短哈希，避免不同时间的 `5.x` 结果互相覆盖；如沿用 `perf/5.x/`，需同时保存完整 commit 信息：

```bash
rsync -a "$K1_HOST":~/cvbenchmark-k1-5x/results/ ./perf/5.x/
cd <仓库根目录>
python3 benchmark.py score --version 5.x --modules core imgproc
```

完整总分需要八个模块的 K1 XML，以及由**完全相同的 OpenCV commit**生成的基准 CPU XML。仓库内 `perf/5.0.0/` 的基准对应旧 tag，不能用于当前 `5.x` 提交；应先为选定的 5.x commit 重新生成基准。生成图表还需维护 `processor.json`。

## 验证状态

- OpenCV `112ca450` / `opencv_extra` `9c5eefa1` 已在本机和工作站对齐；5.x 的 `core`、`imgproc` 已重新交叉编译。
- K1 已部署对应 bundle；动态依赖检查通过，单项 smoke test 通过，运行时报告 OpenCV 5.1.0-dev、RVV HAL 和 RVV CPU feature。
- 正式跑分前仍需把 5.x 测试数据同步到 K1 的独立目录，并为完全相同的 OpenCV commit 生成基准 CPU XML。
