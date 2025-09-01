#!/usr/bin/env python3
import argparse
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# Defaults (align with runner.sh)
COMPOSE_FILE_DEFAULT = "docker-compose.yml"
ENV_FILE_DEFAULT = os.environ.get("ENV_FILE", ".env")
REG_TOKEN_CACHE_FILE_DEFAULT = os.environ.get("REG_TOKEN_CACHE_FILE", ".reg_token.cache")
REG_TOKEN_CACHE_TTL_DEFAULT = int(os.environ.get("REG_TOKEN_CACHE_TTL", "300"))
DOCKERFILE_HASH_FILE_DEFAULT = os.environ.get("DOCKERFILE_HASH_FILE", ".dockerfile.sha256")

# Simple logger

def info(msg: str) -> None:
    print(f"[INFO] {msg}")


def warn(msg: str) -> None:
    print(f"[WARN] {msg}", file=sys.stderr)


def err(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr)


# Env handling

def load_env(env_path: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            if not line or re.match(r"^[\s#]", line):
                continue
            if "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def save_env(env_path: Path, updates: Dict[str, str]) -> None:
    env = load_env(env_path)
    env.update({k: v for k, v in updates.items() if v is not None})
    lines = [f"{k}={v}" for k, v in env.items()]
    tmp = env_path.with_suffix(env_path.suffix + ".tmp")
    tmp.write_text("\n".join(lines) + "\n")
    try:
        tmp.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except Exception:
        pass
    tmp.replace(env_path)


def prompt_tty(prompt: str, secret: bool = False) -> str:
    try:
        with open("/dev/tty", "r+") as tty:
            if not secret:
                tty.write(prompt)
                tty.flush()
                return tty.readline().rstrip("\n")
    except Exception:
        pass
    # Fallbacks
    if secret:
        import getpass

        return getpass.getpass(prompt)
    return input(prompt)


def env_bool(name: str, default: str = "false") -> bool:
    v = os.environ.get(name, default).lower()
    return v in {"1", "true", "yes", "y"}


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except ValueError:
        return default


class Context:
    def __init__(self) -> None:
        self.cwd = Path.cwd()
        self.env_file = Path(os.environ.get("ENV_FILE", ENV_FILE_DEFAULT))
        self.compose_file = Path(os.environ.get("COMPOSE_FILE", COMPOSE_FILE_DEFAULT))
        self.reg_token_cache_file = Path(
            os.environ.get("REG_TOKEN_CACHE_FILE", REG_TOKEN_CACHE_FILE_DEFAULT)
        )
        self.reg_token_cache_ttl = REG_TOKEN_CACHE_TTL_DEFAULT
        self.dockerfile_hash_file = Path(
            os.environ.get("DOCKERFILE_HASH_FILE", DOCKERFILE_HASH_FILE_DEFAULT)
        )
        # Load .env-like into process env
        env_kv = load_env(self.env_file)
        for k, v in env_kv.items():
            os.environ.setdefault(k, v)

    # Compose picker
    def compose_cmd(self) -> List[str]:
        try:
            subprocess.run(["docker", "compose", "version"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return ["docker", "compose"]
        except Exception:
            pass
        if shutil_which("docker-compose"):
            return ["docker-compose"]
        die("docker compose (v2) 或 docker-compose 未安装。")
        return []


# Utility

def shutil_which(cmd: str) -> Optional[str]:
    from shutil import which

    return which(cmd)


def run(cmd: List[str], check: bool = True, capture: bool = False, text: bool = True, env: Optional[Dict[str, str]] = None, input_data: Optional[str] = None) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=check, capture_output=capture, text=text, env=env, input=input_data)


def die(msg: str, code: int = 1) -> None:
    err(msg)
    sys.exit(code)


# GitHub API helpers

def ensure_org_pat(ctx: Context) -> Tuple[str, str]:
    org = os.environ.get("ORG", "")
    pat = os.environ.get("GH_PAT", "")
    wrote = False
    if not org:
        while True:
            org = prompt_tty("请输入组织名（与 github.com 上一致）: ").strip()
            if org:
                wrote = True
                break
            warn("组织名不能为空，请重试。")
    if not pat:
        while True:
            pat = prompt_tty("请输入 Classic PAT（admin:org）（输入不可见）: ", secret=True).strip()
            if pat:
                wrote = True
                break
            warn("PAT 不能为空，请重试。")
    os.environ["ORG"] = org
    os.environ["GH_PAT"] = pat
    if wrote:
        save_env(ctx.env_file, {"ORG": org, "GH_PAT": pat})
    return org, pat


def gh_request(method: str, path: str, body: Optional[dict] = None) -> dict:
    org = os.environ.get("ORG", "")
    pat = os.environ.get("GH_PAT", "")
    if not org or not pat:
        die("需要 ORG 和 GH_PAT！")
    url = f"https://api.github.com/orgs/{urllib.parse.quote(org)}/{path.lstrip('/')}"
    headers = {
        "Authorization": f"Bearer {pat}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "runner.py",
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, method=method.upper(), headers=headers, data=data)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        die(f"GitHub API 错误: {e.code} {e.reason}")
    except urllib.error.URLError as e:
        die(f"GitHub API 网络错误: {e.reason}")


def gh_fetch_reg_token(ctx: Context) -> str:
    # cache
    now = int(time.time())
    if ctx.reg_token_cache_file.exists():
        try:
            lines = ctx.reg_token_cache_file.read_text().splitlines()
            ts = int(lines[0]) if lines else 0
            tok = lines[1] if len(lines) > 1 else ""
            if tok and now - ts < ctx.reg_token_cache_ttl:
                return tok
        except Exception:
            pass
    # existing env token
    env_tok = os.environ.get("REG_TOKEN", "")
    if env_tok:
        ctx.reg_token_cache_file.write_text(f"{now}\n{env_tok}\n")
        return env_tok
    ensure_org_pat(ctx)
    print("[INFO] 请求组织注册令牌...", file=sys.stderr)
    data = gh_request("POST", "/actions/runners/registration-token")
    tok = data.get("token", "")
    if not tok:
        die("获取注册令牌失败！")
    ctx.reg_token_cache_file.write_text(f"{now}\n{tok}\n")
    return tok


def gh_list_runners() -> List[dict]:
    data = gh_request("GET", "/actions/runners?per_page=100")
    return data.get("runners", [])


def gh_get_runner_id_by_name(name: str) -> Optional[int]:
    for r in gh_list_runners():
        if r.get("name") == name:
            return int(r.get("id"))
    return None


def gh_delete_runner_by_id(rid: int) -> None:
    gh_request("DELETE", f"/actions/runners/{rid}")


# Compose rendering and helpers

def effective_prefix() -> str:
    p = os.environ.get("RUNNER_NAME_PREFIX", "")
    p = p.rstrip("-")
    return f"{p}-" if p else ""


def pick_runner_image(ctx: Context, cmd: str) -> str:
    base = os.environ.get("RUNNER_IMAGE", "ghcr.io/actions/actions-runner:latest")
    custom = os.environ.get("RUNNER_CUSTOM_IMAGE", "qc-actions-runner:v0.0.1")
    current = base
    if cmd not in {"init", "scale", "start", "stop", "restart", "logs"}:
        return current
    dockerfile = ctx.cwd / "Dockerfile"
    if dockerfile.exists():
        new_hash = ""
        try:
            # Prefer sha256sum
            res = run(["sha256sum", str(dockerfile)], check=False, capture=True)
            if res.returncode == 0 and res.stdout:
                new_hash = res.stdout.strip().split()[0]
            else:
                res = run(["shasum", "-a", "256", str(dockerfile)], check=False, capture=True)
                if res.returncode == 0 and res.stdout:
                    new_hash = res.stdout.strip().split()[0]
        except Exception:
            pass
        old_hash = ctx.dockerfile_hash_file.read_text().strip() if ctx.dockerfile_hash_file.exists() else ""
        if new_hash and new_hash != old_hash:
            info(f"检测到 Dockerfile 变更，开始构建 {custom} 镜像")
            run(["docker", "build", "-t", custom, "."], check=True)
            ctx.dockerfile_hash_file.write_text(new_hash)
            info(f"构建完成。本次将使用 {custom} 作为镜像")
            return custom
        # Prefer existing custom image
        res = run(["docker", "image", "inspect", custom], check=False, capture=True)
        if res.returncode == 0:
            return custom
        return base
    else:
        return base


def render_compose(ctx: Context, count: int, runner_image: str, reg_token: str) -> None:
    if count < 1:
        die("生成 compose 失败：数量必须 >= 1！")
    pfx = effective_prefix()
    # Collect env values
    RUNNER_LABELS = os.environ.get("RUNNER_LABELS", "self-hosted,linux,docker")
    RUNNER_GROUP = os.environ.get("RUNNER_GROUP", "Default")
    DISABLE_AUTO_UPDATE = os.environ.get("DISABLE_AUTO_UPDATE", "false")
    RUNNER_WORKDIR = os.environ.get("RUNNER_WORKDIR", "")
    HTTP_PROXY = os.environ.get("HTTP_PROXY", "")
    HTTPS_PROXY = os.environ.get("HTTPS_PROXY", "")
    PRIVILEGED = env_bool("PRIVILEGED", "true")
    ADD_SYS_ADMIN_CAP = env_bool("ADD_SYS_ADMIN_CAP", "true")
    MAP_LOOP_DEVICES = env_bool("MAP_LOOP_DEVICES", "true")
    LOOP_DEVICE_COUNT = env_int("LOOP_DEVICE_COUNT", 4)
    ADD_DEVICE_CGROUP_RULES = env_bool("ADD_DEVICE_CGROUP_RULES", "true")
    MAP_KVM_DEVICE = env_bool("MAP_KVM_DEVICE", "true")
    KVM_GROUP_ADD = env_bool("KVM_GROUP_ADD", "true")
    MOUNT_UDEV_RULES_DIR = env_bool("MOUNT_UDEV_RULES_DIR", "true")
    MOUNT_DOCKER_SOCK = env_bool("MOUNT_DOCKER_SOCK", os.environ.get("MOUNT_DOCKER_SOCK", "false"))

    lines: List[str] = []
    ap = lines.append
    ap("x-runner-base: &runner_base")
    ap(f"  image: {runner_image}")
    ap("  restart: unless-stopped")
    ap("  environment: &runner_env")
    ap(f"    RUNNER_ORG_URL: \"https://github.com/{os.environ.get('ORG','')}\"")
    ap(f"    RUNNER_TOKEN: \"{reg_token}\"")
    ap(f"    RUNNER_LABELS: \"{RUNNER_LABELS}\"")
    ap(f"    RUNNER_GROUP: \"{RUNNER_GROUP}\"")
    ap(f"    RUNNER_REMOVE_ON_STOP: \"false\"")
    ap(f"    DISABLE_AUTO_UPDATE: \"{DISABLE_AUTO_UPDATE}\"")
    ap(f"    RUNNER_WORKDIR: \"{RUNNER_WORKDIR}\"")
    ap(f"    HTTP_PROXY: \"{HTTP_PROXY}\"")
    ap(f"    HTTPS_PROXY: \"{HTTPS_PROXY}\"")
    ap("    NO_PROXY: localhost,127.0.0.1,.internal")
    ap("  network_mode: host")
    if PRIVILEGED:
        ap("  privileged: true")
    else:
        if ADD_SYS_ADMIN_CAP:
            ap("  cap_add:")
            ap("    - SYS_ADMIN")
        if ADD_DEVICE_CGROUP_RULES:
            ap("  device_cgroup_rules:")
            ap("    - 'b 7:* rwm'")
            ap("    - 'c 10:237 rwm'")
            ap("    - 'c 10:232 rwm'")
    printed_devices = False
    if MAP_LOOP_DEVICES:
        for j in range(0, LOOP_DEVICE_COUNT):
            if Path(f"/dev/loop{j}").exists():
                if not printed_devices:
                    ap("  devices:")
                    printed_devices = True
                    if Path("/dev/loop-control").exists():
                        ap("    - /dev/loop-control:/dev/loop-control")
                ap(f"    - /dev/loop{j}:/dev/loop{j}")
    if MAP_KVM_DEVICE and Path("/dev/kvm").exists():
        if not printed_devices:
            ap("  devices:")
            printed_devices = True
        ap("    - /dev/kvm:/dev/kvm")
    if KVM_GROUP_ADD and Path("/dev/kvm").exists():
        try:
            import stat as pystat, os as pyos

            st = os.stat("/dev/kvm")
            kvm_gid = st.st_gid
            ap("  group_add:")
            ap(f"    - {kvm_gid}")
        except Exception:
            pass
    if MOUNT_DOCKER_SOCK:
        ap("  volumes:")
        ap("    - /var/run/docker.sock:/var/run/docker.sock")
    else:
        ap("  # 如需在 job 中使用 docker 命令，需挂载宿主 docker.sock（高权限，谨慎）")
        ap("  # volumes:")
        ap("  #   - /var/run/docker.sock:/var/run/docker.sock")

    ap("")
    ap("services:")
    for i in range(1, count + 1):
        svc = f"{pfx}runner-{i}"
        vname = f"{svc}-data"
        ap(f"  {svc}:")
        ap("    <<: *runner_base")
        ap(f"    container_name: \"{svc}\"")
        ap("    command: [\"/home/runner/run.sh\"]")
        ap("    environment:")
        ap("      <<: *runner_env")
        ap(f"      RUNNER_NAME: \"{svc}\"")
        ap("    volumes:")
        ap(f"      - {vname}:/home/runner")
        if MOUNT_UDEV_RULES_DIR:
            ap(f"      - {svc}-udev-rules:/etc/udev/rules.d")
    ap("")
    ap("volumes:")
    for i in range(1, count + 1):
        ap(f"  {pfx}runner-{i}-data:")
        if MOUNT_UDEV_RULES_DIR:
            ap(f"  {pfx}runner-{i}-udev-rules:")

    ctx.compose_file.write_text("\n".join(lines) + "\n")
    os.environ["RUNNER_IMAGE"] = runner_image
    os.environ["REG_TOKEN"] = reg_token


# Docker/compose wrappers

def compose_up(ctx: Context, services: List[str]) -> None:
    run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "up", "-d", *services], check=True)


