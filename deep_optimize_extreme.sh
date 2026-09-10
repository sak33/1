#!/usr/bin/env bash
# deep_optimize_extreme.sh
# 深度极限系统层优化脚本 (CPU/NUMA/内存/存储层，补齐 universal_optimize_extreme.sh 的网络层)
# 目标: Debian 13 (trixie, kernel 6.12+) 64位, 兼容其他 systemd 发行版
# 设计原则: 模块化 / 幂等 / dry-run / 写前备份 / 分模块回滚 / 高风险项默认关闭
#
# 用法:
#   sudo bash deep_optimize_extreme.sh apply                 # 应用所有默认(低/中风险)模块
#   sudo bash deep_optimize_extreme.sh apply --dry-run        # 预演
#   sudo bash deep_optimize_extreme.sh apply --module=cpu_sched
#   sudo bash deep_optimize_extreme.sh status                 # 查看当前状态
#   sudo bash deep_optimize_extreme.sh rollback <module|all>  # 回滚
#   sudo bash deep_optimize_extreme.sh bench                  # 采集基线/对比
#
# 高风险模块 (默认不执行，需显式启用):
#   --enable-grub                 开启 isolcpus/nohz_full/rcu_nocbs (需指定 --isolate-cpus=2,3)
#   --enable-mitigations-off      关闭 CPU 漏洞缓解 (显著降低安全性，仅限完全信任的单租户环境)
# 两者都还需要追加 --i-understand-the-risk 才会真正写入，且都需要 reboot 才生效。

set -Eeuo pipefail
VERSION="1.0.0-deep-extreme"

# ------------------------------------------------------------------
# 全局状态
# ------------------------------------------------------------------
DRY_RUN=0
ACTION=""
ONLY_MODULE=""
ENABLE_GRUB=0
ENABLE_MITIGATIONS_OFF=0
CONFIRM_RISK=0
ISOLATE_CPUS=""
ROLLBACK_TARGET=""

STATE_DIR="/etc/deep-extreme"
STATE_FILE="${STATE_DIR}/module_status.json"
BACKUP_ROOT="${STATE_DIR}/backups"
LOG_FILE="/var/log/deep-extreme.log"
BENCH_LOG_DIR="/var/log/deep-extreme-bench"

TOTAL_MEM_KB=0
TOTAL_MEM_MB=0
CPU_COUNT=0
HAS_SYSTEMD=0
IS_OPENVZ=0
IS_LXC=0
IS_VM=0
NUMA_NODES=0

# ------------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --module=*) ONLY_MODULE="${arg#*=}" ;;
    --enable-grub) ENABLE_GRUB=1 ;;
    --enable-mitigations-off) ENABLE_MITIGATIONS_OFF=1 ;;
    --i-understand-the-risk) CONFIRM_RISK=1 ;;
    --isolate-cpus=*) ISOLATE_CPUS="${arg#*=}" ;;
    apply|status|rollback|bench|help) ACTION="$arg" ;;
    *)
      if [[ "$ACTION" == "rollback" && -z "$ROLLBACK_TARGET" ]]; then
        ROLLBACK_TARGET="$arg"
      fi
      ;;
  esac
done
ACTION="${ACTION:-help}"

# ------------------------------------------------------------------
# 基础输出/日志
# ------------------------------------------------------------------
ok(){ printf "\033[32m[✓] %s\033[0m\n" "$*"; }
warn(){ printf "\033[33m[!] %s\033[0m\n" "$*"; }
err(){ printf "\033[31m[✗] %s\033[0m\n" "$*"; }
info(){ printf "\033[36m[i] %s\033[0m\n" "$*"; }

log_line(){
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

_err_trap() {
  local rc=$? lineno=${1:-?}
  printf '\033[31m[FATAL]\033[0m 第一个不成功的命令在行 %s (退出码 %s)\n' "$lineno" "$rc" >&2
  printf '  详情可查看 %s\n' "$LOG_FILE" >&2
  exit "$rc"
}
trap '_err_trap $LINENO' ERR

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "需要 root 权限，请使用 sudo 或切换 root 后再试"
    exit 1
  fi
}

