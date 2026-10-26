---
description: "构建并部署 daidai Fork，通过 SSH 访问持久化 Web 服务。"
---

# 应用部署

[English](README.md) | 中文

## 摘要

本教程要求已经完成[服务器初始化](../README.zh.md)，可以通过 deploy 账号登录 SSH，并已在本地检出此 Fork。流程包括构建 Fork 源码、向 GHCR 发布经过测试的镜像，以及运行带持久化数据的单个 Web 实例。登录后在 Web 设置中填写模型凭证；凭证不得写入镜像或 Git。

## 目录

- [构建与验证](#build-and-verify)
- [发布与部署](#publish-and-deploy)
- [打开 Web 应用](#open-the-web-application)
- [更新与恢复](#update-and-recover)
- [开发说明](#dev-note)

<a id="build-and-verify"></a>

## 构建与验证

在安装了 Docker、Python 3 且有足够内存运行上游构建的电脑上，从仓库根目录执行以下命令。2 核 4GB 部署服务器只拉取和运行镜像。发布时使用已经提交的干净工作区，使镜像中的提交号能够对应源码。

```bash
docker build --platform linux/amd64 \
  --build-arg SOURCE_COMMIT="$(git rev-parse HEAD)" \
  -f deploy/Dockerfile -t daidai:check .
python3 deploy/smoke_image.py daidai:check
```

Dockerfile 固定基础镜像摘要和 pnpm 版本，按冻结的锁文件安装依赖，运行上游产物构建及汇总类型检查，构建 Linux 沙箱二进制，并保留已编译工作区及已安装的依赖，使动态加载的 Web 插件保持原有的对等依赖解析。运行镜像包含源码和开发依赖；构建上下文排除了 Git 元数据、本地环境文件和私钥文件。Debian 软件包仍从当前软件仓库解析；发布后的镜像摘要标识实际部署的内容。冒烟检查使用临时 Docker 资源，验证匿名访问拒绝、令牌登录、前端资源、UID 1001，以及重启及重建容器后保留的标记文件。它不调用模型，也不能证明定时任务能够恢复。

<a id="publish-and-deploy"></a>

## 发布与部署

[镜像工作流](../../.github/workflows/daidai-image.yml) 在此 Fork 的 master 收到推送或手动触发时构建 Linux amd64 镜像，运行冒烟检查，再发布 `ghcr.io/isaac-zheng/daidai:sha-COMMIT`。构建或冒烟失败时不会发布。上游专用工作流可能依赖上游运行器；本工作流使用 GitHub 标准 Ubuntu 运行器。

记录 `docker push` 输出的镜像摘要。确认服务器有权拉取 GHCR 包：公开包无需登录；私有包需要在服务器上单独配置只读包凭证。从 Mac 复制 Compose 文件，将 `SERVER_IP` 替换为服务器地址。

```bash
scp -i "$HOME/.ssh/personal-agent-server.pem" deploy/compose.yaml \
  deploy@SERVER_IP:/opt/daidai/compose.yaml
ssh -i "$HOME/.ssh/personal-agent-server.pem" deploy@SERVER_IP
```

在服务器确认 `id -u deploy` 和 `id -g deploy` 均为 1001；否则先调整镜像用户及目录归属再启动。在 `/opt/daidai/.env` 中填写实际发布的摘要，然后拉取并启动。

```bash
cd /opt/daidai
printf '%s\n' 'DAIDAI_IMAGE=ghcr.io/isaac-zheng/daidai@sha256:REPLACE_WITH_DIGEST' > .env
chmod 600 .env
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=80 agent
```

Compose 仅绑定服务器的 `127.0.0.1:3080`，在未明确停止时自动重启服务，并留出 60 秒关停时间。`/opt/daidai/data` 保存 `DSH_HOME`，包括设置和会话；`/opt/daidai/workspace` 保存任务文件。智能体以 UID/GID 1001 运行，不能访问宿主 Docker。容器重启策略不会重启仍在运行但已不健康的进程，也不能证明中断的模型轮次会恢复。

<a id="open-the-web-application"></a>

## 打开 Web 应用

在 Mac 终端保持以下命令运行。如果本地端口已被占用，SSH 会报错。

```bash
ssh -N -o ExitOnForwardFailure=yes \
  -i "$HOME/.ssh/personal-agent-server.pem" \
  -L 127.0.0.1:3080:127.0.0.1:3080 deploy@SERVER_IP
```

打开服务器日志中打印的 `http://127.0.0.1:3080/?token=...` 链接，将此链接视为登录凭证。进程重启后如要求重新认证，使用新链接。在 Web 设置中填写模型服务凭证，选择 `/workspace` 作为工作目录，再发送一个简短任务。云防火墙保持 3080 端口关闭；此 SSH 访问方案无需域名或公开 Web 端口。

<a id="update-and-recover"></a>

## 更新与恢复

升级前停止服务，将 `data`、`workspace`、`.env` 和 `compose.yaml` 一致地备份到智能体不可写的目录，并保护其中的凭证。记录旧镜像摘要，再把 `.env` 改为经过验证的新摘要，拉取并启动。确认浏览器登录、已有会话、模型回复和定时唤醒。本部署流程不启用自动备份或定时任务。

如果新版本失败，停止服务并在本地查看日志。数据迁移后仅回退镜像可能不安全；应同时恢复升级前的数据备份和对应的旧镜像摘要。不要通过删除应用目录或清理数据卷来修复问题。首次部署与升级均需分别验证浏览器访问、模型调用、定时任务和重启恢复。

<a id="dev-note"></a>

## 开发说明

2026-10-26，Linux amd64 镜像通过上游全部 10 项构建检查，以及容器冒烟检查：插件加载、登录、无效令牌拒绝、前端资源、UID 1001、重启及容器重建后的数据保留。镜像未压缩大小约为 2.8GB。发布及线上应用部署仍待验证。服务器初始化证据见[服务器初始化](../README.zh.md#dev-note)。
