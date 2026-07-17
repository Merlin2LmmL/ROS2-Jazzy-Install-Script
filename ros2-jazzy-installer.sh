#!/usr/bin/env bash
# ==============================================================================
#  ROS 2 Jazzy Installer — Ubuntu 24.04 (Noble)
#  Supports: binary install (default, fast) or source build (--source)
# ==============================================================================
set -euo pipefail

# ── Constants ──────────────────────────────────────────────────────────────────
readonly ROS_DISTRO="jazzy"
readonly SUPPORTED_CODENAME="noble"
readonly WORKSPACE="${HOME}/ros2_${ROS_DISTRO}_ws"
readonly LOGFILE="/tmp/ros2_${ROS_DISTRO}_install_$(date +%Y%m%d_%H%M%S).log"

# ── Defaults ───────────────────────────────────────────────────────────────────
INSTALL_MODE="binary"   # binary | source
FAST_MODE=0
PARALLEL_WORKERS=""
SKIP_LOCALE=0
ROS_PACKAGE=""
SYSTEM_VARIANT="auto"

# ── Colors ─────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
  MAGENTA='\033[0;35m'; DIM='\033[2m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
  MAGENTA=''; DIM=''
fi

# ── Logging ────────────────────────────────────────────────────────────────────
info()  { echo -e "${GREEN}[INFO]${RESET}  $*" | tee -a "$LOGFILE"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "$LOGFILE"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "$LOGFILE" >&2; }
step()  { echo -e "\n${CYAN}${BOLD}▶ $*${RESET}" | tee -a "$LOGFILE"; }
die()   { error "$*"; exit 1; }

# ── Progress spinner ───────────────────────────────────────────────────────────
# run_with_progress "Label" cmd [args...]
#   Runs cmd in the background, shows a braille spinner + the last relevant
#   log line updated in-place.  On success prints ✓; on failure prints ✗ + hint.
#
# FIX: Each redraw prefixes \033[2K to erase the entire terminal line before
# writing, so shorter detail strings never leave stale characters behind.
#
# _SPINNER_LOG_START is set just before calling so the tail only picks up lines
# produced by *this* command (avoids surfacing old log noise).
_SPINNER_LOG_START=0