# ------------------------------------------------------------------
# 检测
# ------------------------------------------------------------------
detect_env() {
  TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
  CPU_COUNT=$(nproc 2>/dev/null || echo 1)

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    HAS_SYSTEMD=1
  fi

  if [[ -f /proc/user_beancounters && ! -d /proc/vz/version ]] || [[ -f /proc/vz/veinfo ]]; then
    IS_OPENVZ=1
  fi
  if grep -qaE '(lxc|container=lxc)' /proc/1/environ 2>/dev/null \
     || [[ -f /.dockerenv ]] \
     || grep -qE ':/(docker|lxc)/' /proc/1/cgroup 2>/dev/null; then
    IS_LXC=1
  fi
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local virt
    virt=$(systemd-detect-virt 2>/dev/null || echo none)
    [[ "$virt" != "none" && "$virt" != "" ]] && IS_VM=1
  fi

  if command -v numactl >/dev/null 2>&1; then
    NUMA_NODES=$(numactl --hardware 2>/dev/null | awk '/available:/{print $2}')
  fi
  NUMA_NODES="${NUMA_NODES:-1}"

  info "内存: ${TOTAL_MEM_MB} MB | CPU 核心: ${CPU_COUNT} | NUMA 节点: ${NUMA_NODES}"
  [[ $IS_OPENVZ -eq 1 ]] && warn "检测到 OpenVZ：本脚本大部分模块（CPU governor/GRUB/IO调度器）在此环境下不可用，将自动跳过"
  [[ $IS_LXC -eq 1 ]] && warn "检测到容器 (LXC/Docker)：仅执行容器内安全的模块，宿主机层面的调优需在宿主机上单独运行"
  [[ $IS_VM -eq 1 ]] && info "检测到虚拟化环境，将跳过物理机特有的部分（如某些电源管理项）"
}

detect_iface() {
  local dev
  dev="$(ip -o route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  if [[ -z "$dev" ]]; then
    dev="$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}' || true)"
  fi
  echo "$dev"
}

# ------------------------------------------------------------------
# 备份 / 状态记录
# ------------------------------------------------------------------
backup_file() {
  local src="$1"
  [[ -f "$src" ]] || return 0
  local ts backup_dir
  ts=$(date '+%Y%m%d-%H%M%S')
  backup_dir="${BACKUP_ROOT}/${ts}"
  mkdir -p "$backup_dir"
  cp -a "$src" "${backup_dir}/$(basename "$src")"
  echo "${backup_dir}/$(basename "$src")"
}

mark_module() {
  local module="$1" status="$2" note="${3:-}"
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || echo '{}' >"$STATE_FILE"
  local tmp
  tmp=$(mktemp)
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$STATE_FILE" "$module" "$status" "$note" "$tmp" <<'PYEOF'
import json,sys
path,module,status,note,tmp = sys.argv[1:6]
try:
    with open(path) as f: data = json.load(f)
except Exception:
    data = {}
data[module] = {"status": status, "note": note, "time": __import__("datetime").datetime.now().isoformat()}
with open(tmp, "w") as f: json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
    mv "$tmp" "$STATE_FILE"
  else
    # 无 python3 时退化为简单追加日志，不做结构化 JSON
    echo "${module}=${status} ${note}" >>"${STATE_DIR}/module_status.txt"
    rm -f "$tmp"
  fi
}

module_enabled() {
  [[ -z "$ONLY_MODULE" || "$ONLY_MODULE" == "$1" ]]
}

# ==================================================================
# 模块 1: CPU 调度 (governor)
# ==================================================================
apply_cpu_sched() {
  module_enabled "cpu_sched" || return 0
  [[ $IS_OPENVZ -eq 1 ]] && { warn "[cpu_sched] OpenVZ 环境跳过"; return 0; }
  info "[cpu_sched] 正在配置 CPU 频率调节器为 performance..."

  if ! command -v cpupower >/dev/null 2>&1; then
    warn "[cpu_sched] 未找到 cpupower，尝试安装 (Debian 13: linux-cpupower)"
    if [[ $DRY_RUN -eq 0 ]]; then
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y linux-cpupower >/dev/null 2>&1 || \
        apt-get install -y linux-tools-common linux-tools-$(uname -r) >/dev/null 2>&1 || true
    fi
  fi

  if [[ ! -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
    warn "[cpu_sched] 未发现 cpufreq 接口 (常见于部分云主机/虚拟机)，跳过"
    mark_module "cpu_sched" "skipped" "no cpufreq interface"
    return 0
  fi

  local avail
  avail=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null || echo "")
  if [[ "$avail" != *performance* ]]; then
    warn "[cpu_sched] performance governor 不可用 (可用: $avail)，跳过"
    mark_module "cpu_sched" "skipped" "performance governor unavailable"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run][cpu_sched] 将把所有 CPU 的 scaling_governor 设为 performance，并写入 systemd unit 持久化"
    return 0
  fi

  local UNIT="/etc/systemd/system/deep-extreme-cpugovernor.service"
  cat >"$UNIT" <<'UNIT'
[Unit]
Description=Deep Extreme: Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    systemctl daemon-reload || true
    systemctl enable --now deep-extreme-cpugovernor.service >/dev/null 2>&1 || true
  fi
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance >"$f" 2>/dev/null || true
  done
  ok "[cpu_sched] CPU governor 已设为 performance 并持久化"
  mark_module "cpu_sched" "applied" "performance governor + systemd unit"
}