def compose_stop(ctx: Context, services: List[str]) -> None:
    run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "stop", *services], check=False)


def compose_restart(ctx: Context, services: List[str]) -> None:
    run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "restart", *services], check=False)


def compose_logs(ctx: Context, services: List[str]) -> None:
    run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "logs", "-f", *services], check=False)


def compose_ps(ctx: Context) -> None:
    run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "ps"], check=False)


def compose_services(ctx: Context, all_services: bool = True) -> List[str]:
    try:
        res = run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "ps", "--services", *( ["--all"] if all_services else [] )], check=True, capture=True)
        return [l for l in res.stdout.splitlines() if l.strip()]
    except Exception:
        return []


def highest_existing_index(ctx: Context) -> int:
    pfx = effective_prefix() + "runner-"
    if not ctx.compose_file.exists():
        return 0
    max_idx = 0
    for svc in compose_services(ctx):
        if svc.startswith(pfx):
            tail = svc[len(pfx):]
            if tail.isdigit():
                n = int(tail)
                if n > max_idx:
                    max_idx = n
    return max_idx


def list_existing_containers(ctx: Context) -> List[str]:
    pref = effective_prefix() + "runner-"
    services: List[str] = []
    if ctx.compose_file.exists():
        services = [s for s in compose_services(ctx) if s.startswith(pref)]
        if services:
            return services
    # Fallback: query docker ps -a for containers named like prefix
    if shutil_which("docker"):
        try:
            res = run(["docker", "ps", "-a", "--format", "{{.Names}}"], check=False, capture=True)
            names = [l.strip() for l in res.stdout.splitlines() if l.strip()]
            return [n for n in names if re.match(rf"^{re.escape(pref)}[0-9]+$", n)]
        except Exception:
            return []
    return []


