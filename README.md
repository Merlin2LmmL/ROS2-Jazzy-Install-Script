# ROS 2 Jazzy Installer

One-script install for ROS 2 Jazzy on **Ubuntu 24.04 (Noble)**.  
Binary APT install by default (~5 min). Optional full source build.

---

## Quick start (Recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/Merlin2LmmL/ROS2-Jazzy-Install-Script/refs/heads/main/ros2-jazzy-installer.sh \
  -o ros2-jazzy-installer.sh \
  && chmod +x ros2-jazzy-installer.sh \
  && ./ros2-jazzy-installer.sh
```

### Alternatively: fast source build (12 parallel workers)

```bash
curl -fsSL https://raw.githubusercontent.com/Merlin2LmmL/ROS2-Jazzy-Install-Script/refs/heads/main/ros2-jazzy-installer.sh \
  -o ros2-jazzy-installer.sh \
  && chmod +x ros2-jazzy-installer.sh \
  && ./ros2-jazzy-installer.sh --source --fast --parallel 12
```

---

## Options

| Flag | Default | Description |
|---|---|---|
| *(none)* | — | Binary APT desktop install, ~5 min |
| `--source` | — | Full source build, ~2–4 hours |
| `--fast` | off | Release mode + max CPU usage (source only) |
| `--parallel N` | `nproc` | Parallel build workers (source only) |
| `--package PKG` | `ros-jazzy-desktop` | APT package to install, e.g. `ros-jazzy-ros-base` |
| `--skip-locale` | off | Skip locale configuration |
| `--workspace DIR` | `~/ros2_jazzy_ws` | Source build output directory |

---

## After install

```bash
source /opt/ros/jazzy/setup.bash          # binary install
# or
source ~/ros2_jazzy_ws/install/local_setup.bash  # source build
```

Test it:
```bash
ros2 run demo_nodes_cpp talker            # terminal 1
ros2 run demo_nodes_py  listener          # terminal 2
```

> If something goes wrong, the full log is at `/tmp/ros2_jazzy_install_<timestamp>.log`.