rollback_cpu_sched() {
  systemctl disable --now deep-extreme-cpugovernor.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/deep-extreme-cpugovernor.service
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo ondemand >"$f" 2>/dev/null || echo schedutil >"$f" 2>/dev/null || true
  done
  systemctl daemon-reload || true
  ok "[cpu_sched] 已回滚为 ondemand/schedutil"
  mark_module "cpu_sched" "rolled_back"
}

# ==================================================================
# 模块 2: RPS / RFS / XPS (软中断分发，补齐虚拟网卡无 MSI IRQ 场景)
# ==================================================================
apply_rps_rfs_xps() {
  module_enabled "rps_rfs_xps" || return 0
  local iface
  iface="$(detect_iface)"
  [[ -z "$iface" ]] && { warn "[rps_rfs_xps] 未能探测到网卡，跳过"; return 0; }
  info "[rps_rfs_xps] 正在为 $iface 配置软中断分发 (CPU: $CPU_COUNT)..."

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run][rps_rfs_xps] 将为 $iface 的每个 rx 队列设置 rps_cpus 全核掩码，并设置 net.core.rps_sock_flow_entries"
    return 0
  fi

  # 计算全核掩码 (十六进制)
  local mask=$(( (1 << CPU_COUNT) - 1 ))
  local mask_hex
  mask_hex=$(printf '%x' "$mask")

  local q count=0
  for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [[ -f "$q" ]] || continue
    echo "$mask_hex" >"$q" 2>/dev/null && ((count++)) || true
  done
  for q in /sys/class/net/"$iface"/queues/tx-*/xps_cpus; do
    [[ -f "$q" ]] || continue
    echo "$mask_hex" >"$q" 2>/dev/null || true
  done

  # RFS 全局与每队列流表
  if [[ -f /proc/sys/net/core/rps_sock_flow_entries ]]; then
    echo 32768 >/proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
  fi
  local per_queue=$((32768 / (count > 0 ? count : 1)))
  for q in /sys/class/net/"$iface"/queues/rx-*/rps_flow_cnt; do
    [[ -f "$q" ]] || continue
    echo "$per_queue" >"$q" 2>/dev/null || true
  done

  # 持久化: udev rule + systemd unit 双保险 (网卡重启/重建后重新应用)
  local UNIT="/etc/systemd/system/deep-extreme-rps@.service"
  cat >"$UNIT" <<'UNIT'
[Unit]
Description=Deep Extreme: RPS/RFS/XPS for %i
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device

[Service]
Type=oneshot
ExecStart=-/bin/bash -lc '
IF="%i"
CPU_COUNT=$(nproc)
MASK=$(( (1 << CPU_COUNT) - 1 ))
MASK_HEX=$(printf "%x" "$MASK")
for q in /sys/class/net/$IF/queues/rx-*/rps_cpus; do [[ -f "$q" ]] && echo "$MASK_HEX" > "$q" 2>/dev/null; done
for q in /sys/class/net/$IF/queues/tx-*/xps_cpus; do [[ -f "$q" ]] && echo "$MASK_HEX" > "$q" 2>/dev/null; done
echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    systemctl daemon-reload || true
    systemctl enable --now "deep-extreme-rps@${iface}.service" >/dev/null 2>&1 || true
  fi
  ok "[rps_rfs_xps] 已为 $iface 配置 RPS/RFS/XPS (${count} 个队列)"
  mark_module "rps_rfs_xps" "applied" "iface=$iface"
}