def runner_is_configured(ctx: Context, idx: int) -> bool:
    svc = f"{effective_prefix()}runner-{idx}"
    if not ctx.compose_file.exists():
        return False
    try:
        res = run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "run", "--rm", "--no-deps", svc, "bash", "-lc", "test -f /home/runner/.runner && test -f /home/runner/.credentials"], check=False)
        return res.returncode == 0
    except Exception:
        return False


def runner_register(ctx: Context, idx: int, force: bool = False) -> None:
    org, _ = ensure_org_pat(ctx)
    token = gh_fetch_reg_token(ctx)
    name = f"{effective_prefix()}runner-{idx}"
    labels = os.environ.get("RUNNER_LABELS", "self-hosted,linux,docker")
    group = os.environ.get("RUNNER_GROUP", "Default")
    workdir = os.environ.get("RUNNER_WORKDIR", "")
    disable_auto_update = env_bool("DISABLE_AUTO_UPDATE", os.environ.get("DISABLE_AUTO_UPDATE", "false"))

    cfg = ["/home/runner/config.sh", "--url", f"https://github.com/{org}", "--token", token, "--name", name, "--labels", labels, "--runnergroup", group, "--unattended", "--replace"]
    if workdir:
        cfg += ["--work", workdir]
    if disable_auto_update:
        cfg += ["--disableupdate"]

    if force:
        info(f"在 Github 上重新注册(替换): {name}")
    else:
        info(f"在 Github 上注册: {name}")
    run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "run", "--rm", "--no-deps", name, "bash", "-lc", " ".join(shlex.quote(c) for c in cfg)], check=True)