run_with_progress() {
  local label="$1"; shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local f=0 elapsed=0

  # Snapshot log length so we only tail new lines from this command
  _SPINNER_LOG_START=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)

  # Run command; all output goes to logfile
  ( "$@" >> "$LOGFILE" 2>&1 ) &
  local pid=$!

  tput civis 2>/dev/null || true   # hide cursor

  while kill -0 "$pid" 2>/dev/null; do
    # Pull last non-blank new log line; strip ANSI codes; truncate to 55 chars
    local detail
    detail=$(tail -n +"$(( _SPINNER_LOG_START + 1 ))" "$LOGFILE" 2>/dev/null \
      | grep -v '^[[:space:]]*$' \
      | tail -1 \
      | sed 's/\x1b\[[0-9;]*[mGKHF]//g' \
      | sed 's/^[[:space:]]*//' \
      | cut -c1-55) || detail=""

    # Elapsed timer mm:ss
    local mm ss timer
    mm=$(( elapsed / 60 )); ss=$(( elapsed % 60 ))
    printf -v timer "%02d:%02d" "$mm" "$ss"

    # \033[2K erases the entire current line so no stale characters can linger
    printf "\r\033[2K  ${MAGENTA}%s${RESET}  ${BOLD}%-26s${RESET}  ${CYAN}│${RESET}  ${YELLOW}%s${RESET}  ${CYAN}│${RESET}  ${DIM}%-55s${RESET}" \
      "${frames[$f]}" "$label" "$timer" "$detail"

    f=$(( (f + 1) % ${#frames[@]} ))
    sleep 1
    (( elapsed++ )) || true
  done

  wait "$pid"; local rc=$?
  tput cnorm 2>/dev/null || true   # restore cursor

  # Clear the spinner line cleanly
  printf "\r\033[2K"

  if [[ $rc -eq 0 ]]; then
    printf "  ${GREEN}✓${RESET}  ${BOLD}%-26s${RESET}  done\n" "$label"
    echo "[DONE] $label" >> "$LOGFILE"
  else
    printf "  ${RED}✗${RESET}  ${BOLD}%-26s${RESET}  FAILED  →  see ${LOGFILE}\n" "$label"
    echo "[FAIL] $label" >> "$LOGFILE"
    return $rc
  fi
}

# colcon_with_progress: like run_with_progress but also shows a
# "pkg N/total" counter by watching "Starting >>>" lines in the log.
colcon_with_progress() {
  local label="$1"; shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local f=0 elapsed=0

  _SPINNER_LOG_START=$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)

  ( "$@" >> "$LOGFILE" 2>&1 ) &
  local pid=$!

  tput civis 2>/dev/null || true

  while kill -0 "$pid" 2>/dev/null; do
    local new_lines
    new_lines=$(tail -n +"$(( _SPINNER_LOG_START + 1 ))" "$LOGFILE" 2>/dev/null) || new_lines=""

    # Count how many packages have started
    local started total_est current_pkg mm ss timer detail
    started=$(echo "$new_lines" | grep -c 'Starting >>>' 2>/dev/null || echo 0)
    # Rough total from first colcon summary line (e.g. "X packages selected")
    total_est=$(echo "$new_lines" | grep -o '[0-9]\+ packages selected' \
      | head -1 | grep -o '[0-9]\+' || echo "?")

    # Last "Starting >>>" package name
    current_pkg=$(echo "$new_lines" \
      | grep 'Starting >>>' \
      | tail -1 \
      | sed 's/.*Starting >>> //' \
      | cut -c1-30 || true)
    current_pkg="${current_pkg:-}"

    mm=$(( elapsed / 60 )); ss=$(( elapsed % 60 ))
    printf -v timer "%02d:%02d" "$mm" "$ss"

    if [[ -n "$current_pkg" ]]; then
      detail="[${started}/${total_est}] ${current_pkg}"
    else
      detail=$(echo "$new_lines" \
        | grep -v '^[[:space:]]*$' \
        | tail -1 \
        | sed 's/\x1b\[[0-9;]*[mGKHF]//g' \
        | sed 's/^[[:space:]]*//' \
        | cut -c1-55 || true)
      detail="${detail:-}"
    fi

    # \033[2K erases the entire current line so no stale characters can linger
    printf "\r\033[2K  ${MAGENTA}%s${RESET}  ${BOLD}%-26s${RESET}  ${CYAN}│${RESET}  ${YELLOW}%s${RESET}  ${CYAN}│${RESET}  ${DIM}%-55s${RESET}" \
      "${frames[$f]}" "$label" "$timer" "$detail"

    f=$(( (f + 1) % ${#frames[@]} ))
    sleep 1
    (( elapsed++ )) || true
  done

  wait "$pid"; local rc=$?
  tput cnorm 2>/dev/null || true
  printf "\r\033[2K"

  if [[ $rc -eq 0 ]]; then
    printf "  ${GREEN}✓${RESET}  ${BOLD}%-26s${RESET}  done\n" "$label"
    echo "[DONE] $label" >> "$LOGFILE"
  else
    printf "  ${RED}✗${RESET}  ${BOLD}%-26s${RESET}  FAILED  →  see ${LOGFILE}\n" "$label"
    echo "[FAIL] $label" >> "$LOGFILE"
    return $rc
  fi
}

detect_system_variant() {

  # User explicitly forced one
  if [[ "$SYSTEM_VARIANT" != "auto" ]]; then
    echo "$SYSTEM_VARIANT"
    return
  fi

  # Running a desktop session
  if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
    echo "desktop"
    return
  fi

  # Desktop metapackages installed
  for pkg in \
      ubuntu-desktop \
      ubuntu-desktop-minimal \
      ubuntu-gnome-desktop \
      kubuntu-desktop \
      xubuntu-desktop \
      lubuntu-desktop \
      ubuntu-mate-desktop \
      ubuntu-budgie-desktop; do

      if dpkg -s "$pkg" >/dev/null 2>&1; then
          echo "desktop"
          return
      fi
  done

  echo "server"
}


# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --binary             Binary APT install (default, ~5 min)
  --source             Full source build (~2–4 hours)
  --package PKG        ROS package to install (default: ros-jazzy-desktop)
                       e.g. --package ros-jazzy-ros-base
  --fast               Source build: Release mode + max parallelism
  --parallel N         Source build: number of parallel workers (default: nproc)
  --skip-locale        Skip locale configuration
  --workspace DIR      Source build workspace (default: ~/ros2_jazzy_ws)
  --help               Show this help

Examples:
  $0                           # Binary desktop install
  $0 --package ros-jazzy-ros-base   # Binary base install (smaller)
  $0 --source --fast           # Source build, optimised
EOF
  exit 0
}

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --binary)        INSTALL_MODE="binary";  shift ;;
    --source)        INSTALL_MODE="source";  shift ;;
    --package)       ROS_PACKAGE="$2";       shift 2 ;;
    --fast)          FAST_MODE=1;            shift ;;
    --parallel)      PARALLEL_WORKERS="$2";  shift 2 ;;
    --skip-locale)   SKIP_LOCALE=1;          shift ;;
    --workspace)     WORKSPACE="$2";         shift 2 ;;
    --desktop)       SYSTEM_VARIANT="desktop"; shift ;;
    --server)        SYSTEM_VARIANT="server"; shift ;;
    --help|-h)       usage ;;
    *) die "Unknown option: $1  (run with --help for usage)" ;;
  esac