rollback_rps_rfs_xps() {
  local iface
  iface="$(detect_iface)"
  systemctl disable --now "deep-extreme-rps@${iface}.service" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/deep-extreme-rps@.service
  systemctl daemon-reload || true
  for q in /sys/class/net/"$iface"/queues/rx-*/rps_cpus; do
    [[ -f "$q" ]] && echo 0 >"$q" 2>/dev/null || true
  done
  ok "[rps_rfs_xps] 已回滚"
  mark_module "rps_rfs_xps" "rolled_back"
}

# ==================================================================
# 模块 3: 透明大页 THP
# ==================================================================
apply_thp() {
  module_enabled "thp" || return 0
  [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]] || { warn "[thp] 系统无 THP 接口，跳过"; return 0; }
  info "[thp] 正在将 THP 设为 madvise (仅显式请求大页的应用受益，避免通用负载延迟毛刺)..."

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run][thp] 将写 madvise 到 transparent_hugepage/enabled 与 defrag，并持久化为开机 unit"
    return 0
  fi

  echo madvise >/sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  echo madvise >/sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

  local UNIT="/etc/systemd/system/deep-extreme-thp.service"
  cat >"$UNIT" <<'UNIT'
[Unit]
Description=Deep Extreme: THP madvise
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled; echo madvise > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    systemctl daemon-reload || true
    systemctl enable --now deep-extreme-thp.service >/dev/null 2>&1 || true
  fi
  ok "[thp] THP 已设为 madvise"
  mark_module "thp" "applied" "madvise"
}

rollback_thp() {
  echo always >/sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  echo always >/sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
  systemctl disable --now deep-extreme-thp.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/deep-extreme-thp.service
  systemctl daemon-reload || true
  ok "[thp] 已恢复为 always"
  mark_module "thp" "rolled_back"
}

# ==================================================================
# 模块 4: 存储 IO 调度器与预读 (按设备类型 udev 规则)
# ==================================================================
apply_storage_io() {
  module_enabled "storage_io" || return 0
  info "[storage_io] 正在按设备类型配置 IO 调度器与预读..."

  local RULE="/etc/udev/rules.d/60-deep-extreme-io.rules"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run][storage_io] 将写入 $RULE: NVMe->none, 非旋转盘(SSD)->mq-deadline, 机械盘->bfq"
    return 0
  fi

  cat >"$RULE" <<'RULES'
# Deep Extreme: IO scheduler + read-ahead by device type
# NVMe: none 调度器 (硬件队列已足够，软件调度反而增加开销)
ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
# 非旋转盘 (SATA/SAS SSD): mq-deadline，兼顾延迟与吞吐
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/read_ahead_kb}="128"
# 机械盘 (HDD): bfq，改善多任务下的公平性
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/read_ahead_kb}="1024"
RULES

  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger --subsystem-match=block 2>/dev/null || true
  ok "[storage_io] udev 规则已写入并触发 (新增/热插拔设备自动生效；已挂载设备可能需要 udevadm trigger 或重启确认)"
  mark_module "storage_io" "applied" "udev rule $RULE"
}

rollback_storage_io() {
  rm -f /etc/udev/rules.d/60-deep-extreme-io.rules
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger --subsystem-match=block 2>/dev/null || true
  ok "[storage_io] 已移除 udev 规则 (调度器恢复为内核默认需重新触发或重启)"
  mark_module "storage_io" "rolled_back"
}

# ==================================================================
# 模块 5: 网卡多队列与中断合并 (在现有 offload 基础上补充)
# ==================================================================
apply_nic_queue() {
  module_enabled "nic_queue" || return 0
  local iface
  iface="$(detect_iface)"
  [[ -z "$iface" ]] && { warn "[nic_queue] 未探测到网卡，跳过"; return 0; }
  command -v ethtool >/dev/null 2>&1 || { warn "[nic_queue] 未安装 ethtool，跳过"; return 0; }

  info "[nic_queue] 正在为 $iface 调整队列数与中断合并..."
  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run][nic_queue] 将尝试 ethtool -L $iface combined $CPU_COUNT 与 ethtool -C $iface rx-usecs 建议值"
    return 0
  fi

  local max_combined
  max_combined=$(ethtool -l "$iface" 2>/dev/null | awk '/Combined:/{print $2; exit}')
  if [[ -n "$max_combined" && "$max_combined" != "n/a" ]]; then
    local target=$CPU_COUNT
    (( target > max_combined )) && target=$max_combined
    ethtool -L "$iface" combined "$target" 2>/dev/null && \
      info "[nic_queue] 已将 $iface combined 队列设为 $target" || \
      warn "[nic_queue] $iface 不支持调整队列数 (常见于部分虚拟网卡)"
  else
    warn "[nic_queue] $iface 未报告 combined 队列信息，跳过队列数调整 (virtio/veth 常见)"
  fi

  # 中断合并: 轻度调整，避免过度合并增加延迟
  ethtool -C "$iface" adaptive-rx on adaptive-tx on 2>/dev/null || \
    warn "[nic_queue] $iface 不支持中断合并调整"

  # 融合进现有 extreme-offload@ unit 之外，单独建一个 unit 避免与上游脚本文件冲突
  local UNIT="/etc/systemd/system/deep-extreme-nicqueue@.service"
  cat >"$UNIT" <<'UNIT'