# Commands

def cmd_help(_: argparse.Namespace, ctx: Context) -> None:
    colw = 48
    pfx = effective_prefix()
    print("用法: ./runner.py COMMAND [选项]    其中，[选项] 由 COMMAND 决定，可用 COMMAND 如下所示：")
    print()

    print("1. 初始化/扩缩相关命令:")
    print(f"  {'./runner.py init [-n N]'.ljust(colw)} 生成 N 个服务并启动（默认使用 .env 中 RUNNER_COUNT）")
    print(f"  {''.ljust(colw)} 首次会向组织申请注册令牌并持久化到各自卷中")
    print(f"  {'./runner.py scale N'.ljust(colw)} 将 Runner 数量调整为 N；启动 1 .. N，停止其他的（保留卷）")
    print()

    print("2. 单实例操作相关命令:")
    print(f"  {'./runner.py register [' + pfx + 'runner-<id> ...]'.ljust(colw)} 注册指定实例；不带参数默认遍历所有已存在实例")
    print(f"  {'./runner.py start [' + pfx + 'runner-<id> ...]'.ljust(colw)} 启动指定实例（会按需注册）；不带参数默认遍历所有已存在实例")
    print(f"  {'./runner.py stop [' + pfx + 'runner-<id> ...]'.ljust(colw)} 直接停止 Runner 容器；不带参数默认遍历所有已存在实例")
    print(f"  {'./runner.py restart [' + pfx + 'runner-<id> ...]'.ljust(colw)} 重启指定实例；不带参数默认遍历所有已存在实例")
    print(f"  {'./runner.py logs ' + pfx + 'runner-<id>' .ljust(colw)} 跟随查看指定实例日志")
    print()

    print("3. 查询相关命令:")
    print(f"  {'./runner.py ps'.ljust(colw)} 查看相关容器的状态")
    print(f"  {'./runner.py list'.ljust(colw)} 同时显示相关容器的状态 + 注册的 Runner 状态")
    print()

    print("4. 删除相关命令:")
    print(f"  {'./runner.py rm|remove|delete [' + pfx + 'runner-<id> ...]'.ljust(colw)} 删除指定实例；不带参数删除全部（需确认，-y 跳过）")
    print(f"  {'./runner.py purge [-y]'.ljust(colw)} 在 remove 的基础上再删除动态生成的 docker-compose.yml 文件")
    print()

    print("5. 帮助")
    print(f"  {'./runner.py help'.ljust(colw)} 显示本说明")
    print()

    print("环境变量（来自 .env 文件或交互输入）:")
    keyw = 24
    def kv(k: str, v: str) -> None:
        print(f"  {k.ljust(keyw)} {v}")
    kv("ORG", "组织名称（必填）")
    kv("GH_PAT", "Classic PAT（需 admin:org 权限），用于组织 API 与注册令牌")
    kv("RUNNER_LABELS", "示例: self-hosted,linux,docker")
    kv("RUNNER_GROUP", "Runner 组（可选）")
    kv("RUNNER_NAME_PREFIX", "Runner 命名前缀")
    kv("RUNNER_COUNT", "start/scale 默认数量")
    kv("DISABLE_AUTO_UPDATE", '"1" 表示禁用 Runner 自更新')
    kv("RUNNER_WORKDIR", "工作目录（默认 /runner/_work）")
    kv("MOUNT_DOCKER_SOCK", '"true"/"1" 表示挂载 /var/run/docker.sock（高权限，谨慎）')
    kv("RUNNER_IMAGE", "用于生成 compose 的镜像（默认 ghcr.io/actions/actions-runner:latest）")
    kv("RUNNER_CUSTOM_IMAGE", "自动构建时使用的镜像 tag（可重写）")
    kv("PRIVILEGED", "是否以 privileged 运行（默认 true，建议: 解决 loop device 问题）")
    kv("ADD_SYS_ADMIN_CAP", "当不启用 privileged 时，添加 SYS_ADMIN 能力（默认 true）")
    kv("MAP_LOOP_DEVICES", "是否映射宿主 /dev/loop* 到容器（默认 true）")
    kv("LOOP_DEVICE_COUNT", "最多映射的 loop 设备数量（默认 4）")
    kv("ADD_DEVICE_CGROUP_RULES", "当不启用 privileged 时，添加 device_cgroup_rules 以允许 loop（默认 true）")
    kv("MAP_KVM_DEVICE", "是否映射 /dev/kvm 到容器（默认 true，存在时）")
    kv("KVM_GROUP_ADD", "将容器加入宿主 /dev/kvm 的 GID（默认 true）")
    kv("MOUNT_UDEV_RULES_DIR", "为 /etc/udev/rules.d 提供挂载以确保目录存在（默认 true）")

    print()
    print("工作流 runs-on 示例: runs-on: [self-hosted, linux, docker]")

    print()
    print("提示:")
    print("- 动态生成的 docker-compose.yml 会覆盖同名文件（存量容器不受影响）。")
    print("- 重新 start/scale/up 会复用已有卷，不会丢失 Runner 配置与工具缓存。")


