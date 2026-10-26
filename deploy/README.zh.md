---
description: "为 daidai 配置 Debian 13 amd64 服务器，安装 Docker、设置 SSH 部署账户并建立应用目录。"
---

# 服务器初始化

[English](README.md) | 中文

## 概述

[bootstrap.sh](bootstrap.sh) 用于配置一台专用的 Debian 13 amd64 systemd 服务器。以 root 身份运行，并提供一个 OpenSSH 公钥。`--check` 仅读取本机前置条件；`--apply` 修改服务器。本流程不部署 Harness。

[应用部署](application/README.zh.md)

## 目录

- [检查前置条件](#check-prerequisites)
- [执行初始化](#apply-initialization)
- [验证访问](#verify-access)
- [变更与恢复](#changes-and-recovery)
- [本地检查](#local-checks)
- [开发备注](#dev-note)

<a id="check-prerequisites"></a>

## 检查前置条件

连接前，通过云控制台核对服务器的 SSH 主机指纹。初始化过程中保留有效的 root 登录方式。输入文件必须仅包含一个不带 `authorized_keys` 选项的公钥；私钥始终留在本地电脑。

建立可信的 SSH 连接后，在仓库根目录通过标准输入发送脚本，可以不复制文件就完成服务器检查。替换 `SERVER_IP`；示例复用已授权给 root 的公钥。

```bash
ssh -i "$HOME/.ssh/personal-agent-server.pem" root@SERVER_IP \
  'bash -s -- --check /root/.ssh/authorized_keys' < deploy/bootstrap.sh
```

`Preflight passed` 仅确认本机前置条件，不验证软件下载、Docker 启动或新 deploy 账户登录。若 root 已授权多个公钥，请另外提供仅包含一个公钥的文件。

<a id="apply-initialization"></a>

## 执行初始化

阅读 [bootstrap.sh](bootstrap.sh) 后，将同一命令的参数改为 `--apply`。此命令会修改服务器；在新的部署账户通过登录验证前，保留 root 连接。

```bash
ssh -i "$HOME/.ssh/personal-agent-server.pem" root@SERVER_IP \
  'bash -s -- --apply /root/.ssh/authorized_keys' < deploy/bootstrap.sh
```

`deploy` 账户会加入 Docker 组，可以通过 Docker 获得实际等同于 root 的管理能力。脚本不为其配置 sudo 规则或登录密码。不要用此账户作为智能体的执行身份，也不要把宿主机 Docker socket 提供给智能体。

<a id="verify-access"></a>

## 验证访问

在修改 root 访问方式前，打开一个新的本地终端，验证部署账户。成功时必须显示 `deploy`、Docker 服务端版本以及 Compose 版本。

```bash
ssh -i "$HOME/.ssh/personal-agent-server.pem" deploy@SERVER_IP \
  'whoami; docker version --format "{{.Server.Version}}" && docker compose version'
```

<a id="changes-and-recovery"></a>

## 变更与恢复

- 脚本从 Debian 和 [Docker 官方软件源](https://docs.docker.com/engine/install/debian/)安装 CA 证书、curl、Git、OpenSSH 客户端、Docker Engine/CLI、containerd.io、Buildx 和 Compose。首次安装使用软件源中的版本，重复运行使用 `--no-upgrade`；这不属于版本锁定。成功后，Docker 组件版本记录在 `/var/lib/daidai-bootstrap/packages.tsv`。
- Docker 自动启动。新建容器默认使用 `local` 日志驱动，每个容器保留三个 10MB 文件；此限制只覆盖标准输出和错误日志，不限制应用文件或磁盘总占用。详细行为见 [Docker 日志轮转说明](https://docs.docker.com/engine/logging/drivers/local/)。
- 脚本追加指定公钥，不替换已有公钥；仅在目录不存在时创建归属 `deploy` 的 `/opt/daidai/{config,data,workspace}`。已有应用目录的所有权和数据保持不变。容器 UID 映射由应用部署配置负责。
- 若已有 Docker 配置不同、账户设置不受支持、受管理路径是符号链接，或存在冲突的发行版软件包，脚本会报错。请人工检查提示的路径或软件包；脚本不卸载软件包，也不覆盖不同的配置。
- 失败时停止执行，不回滚已完成的修改。解决报错原因后运行 `--check`，再重试 `--apply`。脚本不修改 SSH 策略、root 访问、云防火墙设置、swap、时区，也不执行全系统升级。它不重启服务器或显式重启 Docker；软件包安装可能启动服务，Docker 可能管理自己的网络规则。

<a id="local-checks"></a>

## 本地检查

在安装了 Bash、Python 3 和 OpenSSH 的本地环境中，从仓库根目录运行。[test_bootstrap.py](test_bootstrap.py) 无需 root 权限即可验证输入拒绝和已有公钥、配置保护。安装 ShellCheck 后可以额外执行静态检查。

```bash
bash -n deploy/bootstrap.sh
python3 deploy/test_bootstrap.py
shellcheck deploy/bootstrap.sh
```

<a id="dev-note"></a>

## 开发备注

2026-10-26，一台 Debian 13.2 amd64 服务器通过了预检、首次执行、重复执行、新 deploy SSH 登录以及 `docker run --rm hello-world` 验证。已安装 Docker 29.9.2、Compose 5.6.1、Buildx 0.38.1 和 containerd.io 2.4.2。重复执行未改变软件包版本、公钥内容、Docker 配置、账户 ID、应用目录权限或 Docker 进程及启动时间。本机部署账户的 UID/GID 为 1001；配置应用挂载前，应在每台主机上查询实际 ID。Docker 已启用开机启动；尚未验证服务器重启。应用验收记录见[应用部署](application/README.zh.md#dev-note)。本地辅助函数测试、ShellCheck 和仓库 lint 已通过。本机安装依赖需要设置 NODE_USE_ENV_PROXY=1。文档快速检查通过 20/21 项，清除仅指向 SOCKS 的 ALL_PROXY 环境变量后，doc-sync 通过 42/43 项。剩余仓库引用检查将未改动的 Python 锁文件中的文件大小误判为提交号。