[Unit]
Description=Deep Extreme: NIC queue/coalesce tuning for %i
BindsTo=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device

[Service]
Type=oneshot
ExecStart=-/bin/bash -lc '
IF="%i"
CPUN=$(nproc)
MAXC=$(ethtool -l "$IF" 2>/dev/null | awk "/Combined:/{print \$2; exit}")
if [[ -n "$MAXC" && "$MAXC" != "n/a" ]]; then
  T=$CPUN; (( T > MAXC )) && T=$MAXC
  ethtool -L "$IF" combined "$T" 2>/dev/null || true
fi
ethtool -C "$IF" adaptive-rx on adaptive-tx on 2>/dev/null || true
'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  if [[ $HAS_SYSTEMD -eq 1 ]]; then
    systemctl daemon-reload || true
    systemctl enable "deep-extreme-nicqueue@${iface}.service" >/dev/null 2>&1 || true
  fi
  ok "[nic_queue] 已完成 $iface 队列/中断合并调优"
  mark_module "nic_queue" "applied" "iface=$iface"
}

rollback_nic_queue() {
  local iface
  iface="$(detect_iface)"
  systemctl disable --now "deep-extreme-nicqueue@${iface}.service" >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/deep-extreme-nicqueue@.service
  systemctl daemon-reload || true
  ok "[nic_queue] 已回滚 (队列数/中断合并恢复需驱动 reload 或 reboot 保险)"
  mark_module "nic_queue" "rolled_back"
}

# ==================================================================
# 模块 6 (高风险/默认关闭): GRUB isolcpus/nohz_full/rcu_nocbs
# ==================================================================
apply_grub_isolation() {
  module_enabled "grub" || return 0
  if [[ $ENABLE_GRUB -eq 0 ]]; then
    info "[grub] 未指定 --enable-grub，跳过 (默认关闭)"
    return 0
  fi
  if [[ $CONFIRM_RISK -eq 0 ]]; then
    err "[grub] 该模块需要 reboot 且配置错误可能导致系统调度异常，请追加 --i-understand-the-risk 再执行"
    return 1
  fi
  if [[ -z "$ISOLATE_CPUS" ]]; then
    err "[grub] 请通过 --isolate-cpus=2,3 指定要隔离的 CPU 核心 (不能包含 CPU0，且不能等于全部核心)"
    return 1
  fi

  info "[grub] 准备为 CPU $ISOLATE_CPUS 配置 isolcpus/nohz_full/rcu_nocbs..."
  local GRUB_FILE="/etc/default/grub"
  [[ -f "$GRUB_FILE" ]] || { err "[grub] 未找到 $GRUB_FILE，Debian 13 应存在此文件，请检查系统"; return 1; }

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run][grub] 将在 GRUB_CMDLINE_LINUX_DEFAULT 追加: isolcpus=${ISOLATE_CPUS} nohz_full=${ISOLATE_CPUS} rcu_nocbs=${ISOLATE_CPUS}"
    info "[dry-run][grub] 备份 $GRUB_FILE 后执行 update-grub，不会自动 reboot"
    return 0
  fi

  local bak
  bak=$(backup_file "$GRUB_FILE")
  info "[grub] 已备份原文件到 $bak"

  local extra="isolcpus=${ISOLATE_CPUS} nohz_full=${ISOLATE_CPUS} rcu_nocbs=${ISOLATE_CPUS}"
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
    sed -i.deep-extreme-orig -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\")([^\"]*)(\")|\1\2 ${extra}\3|" "$GRUB_FILE"
  else
    echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${extra}\"" >>"$GRUB_FILE"
  fi

  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
  else
    err "[grub] 未找到 update-grub/grub-mkconfig，请手动重新生成 GRUB 配置"
    return 1
  fi

  warn "[grub] 配置已写入，需要 reboot 才能生效。建议先确认带外管理(IPMI/云控制台救援模式)可用后再重启"
  ok "[grub] GRUB CPU 隔离配置完成 (待 reboot)"
  mark_module "grub" "applied_pending_reboot" "isolate=${ISOLATE_CPUS} backup=${bak}"
}