def cmd_ps(_: argparse.Namespace, ctx: Context) -> None:
    if ctx.compose_file.exists():
        compose_ps(ctx)
    else:
        if shutil_which("docker"):
            run(["docker", "ps", "-a"], check=False)
        else:
            info(f"未找到 {ctx.compose_file.name}，且未检测到 docker 命令，无法查询状态。")


def cmd_list(_: argparse.Namespace, ctx: Context) -> None:
    print("--------------------------------- Containers -----------------------------------------")
    cmd_ps(_, ctx)
    print()
    ensure_org_pat(ctx)
    print("--------------------------------- Runners --------------------------------------------")
    runners = gh_list_runners()
    print(f"{'NAME':40} {'STATUS':8} {'BUSY':6} LABELS")
    for r in runners:
        name = r.get("name", "")
        status = r.get("status", "")
        busy = "busy" if r.get("busy") else "idle"
        labels = ",".join(l.get("name", "") for l in r.get("labels", []))
        print(f"{name:40} {status:8} {busy:6} {labels}")
    print()
    info("由于 Github 限制，组织级 Runner 列表最多 100 条！")
    print()


def cmd_init(args: argparse.Namespace, ctx: Context) -> None:
    count = args.count if args.count is not None else env_int("RUNNER_COUNT", 2)
    if count < 1:
        die("数量必须 >= 1！")
    token = gh_fetch_reg_token(ctx)
    image = pick_runner_image(ctx, "init")
    render_compose(ctx, count, image, token)
    services = [f"{effective_prefix()}runner-{i}" for i in range(1, count + 1)]
    compose_up(ctx, services)
    for i in range(1, count + 1):
        runner_register(ctx, i, force=False)