done

# ── Auto-detect Desktop vs Server ──────────────────────────────────────────────
SYSTEM_VARIANT="$(detect_system_variant)"

# If the user didn't specify a package, choose one automatically.
if [[ -z "$ROS_PACKAGE" ]]; then
  if [[ "$SYSTEM_VARIANT" == "desktop" ]]; then
    ROS_PACKAGE="ros-${ROS_DISTRO}-desktop"
  else
    ROS_PACKAGE="ros-${ROS_DISTRO}-ros-base"
  fi
fi

# ── Privilege helper ───────────────────────────────────────────────────────────
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  SUDO=""
else
  if ! command -v sudo &>/dev/null; then
    die "'sudo' not found and not running as root. Install sudo or re-run as root."
  fi
  SUDO="sudo"
fi

# ── Startup banner ─────────────────────────────────────────────────────────────
echo -e "${BOLD}"
cat <<'BANNER'
    ____  ____  _____    ___          __
   / __ \/ __ \/ ___/   |__ \        / /___ _________  __  __
  / /_/ / / / /\__ \    __/ /   __  / / __ `/_  /_  / / / / /
 / _, _/ /_/ /___/ /   / __/   / /_/ / /_/ / / /_/ /_/ /_/ /
/_/ |_|\____//____/   /____/   \____/\__,_/ /___/___/\__, /
                                                     /____/
BANNER
echo -e "${RESET}"
echo -e "${BOLD}ROS 2 ${ROS_DISTRO} Installer${RESET}"
echo -e "Mode      : ${CYAN}${INSTALL_MODE}${RESET}"
echo -e "System    : ${CYAN}${SYSTEM_VARIANT}${RESET}"
[[ "$INSTALL_MODE" == "binary" ]] && echo -e "Package   : ${CYAN}${ROS_PACKAGE}${RESET}"
[[ "$INSTALL_MODE" == "source" ]] && echo -e "Workspace : ${CYAN}${WORKSPACE}${RESET}"
echo -e "Log file  : ${CYAN}${LOGFILE}${RESET}"
echo ""

# ── Prerequisite: must be bash ─────────────────────────────────────────────────
if [[ -z "${BASH_VERSION:-}" ]]; then
  die "This script must be run with bash, not sh.  Use: bash $0"
fi

# ── OS check ───────────────────────────────────────────────────────────────────
step "Checking OS compatibility"

if [[ ! -f /etc/os-release ]]; then
  die "/etc/os-release not found — is this Linux?"
fi

source /etc/os-release

if [[ "${ID:-}" != "ubuntu" ]]; then
  die "Unsupported OS: ${PRETTY_NAME:-unknown}. This script requires Ubuntu."
fi

CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

if [[ "$CODENAME" != "$SUPPORTED_CODENAME" ]]; then
  die "ROS 2 Jazzy requires Ubuntu 24.04 (Noble). Detected: ${PRETTY_NAME} (${CODENAME})"
fi

info "OS: ${PRETTY_NAME} (${CODENAME}) ✓"

# ── Idempotency check ──────────────────────────────────────────────────────────
if [[ "$INSTALL_MODE" == "binary" ]]; then
  if dpkg -s "$ROS_PACKAGE" &>/dev/null; then
    warn "${ROS_PACKAGE} is already installed."
    read -r -p "  Re-install / upgrade? [y/N] " _confirm
    [[ "${_confirm,,}" == "y" ]] || { info "Nothing to do. Exiting."; exit 0; }
  fi
elif [[ "$INSTALL_MODE" == "source" ]]; then
  if [[ -f "${WORKSPACE}/install/local_setup.bash" ]]; then
    warn "A previous source build exists at ${WORKSPACE}."
    read -r -p "  Rebuild from scratch? [y/N] " _confirm
    [[ "${_confirm,,}" == "y" ]] || { info "Nothing to do. Exiting."; exit 0; }
  fi
fi

# ── Locale setup ───────────────────────────────────────────────────────────────
setup_locale() {
  step "Configuring locale"

  # Map number → locale code (avoid associative array empty-key bug)
  locale_for_choice() {
    case "$1" in
      1) echo "en_US" ;; 2) echo "de_DE" ;; 3) echo "fr_FR" ;;
      4) echo "es_ES" ;; 5) echo "it_IT" ;; 6) echo "ja_JP" ;;
      7) echo "zh_CN" ;; *) echo "en_US" ;;
    esac
  }

  echo ""
  echo "Select locale:"
  echo "  1) English — en_US  (default)"
  echo "  2) German  — de_DE"
  echo "  3) French  — fr_FR"
  echo "  4) Spanish — es_ES"
  echo "  5) Italian — it_IT"
  echo "  6) Japanese — ja_JP"
  echo "  7) Chinese (Simplified) — zh_CN"
  echo ""
  read -r -p "Choice [1-7, Enter = 1]: " _choice

  # Strip whitespace; default to 1 if empty or invalid
  _choice="${_choice//[[:space:]]/}"
  LANG_CODE="$(locale_for_choice "${_choice}")"
  LOCALE="${LANG_CODE}.UTF-8"
  info "Using locale: $LOCALE"

  # Install locales package if needed — best-effort (may be absent in minimal images)
  if ! command -v locale-gen &>/dev/null; then
    run_with_progress "install locales" \
      $SUDO apt-get install -y locales || {
      warn "'locales' package unavailable — skipping locale config (continuing install)"
      return 0
    }
  fi

  $SUDO locale-gen "${LOCALE}" >> "$LOGFILE" 2>&1 || {
    warn "locale-gen failed for ${LOCALE}, trying en_US.UTF-8 fallback"
    LOCALE="en_US.UTF-8"
    $SUDO locale-gen "${LOCALE}" >> "$LOGFILE" 2>&1 || {
      warn "locale-gen unavailable — skipping locale config (continuing install)"
      return 0
    }
  }
  $SUDO update-locale LANG="$LOCALE" LC_ALL="$LOCALE" >> "$LOGFILE" 2>&1 || true
  export LANG="$LOCALE"
  export LC_ALL="$LOCALE"
  info "Locale set to ${LOCALE} ✓"
}

# ── Initial apt update (must happen before any install, including locales) ──────
step "Updating package lists"
run_with_progress "apt update"   $SUDO apt-get update -qq

# FIX: locale is now prompted for BOTH binary and source modes.
# Pass --skip-locale on the command line to bypass this step.
if [[ $SKIP_LOCALE -eq 0 ]]; then
  setup_locale
fi

# ── Base tools ─────────────────────────────────────────────────────────────────
step "Installing base tools"
run_with_progress "base packages" \
  $SUDO apt-get install -y curl git software-properties-common
run_with_progress "add universe repo" \
  $SUDO add-apt-repository universe -y

# ── ROS 2 APT repository ───────────────────────────────────────────────────────
setup_ros_repo() {
  step "Adding ROS 2 APT repository"

  # Fetch latest ros2-apt-source release tag
  local tag
  tag=$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
    | grep '"tag_name"' | head -1 | awk -F'"' '{print $4}') \
    || die "Could not fetch ros-apt-source release info. Check your internet connection."

  [[ -z "$tag" ]] && die "ros-apt-source release tag was empty."

  local deb_url="https://github.com/ros-infrastructure/ros-apt-source/releases/download/${tag}/ros2-apt-source_${tag}.${CODENAME}_all.deb"
  local deb_path="/tmp/ros2-apt-source_${tag}.deb"

  run_with_progress "download ros2-apt-source" \
    curl -fsSL -o "$deb_path" "$deb_url" \
    || die "Failed to download ${deb_url}"

  run_with_progress "register ROS repo" \
    $SUDO dpkg -i "$deb_path"
  run_with_progress "apt update (ROS)" \
    $SUDO apt-get update -qq
}

setup_ros_repo

# ==============================================================================
#  BINARY INSTALL
# ==============================================================================
install_binary() {
  step "Installing ${ROS_PACKAGE} (binary)"

  run_with_progress "install ${ROS_PACKAGE}" \
    $SUDO apt-get install -y "$ROS_PACKAGE" \
    || die "apt-get install ${ROS_PACKAGE} failed. Check ${LOGFILE} for details."

  # ── Shell integration ────────────────────────────────────────────────────────
  local setup_line="source /opt/ros/${ROS_DISTRO}/setup.bash"

  for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    if [[ -f "$rc" ]] && ! grep -qF "$setup_line" "$rc"; then
      echo "" >> "$rc"
      echo "# ROS 2 ${ROS_DISTRO}" >> "$rc"
      echo "$setup_line" >> "$rc"
      info "Added ROS setup to ${rc}"
    fi
  done
}

# ==============================================================================
#  SOURCE BUILD
# ==============================================================================
install_source() {
  step "Source build — this will take 2–4 hours"

  # Extra build deps
  run_with_progress "build dependencies" \
    $SUDO apt-get install -y \
      build-essential cmake python3-pip ros-dev-tools python3-rosdep

  mkdir -p "${WORKSPACE}/src"
  cd "$WORKSPACE"

  # ── Clone sources ────────────────────────────────────────────────────────────
  step "Cloning ROS 2 sources (vcs import)"
  run_with_progress "vcs import sources" \
    vcs import --input \
      "https://raw.githubusercontent.com/ros2/ros2/${ROS_DISTRO}/ros2.repos" src \
    || die "vcs import failed. Check ${LOGFILE}."

  # ── rosdep ───────────────────────────────────────────────────────────────────
  step "Running rosdep"

  if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
    run_with_progress "rosdep init" $SUDO rosdep init
  else
    info "rosdep already initialised, skipping init"
  fi

  run_with_progress "rosdep update"  rosdep update
  run_with_progress "apt upgrade"    $SUDO apt-get upgrade -y
  run_with_progress "rosdep install" \
    rosdep install --from-paths src --ignore-src \
      --rosdistro "${ROS_DISTRO}" -y \
      --skip-keys "fastcdr rti-connext-dds-6.0.1 urdfdom_headers" \
    || die "rosdep install failed. Check ${LOGFILE}."

  # ── Build ────────────────────────────────────────────────────────────────────
  step "Building with colcon"

  local workers="${PARALLEL_WORKERS:-$(nproc)}"
  info "Parallel workers: ${workers}"

  local cmake_build_type="RelWithDebInfo"
  [[ $FAST_MODE -eq 1 ]] && cmake_build_type="Release"

  colcon_with_progress "colcon build" \
    colcon build \
      --symlink-install \
      --parallel-workers "$workers" \
      --cmake-args "-DCMAKE_BUILD_TYPE=${cmake_build_type}" \
    || die "colcon build failed. Check ${LOGFILE}."
}

# ── Run chosen install mode ────────────────────────────────────────────────────
case "$INSTALL_MODE" in
  binary) install_binary ;;
  source) install_source ;;
esac

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}======================================"
echo -e " ✓  INSTALL COMPLETE"
echo -e "======================================${RESET}"
echo ""

if [[ "$INSTALL_MODE" == "binary" ]]; then
  echo -e "Activate in a ${BOLD}new terminal${RESET} (already added to ~/.bashrc):"
  echo -e "  ${CYAN}source /opt/ros/${ROS_DISTRO}/setup.bash${RESET}"
  echo ""
  echo -e "Quick test:"
  echo -e "  ${CYAN}ros2 run demo_nodes_cpp talker${RESET}"
  echo -e "  ${CYAN}ros2 run demo_nodes_py  listener${RESET}   # (new terminal)"
else
  echo -e "Activate workspace:"
  echo -e "  ${CYAN}source ${WORKSPACE}/install/local_setup.bash${RESET}"
  echo ""
  echo -e "Quick test:"
  echo -e "  ${CYAN}ros2 run demo_nodes_cpp talker${RESET}"
  echo -e "  ${CYAN}ros2 run demo_nodes_py  listener${RESET}   # (new terminal)"
fi

echo ""
echo -e "Full install log: ${CYAN}${LOGFILE}${RESET}"
echo ""