rollback_grub_isolation() {
  local GRUB_FILE="/etc/default/grub"
  if [[ -f "${GRUB_FILE}.deep-extreme-orig" ]]; then
    cp -a "${GRUB_FILE}.deep-extreme-orig" "$GRUB_FILE"
    info "[grub] 已从 sed 生成的 .deep-extreme-orig 恢复"
  else
    warn "[grub] 未找到自动备份的 .deep-extreme-orig，请从 ${BACKUP_ROOT} 下手动找回对应时间戳的备份并恢复"
  fi
  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  fi
  warn "[grub] 已恢复配置文件，需要 reboot 生效"
  mark_module "grub" "rolled_back_pending_reboot"
}

# ==================================================================
# 模块 7 (高风险/默认关闭): mitigations=off
# ==================================================================
apply_mitigations_off() {
  module_enabled "mitigations" || return 0
  if [[ $ENABLE_MITIGATIONS_OFF -eq 0 ]]; then
    info "[mitigations] 未指定 --enable-mitigations-off，跳过 (默认关闭，强烈建议保持关闭)"
    return 0
  fi
  if [[ $CONFIRM_RISK -eq 0 ]]; then
    err "[mitigations] 该操作会关闭 Spectre/Meltdown 等 CPU 侧信道漏洞缓解，显著降低安全性。"
    err "           仅建议在完全信任、单租户、无外部可控代码执行的环境使用。"
    err "           请追加 --i-understand-the-risk 再执行"
    return 1
  fi

  local GRUB_FILE="/etc/default/grub"
  [[ -f "$GRUB_FILE" ]] || { err "[mitigations] 未找到 $GRUB_FILE"; return 1; }

  if [[ $DRY_RUN -eq 1 ]]; then
    info "[dry-run][mitigations] 将在 GRUB_CMDLINE_LINUX_DEFAULT 追加 mitigations=off，需 reboot"
    return 0
  fi

  local bak
  bak=$(backup_file "$GRUB_FILE")
  if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
    sed -i.deep-extreme-mit-orig -E 's|^(GRUB_CMDLINE_LINUX_DEFAULT=")([^"]*)(")|\1\2 mitigations=off\3|' "$GRUB_FILE"
  else
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="mitigations=off"' >>"$GRUB_FILE"
  fi
  command -v update-grub >/dev/null 2>&1 && update-grub || true

  warn "[mitigations] mitigations=off 已写入，需 reboot 生效。此设置已记录在 $STATE_FILE，请定期复核是否仍然需要"
  mark_module "mitigations" "applied_pending_reboot" "backup=${bak}"
}

rollback_mitigations_off() {
  local GRUB_FILE="/etc/default/grub"
  if [[ -f "${GRUB_FILE}.deep-extreme-mit-orig" ]]; then
    cp -a "${GRUB_FILE}.deep-extreme-mit-orig" "$GRUB_FILE"
  else
    warn "[mitigations] 未找到自动备份，请从 ${BACKUP_ROOT} 手动恢复"
  fi
  command -v update-grub >/dev/null 2>&1 && update-grub || true
  warn "[mitigations] 已恢复，需要 reboot 生效"
  mark_module "mitigations" "rolled_back_pending_reboot"
}

