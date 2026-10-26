# vscode-server-sync

把 VS Code Server 从一台有外网的机器（下称**源机**）同步到任意无外网的 Linux 主机（下称**目标机**），让 Remote-SSH 连接时跳过下载直接启动。

下文以 HPC2（源机）→ HPC3（目标机）为例，换成别的服务器只需 `--host <别名>`。

## 前提

- 源机能免密 SSH 到目标机（脚本用 `BatchMode`，不会弹密码）：在源机 `~/.ssh/config` 里配好目标机的 Host，并装好公钥
- 目标机是 Linux，架构为 x86_64 / aarch64 / armv7l。脚本会读目标机的架构：和源机一样就直接复用源机已有的 server；不一样就必须加 `--download`，按目标机架构下载
- 两边都有 `rsync`；目标机有 `python3`（用来改 `lru.json`）
- 目标机的 glibc 满足 VS Code Server 的最低要求（老系统如 CentOS 7 可能跑不起来，这与是否联网无关）
- 只处理 Stable 版，不处理 Insiders

## 解决什么问题

VS Code Remote-SSH 连上远端后，会去 `update.code.visualstudio.com` 下载与本地客户端 commit 完全一致的 server。目标机无法连网，这一步必然卡死——典型症状是 `~/.vscode-server/` 下留一堆 **0 字节**的 `vscode-cli-<commit>.tar.gz`。

## 用法

直接运行、不带参数，会进入交互菜单（类似 3x-ui）：

```
+----------------------------------------------+
|  VS Code Server 同步工具                     |
|  目标机: HPC3    本机架构: x64               |
+----------------------------------------------+
|  1. 同步最近使用的版本                       |
|  2. 同步指定 commit                          |
|  3. 列出本机版本                             |
+----------------------------------------------+
|  4. 切换目标机                               |
|  5. 允许下载 (--download): 关                |
|  6. 强制重传 (--force):    关                |
+----------------------------------------------+
|  0. 退出                                     |
+----------------------------------------------+
请输入选择 [0-6]:
```

带参数则直接执行，不进菜单（适合脚本/cron）：

```bash
./sync-vscode-server.sh --host HPC3  # 同步本地最近使用的版本（最常用）
./sync-vscode-server.sh --list       # 看本地有哪些版本
./sync-vscode-server.sh --dry-run    # 只看会传什么，不实际传
```

| 选项 | 说明 |
|---|---|
| `--commit <hash>` | 指定 commit，默认取 `lru.json` 首项（= 最近用过的） |
| `--host <别名>` | 目标机的 ssh 别名或地址，默认 `HPC3`（读 `~/.ssh/config`） |
| `--download` | 本机没有可用的该 commit 时，按**目标机**架构下载到临时目录，传完即删，不动本机 `~/.vscode-server`（需能联网） |
| `--force` | 远端已存在也重传 |
| `--list` | 列出本地版本后退出 |
| `--dry-run` | 空跑 |

脚本是幂等的：远端已完整存在就直接跳过，重复执行安全。

## 什么时候要重跑

**VS Code 客户端一升级就要重跑。** 客户端和 server 的 commit 必须逐字节一致，版本号相同也不行。

升级后的标准流程：

1. 用新版 VS Code 连一次源机（它有外网，会自动下好新 server）
2. 在源机上跑 `./sync-vscode-server.sh --host <目标机>`
3. 再连目标机

如果不想先连源机，也可以在源机上直接：

```bash
./sync-vscode-server.sh --host <目标机> --commit <新commit> --download
```

commit 可以在 VS Code 里 `Help → About` 查到。

## 传了什么

对应 VS Code 1.86+ 的远端布局：

```
~/.vscode-server/
├── code-<commit>                          CLI 二进制（32M）
└── cli/
    └── servers/
        ├── lru.json                       最近使用列表，脚本会把本 commit 置顶
        └── Stable-<commit>/
            └── server/                    服务端本体（约 700-800M）
                ├── bin/code-server
                ├── node
                └── ...
```

收尾动作还包括：修正可执行位、删除 `~/.vscode-server/` 下 0 字节的下载残留（否则客户端可能把它当缓存用，导致继续报错）。
