# 简介

在 Github 上部署基于 Docker 环境的 self-hosted Runner 的 Shell 脚本

# 功能

1. 自动基于 ghcr.io/actions/actions-runner:latest 添加必要工具构建自定义镜像

2. 自动获取 TOKERN

3. 一键创建容器并注册 Github

4. 增删改查等操作

# 使用

1. 赋予执行权限 `sudo chmod u+x runner.sh`

2. `./runner.sh COMMAND [选项]`
    ```bash
    zcs@dtlqc:~/WORKSPACE/github-runners$ ./runner.sh
    [INFO] 请求组织注册令牌...
    用法: ./runner.sh COMMAND [选项]    其中，[选项] 由 COMMAND 决定，可用 COMMAND 如下所示：

    1. 初始化/扩缩相关命令:
    ./runner.sh init [-n N]                          生成 N 个服务并启动（默认使用 .env 中 RUNNER_COUNT）
                                                     首次会向组织申请注册令牌并持久化到各自卷中
    ./runner.sh scale N                              将 Runner 数量调整为 N；启动 1 .. N，停止其他的（保留卷）

    1. 单实例操作相关命令:
    ./runner.sh register [runner-<id> ...]           注册指定实例；不带参数默认遍历所有已存在实例
    ./runner.sh start [runner-<id> ...]              启动指定实例（会按需注册）；不带参数默认遍历所有已存在实例
    ./runner.sh stop [runner-<id> ...]               直接停止 Runner 容器；不带参数默认遍历所有已存在实例
    ./runner.sh restart [runner-<id> ...]            重启指定实例；不带参数默认遍历所有已存在实例
    ./runner.sh logs runner-<id>                     跟随查看指定实例日志

    1. 查询相关命令:
    ./runner.sh ps                                   查看相关容器的状态
    ./runner.sh list                                 同时显示相关容器的状态 + 注册的 Runner 状态

    1. 删除相关命令:
    ./runner.sh rm|remove|delete [runner-<id> ...]   删除指定实例；不带参数删除全部（需确认，-y 跳过）
    ./runner.sh purge [-y]                           在 remove 的基础上再删除动态生成的 docker-compose.yml 文件

    1. 帮助
    ./runner.sh help                                 显示本说明

    环境变量（来自 .env 文件或交互输入）:
    ORG                      组织名称（必填）
    GH_PAT                   Classic PAT（需 admin:org 权限），用于组织 API 与注册令牌
    RUNNER_LABELS            示例: self-hosted,linux,docker
    RUNNER_GROUP             Runner 组（可选）
    RUNNER_NAME_PREFIX       Runner 命名前缀
    RUNNER_COUNT             start/scale 默认数量
    DISABLE_AUTO_UPDATE      "1" 表示禁用 Runner 自更新
    RUNNER_WORKDIR           工作目录（默认 /runner/_work）
    MOUNT_DOCKER_SOCK        "true"/"1" 表示挂载 /var/run/docker.sock（高权限，谨慎）
    RUNNER_IMAGE             用于生成 compose 的镜像（默认 ghcr.io/actions/actions-runner:latest）
    RUNNER_CUSTOM_IMAGE      自动构建时使用的镜像 tag（可重写）
    PRIVILEGED               是否以 privileged 运行（默认 true，建议: 解决 loop device 问题）
    ADD_SYS_ADMIN_CAP        当不启用 privileged 时，添加 SYS_ADMIN 能力（默认 true）
    MAP_LOOP_DEVICES         是否映射宿主 /dev/loop* 到容器（默认 true）
    LOOP_DEVICE_COUNT        最多映射的 loop 设备数量（默认 4）
    ADD_DEVICE_CGROUP_RULES  当不启用 privileged 时，添加 device_cgroup_rules 以允许 loop（默认 true）
    MAP_KVM_DEVICE           是否映射 /dev/kvm 到容器（默认 true，存在时）
    KVM_GROUP_ADD            将容器加入宿主 /dev/kvm 的 GID（默认 true）
    MOUNT_UDEV_RULES_DIR     为 /etc/udev/rules.d 提供挂载以确保目录存在（默认 true）

    工作流 runs-on 示例: runs-on: [self-hosted, linux, docker]

    提示:
    - 动态生成的 docker-compose.yml 会覆盖同名文件（存量容器不受影响）。
    - 重新 start/scale/up 会复用已有卷，不会丢失 Runner 配置与工具缓存。
    ```