# ==================================================================
# 基准测试
# ==================================================================
run_bench() {
  mkdir -p "$BENCH_LOG_DIR"
  local ts out
  ts=$(date '+%Y%m%d-%H%M%S')
  out="${BENCH_LOG_DIR}/bench-${ts}.log"
  {
    echo "=== Deep Extreme Bench $(date '+%F %T') ==="
    echo "--- uname ---"; uname -a
    echo "--- vmstat ---"; vmstat 1 5 2>/dev/null || echo "vmstat 不可用"
    echo "--- mpstat ---"; mpstat -P ALL 1 3 2>/dev/null || echo "mpstat 不可用 (安装 sysstat 以启用)"
    echo "--- sysctl 关键网络参数 ---"
    sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc \
      net.core.rmem_max net.core.wmem_max vm.swappiness 2>/dev/null || true
    echo "--- CPU governor ---"
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "无 cpufreq 接口"
    echo "--- THP ---"
    cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "无 THP 接口"
    if command -v iperf3 >/dev/null 2>&1; then
      echo "--- 提示: 已安装 iperf3，可手动运行 iperf3 -c <目标> 做端到端吞吐对比 ---"
    fi
    if command -v fio >/dev/null 2>&1; then
      echo "--- 提示: 已安装 fio，可手动运行针对性磁盘基准 ---"
    fi
  } >"$out" 2>&1
  ok "基线/状态快照已保存到 $out"
}

# ==================================================================
# 状态展示
# ==================================================================
show_status() {
  echo ""
  echo "==================== Deep Extreme 状态 (v${VERSION}) ===================="
  detect_env
  echo ""
  if [[ -f "$STATE_FILE" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$STATE_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for k, v in data.items():
        print(f"  {k:20s} {v.get('status','?'):25s} {v.get('note','')}")
except Exception as e:
    print("  (无法解析状态文件:", e, ")")
PYEOF
  elif [[ -f "${STATE_DIR}/module_status.txt" ]]; then
    cat "${STATE_DIR}/module_status.txt"
  else
    echo "  (尚未应用任何模块)"
  fi
  echo "========================================================================"
  echo ""
  info "配套的网络层优化请单独运行 buyi06/optimize_extreme 的 universal_optimize_extreme.sh status 查看"
}

# ==================================================================
# 主分发
# ==================================================================
usage() {
  cat <<EOF
Deep Extreme 系统层优化脚本 v${VERSION}

用法:
  sudo bash $0 apply [--dry-run] [--module=<name>]
  sudo bash $0 status
  sudo bash $0 rollback <module|all>
  sudo bash $0 bench

模块名: cpu_sched | rps_rfs_xps | thp | storage_io | nic_queue | grub | mitigations

高风险模块 (默认不在 apply 全量范围内, 需要显式启用且需要 reboot 生效):
  --enable-grub --isolate-cpus=2,3 --i-understand-the-risk
  --enable-mitigations-off --i-understand-the-risk

配套使用:
  本脚本只覆盖 CPU/内存/存储/NUMA 层，网络栈优化 (BBR/TFO/缓冲区/conntrack)
  请先运行仓库 buyi06/optimize_extreme 的 universal_optimize_extreme.sh apply
EOF
}

do_apply() {
  require_root
  detect_env
  mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
  log_line "apply start dry_run=$DRY_RUN module=${ONLY_MODULE:-all}"

  apply_cpu_sched
  apply_rps_rfs_xps
  apply_thp
  apply_storage_io
  apply_nic_queue
  apply_grub_isolation
  apply_mitigations_off

  echo ""
  ok "默认(低/中风险)模块处理完成"
  if [[ $ENABLE_GRUB -eq 0 && $ENABLE_MITIGATIONS_OFF -eq 0 ]]; then
    info "高风险模块 (grub 隔核 / mitigations=off) 本次未启用，如需请查看 --help"
  fi
  log_line "apply done"
}

do_rollback() {
  require_root
  detect_env
  local target="${ROLLBACK_TARGET:-}"
  if [[ -z "$target" ]]; then
    err "请指定要回滚的模块，例如: rollback cpu_sched 或 rollback all"
    exit 1
  fi
  case "$target" in
    cpu_sched) rollback_cpu_sched ;;
    rps_rfs_xps) rollback_rps_rfs_xps ;;
    thp) rollback_thp ;;
    storage_io) rollback_storage_io ;;
    nic_queue) rollback_nic_queue ;;
    grub) rollback_grub_isolation ;;
    mitigations) rollback_mitigations_off ;;
    all)
      rollback_cpu_sched; rollback_rps_rfs_xps; rollback_thp
      rollback_storage_io; rollback_nic_queue
      rollback_grub_isolation; rollback_mitigations_off
      ;;
    *) err "未知模块: $target"; exit 1 ;;
  esac
  log_line "rollback $target done"
}

case "$ACTION" in
  apply) do_apply ;;
  status) show_status ;;
  rollback) do_rollback ;;
  bench) run_bench ;;
  help|*) usage ;;
esac
