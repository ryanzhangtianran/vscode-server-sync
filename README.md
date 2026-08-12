# vscode-server-sync

把 VS Code Server 从有外网的 **hpc2** 同步到无外网的 **HPC3**，让 Remote-SSH 连接时跳过下载直接启动。

## 解决什么问题

VS Code Remote-SSH 连上远端后，会去 `update.code.visualstudio.com` 下载与本地客户端 commit 完全一致的 server。HPC3 没有外网，这一步必然卡死——典型症状是 `~/.vscode-server/` 下留一堆 **0 字节**的 `vscode-cli-<commit>.tar.gz`。

hpc2 有外网（走 mihomo 代理），且你平时就在用 VS Code 连它，所以那边已经躺着现成的 server。直接复制过去即可。

## 用法

```bash
./sync-vscode-server.sh              # 同步本地最近使用的版本（最常用）
./sync-vscode-server.sh --list       # 看本地有哪些版本
./sync-vscode-server.sh --dry-run    # 只看会传什么，不实际传
```

| 选项 | 说明 |
|---|---|
| `--commit <hash>` | 指定 commit，默认取 `lru.json` 首项（= 最近用过的） |
| `--host <别名>` | 目标主机，默认 `HPC3`（读 `~/.ssh/config`） |
| `--download` | 本地也没有该 commit 时，从微软更新服务器下载（需代理可用） |
| `--force` | 远端已存在也重传 |
| `--list` | 列出本地版本后退出 |
| `--dry-run` | 空跑 |

脚本是幂等的：远端已完整存在就直接跳过，重复执行安全。

## 什么时候要重跑

**VS Code 客户端一升级就要重跑。** 客户端和 server 的 commit 必须逐字节一致，版本号相同也不行。

升级后的标准流程：

1. 用新版 VS Code 连一次 **hpc2**（它有外网，会自动下好新 server）
2. 在 hpc2 上跑 `./sync-vscode-server.sh`
3. 再连 HPC3

如果不想先连 hpc2，也可以直接：

```bash
./sync-vscode-server.sh --commit <新commit> --download
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

## 实测

首次同步 commit `df53daab...`（VS Code 1.132.0）：

```
818M  →  48 秒  @ 16.55 MB/s
```

用 `rsync -a --partial`，中断可续传，重跑只补差异。

## 已知边界

- **只处理 server 本身，不含扩展。** 远端扩展装在 `~/.vscode-server/extensions/`，同样需要外网才能从市场下载。要一并同步的话：

  ```bash
  rsync -a --partial --info=progress2 \
    ~/.vscode-server/extensions/ HPC3:.vscode-server/extensions/
  ```

  注意扩展的 `machineId`/平台相关部分在同架构（都是 linux-x64）下可以直接复用。

- **架构写死 linux-x64**（`--download` 模式的下载链接）。hpc2 和 HPC3 都是 x86_64，够用。
- **依赖 hpc2 的代理**只在 `--download` 模式；纯复制模式不需要外网。