def cmd_scale(args: argparse.Namespace, ctx: Context) -> None:
    try:
        count = int(args.count)
    except Exception:
        die("数量必须是数字！")
    if count < 1:
        die("数量必须 >= 1！")
    token = gh_fetch_reg_token(ctx)
    image = pick_runner_image(ctx, "scale")
    render_compose(ctx, count, image, token)
    services = [f"{effective_prefix()}runner-{i}" for i in range(1, count + 1)]
    compose_up(ctx, services)
    # stop extras
    exist_max = highest_existing_index(ctx)
    if exist_max > count:
        info(f"停止超出目标的容器: {count+1} .. {exist_max}")
        for i in range(count + 1, exist_max + 1):
            compose_stop(ctx, [f"{effective_prefix()}runner-{i}"])


def names_to_ids(ctx: Context, names: List[str]) -> List[int]:
    ids: List[int] = []
    for s in names:
        if not s.startswith(effective_prefix() + "runner-"):
            warn(f"非法服务名: {s}")
            continue
        tail = s.rsplit("-", 1)[-1]
        if tail.isdigit():
            ids.append(int(tail))
    return ids


def existing_ids(ctx: Context) -> List[int]:
    res: List[int] = []
    for s in list_existing_containers(ctx):
        tail = s.rsplit("-", 1)[-1]
        if tail.isdigit():
            res.append(int(tail))
    return res


def cmd_register(args: argparse.Namespace, ctx: Context) -> None:
    ids: List[int] = []
    if getattr(args, "names", None):
        ids = names_to_ids(ctx, args.names)
    else:
        ids = existing_ids(ctx)
    if not ids:
        info("没有可注册的 Runner 容器！")
        return
    max_id = max(ids)
    token = gh_fetch_reg_token(ctx)
    image = pick_runner_image(ctx, "register")
    render_compose(ctx, max_id, image, token)
    for i in ids:
        runner_register(ctx, i, force=False)


def cmd_start(args: argparse.Namespace, ctx: Context) -> None:
    # Determine services
    selected: List[str] = []
    max_id = 0
    if getattr(args, "names", None):
        for s in args.names:
            selected.append(s)
            tail = s.rsplit("-", 1)[-1]
            if tail.isdigit():
                max_id = max(max_id, int(tail))
    else:
        selected = list_existing_containers(ctx)
        for s in selected:
            tail = s.rsplit("-", 1)[-1]
            if tail.isdigit():
                max_id = max(max_id, int(tail))
    if not selected:
        info("没有可启动的 Runner 容器！")
        return
    max_id = max(1, max_id)
    token = gh_fetch_reg_token(ctx)
    image = pick_runner_image(ctx, "start")
    render_compose(ctx, max_id, image, token)
    # check and register if needed
    org_names = {r.get("name", "") for r in gh_list_runners()} if os.environ.get("ORG") and os.environ.get("GH_PAT") else set()
    need_reg: List[int] = []
    force_reg: List[int] = []
    for s in selected:
        tail = s.rsplit("-", 1)[-1]
        if not tail.isdigit():
            continue
        idx = int(tail)
        if not runner_is_configured(ctx, idx):
            need_reg.append(idx)
        else:
            if org_names and s not in org_names:
                force_reg.append(idx)
    for i in need_reg:
        runner_register(ctx, i, force=False)
    for i in force_reg:
        runner_register(ctx, i, force=True)
    compose_up(ctx, selected)


def cmd_stop(args: argparse.Namespace, ctx: Context) -> None:
    if getattr(args, "names", None):
        ids = names_to_ids(ctx, args.names)
        if not ids:
            info("没有可停止的 Runner 容器！")
            return
        exist_max = highest_existing_index(ctx)
        count = max(exist_max, max(ids)) if ids else exist_max
        count = max(1, count)
        token = gh_fetch_reg_token(ctx)
        image = pick_runner_image(ctx, "stop")
        render_compose(ctx, count, image, token)
        compose_stop(ctx, args.names)
    else:
        names = list_existing_containers(ctx)
        if not names:
            info("没有可停止的 Runner 容器！")
            return
        max_id = 1
        for s in names:
            tail = s.rsplit("-", 1)[-1]
            if tail.isdigit():
                max_id = max(max_id, int(tail))
        token = gh_fetch_reg_token(ctx)
        image = pick_runner_image(ctx, "stop")
        render_compose(ctx, max_id, image, token)
    compose_stop(ctx, names)


def cmd_restart(args: argparse.Namespace, ctx: Context) -> None:
    names = args.names if getattr(args, "names", None) else list_existing_containers(ctx)
    if not names:
        info("没有可重启的 Runner 容器！")
        return
    max_id = 1
    for s in names:
        tail = s.rsplit("-", 1)[-1]
        if tail.isdigit():
            max_id = max(max_id, int(tail))
    token = gh_fetch_reg_token(ctx)
    image = pick_runner_image(ctx, "restart")
    render_compose(ctx, max_id, image, token)
    compose_restart(ctx, names)


def cmd_logs(args: argparse.Namespace, ctx: Context) -> None:
    name = args.name
    if not re.match(rf"^{re.escape(effective_prefix())}runner-([0-9]+)$", name):
        die(f"非法服务名: {name}")
    tail = name.rsplit("-", 1)[-1]
    id_num = int(tail)
    exist_max = highest_existing_index(ctx)
    count = max(exist_max, id_num)
    count = max(1, count)
    token = gh_fetch_reg_token(ctx)
    image = pick_runner_image(ctx, "logs")
    render_compose(ctx, count, image, token)
    compose_logs(ctx, [name])


def delete_all_with_prefix(ctx: Context) -> None:
    pfx = effective_prefix() + "runner-"
    # deregister all runners in org with prefix
    try:
        for r in gh_list_runners():
            name = r.get("name", "")
            rid = r.get("id", None)
            if name.startswith(pfx) and rid is not None:
                info(f"从 Github 上注销: {name} (id={rid})")
                try:
                    gh_delete_runner_by_id(int(rid))
                except Exception:
                    warn(f"从 Github 上注销 {name} 失败，请手动从 Github 网站注销！")
    except Exception:
        warn("批量注销时发生错误。")
    # local down -v
    if ctx.compose_file.exists():
        info("使用 docker compose down -v 删除所有服务与卷")
        run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "down", "-v"], check=False)


def cmd_delete(args: argparse.Namespace, ctx: Context) -> None:
    ensure_org_pat(ctx)
    names = getattr(args, "names", [])
    yes = getattr(args, "yes", False)
    if not names:
        if not yes:
            ans = prompt_tty("确认删除以上所有 Runner/容器/卷吗? [y / N] ").strip().lower()
            if ans not in {"y", "yes"}:
                print("操作已取消！")
                return
        delete_all_with_prefix(ctx)
        info("批量删除完成！")
        return
    # targeted delete
    for s in names:
        tail = s.rsplit("-", 1)[-1]
        if not tail.isdigit():
            warn(f"未找到 {s} 对应的 Runner 容器，忽略该项！")
            continue
        info(f"从 Github 上注销: {s}")
        rid = gh_get_runner_id_by_name(s)
        if rid is not None:
            try:
                gh_delete_runner_by_id(rid)
            except Exception:
                warn(f"从 Github 上注销 {s} 失败，请手动在 Github 网页上注销！")
        else:
            warn(f"未在组织列表找到 {s}，可能已被移除！")
        info(f"删除容器与数据卷: {s} / {s}-data")
        if ctx.compose_file.exists():
            run(ctx.compose_cmd() + ["-f", str(ctx.compose_file), "rm", "-s", "-f", s], check=False)


def cmd_purge(args: argparse.Namespace, ctx: Context) -> None:
    ensure_org_pat(ctx)
    yes = getattr(args, "yes", False)
    if not yes:
        ans = prompt_tty("确定要注销所有 Runners、删除所有容器和卷，并移除所有生成的文件？[y / N] ").strip().lower()
        if ans not in {"y", "yes"}:
            print("操作已取消！")
            return
    delete_all_with_prefix(ctx)
    # Cleanup files
    for f in [
        ctx.compose_file,
        Path(os.environ.get("REG_TOKEN_CACHE_FILE", REG_TOKEN_CACHE_FILE_DEFAULT)),
        Path(os.environ.get("DOCKERFILE_HASH_FILE", DOCKERFILE_HASH_FILE_DEFAULT)),
        ctx.env_file,
    ]:
        if f.exists():
            info(f"删除 {f} 文件")
            try:
                f.unlink()
            except Exception:
                pass
    info("purge 完成！")


# Parser

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="runner.py", description="GitHub self-hosted runner manager (Python)")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("help")
    sub.add_parser("ps")
    sub.add_parser("list")

    p_init = sub.add_parser("init")
    p_init.add_argument("-n", "--count", type=int, default=None)

    p_scale = sub.add_parser("scale")
    p_scale.add_argument("count", type=int)

    p_register = sub.add_parser("register")
    p_register.add_argument("names", nargs="*")

    p_start = sub.add_parser("start")
    p_start.add_argument("names", nargs="*")

    p_stop = sub.add_parser("stop")
    p_stop.add_argument("names", nargs="*")

    p_restart = sub.add_parser("restart")
    p_restart.add_argument("names", nargs="*")

    p_logs = sub.add_parser("logs")
    p_logs.add_argument("name")

    for name in ("rm", "remove", "delete"):
        pr = sub.add_parser(name)
        pr.add_argument("names", nargs="*")
        pr.add_argument("-y", "--yes", action="store_true")

    p_purge = sub.add_parser("purge")
    p_purge.add_argument("-y", "--yes", action="store_true")

    return p


def main(argv: Optional[List[str]] = None) -> None:
    print(argv)
    print("----- runner.py (Python) -----")
    if argv is None:
        argv = sys.argv[1:]
    # When no arguments provided, show detailed help
    if not argv:
        argv = ["help"]
    parser = build_parser()
    args = parser.parse_args(argv)
    ctx = Context()

    cmd = args.cmd
    if cmd == "help":
        return cmd_help(args, ctx)
    if cmd == "ps":
        return cmd_ps(args, ctx)
    if cmd == "list":
        return cmd_list(args, ctx)
    if cmd == "init":
        return cmd_init(args, ctx)
    if cmd == "scale":
        return cmd_scale(args, ctx)
    if cmd == "register":
        return cmd_register(args, ctx)
    if cmd == "start":
        return cmd_start(args, ctx)
    if cmd == "stop":
        return cmd_stop(args, ctx)
    if cmd == "restart":
        return cmd_restart(args, ctx)
    if cmd == "logs":
        return cmd_logs(args, ctx)
    if cmd in {"rm", "remove", "delete"}:
        return cmd_delete(args, ctx)
    if cmd == "purge":
        return cmd_purge(args, ctx)


if __name__ == "__main__":
    main()
