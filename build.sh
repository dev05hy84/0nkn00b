#!/usr/bin/env bash
#
# build.sh - build the Linux kernel + Mali Kbase driver for the Arm GPU bug
#            bounty virtual platform (arm64 / QEMU virt, "dummy model").
#
# Follows Kernel/doc/arm_gpu_virtual_platform_how_to_guide.pdf, Arm64 /
# "Device Tree" configuration (the recommended path; no driver patches) and
# Kernel/README for the base-kernel config. Adapted from the 5th-gen guide to
# the Bifrost r36p0 driver (Job Manager by default).
#
# Produces:
#   build/kernel-<ver>/arch/arm64/boot/Image.gz   - kernel image
#   build/kernel-<ver>/.../midgard/mali_kbase.ko  - Kbase module
#   build/images/virt_mali.dtb                    - qemu-virt DTB + Mali node
#   out/Image.gz                                  - collected kernel image
#   out/mali_kbase.ko                             - collected Kbase module
#   out/virt_mali.dtb                             - collected DTB
#   out/initramfs-arm64.cpio.gz                   - boot initramfs (busybox + module)
#
# Overridable environment variables:
#   KERNEL_VERSION     (default 5.10.155)
#   DRIVER_VERSION     (default r36p0-01eac0)
#   ARCH               (default arm64; the guide's supported path)
#   CROSS_COMPILE      (default aarch64-linux-gnu-)
#   MALI_MODE          jm | csf          (default jm - Bifrost Job Manager)
#   DRIVER_MODE        module | builtin  (default module; CONFIG_MALI_MIDGARD=m)
#   ENABLE_KASAN       0 | 1             (default 0; README used 1)
#   ENABLE_DEBUG_INFO  0 | 1             (default 0; README used 1)
#   AUTO_INSTALL       0 | 1             (default 1: apt-get missing packages)
#   JOBS               (default: nproc)
#   FORCE_BUILD        0 | 1             (default 0: skip build if out/ artifacts exist)
#   BUILD_INITRAMFS    0 | 1             (default 1: build the boot initramfs)
#
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-5.10.155}"
DRIVER_VERSION="${DRIVER_VERSION:-r36p0-01eac0}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
MALI_MODE="${MALI_MODE:-jm}"
DRIVER_MODE="${DRIVER_MODE:-module}"
ENABLE_KASAN="${ENABLE_KASAN:-0}"
ENABLE_DEBUG_INFO="${ENABLE_DEBUG_INFO:-0}"
AUTO_INSTALL="${AUTO_INSTALL:-1}"
JOBS="${JOBS:-$(nproc)}"
FORCE_BUILD="${FORCE_BUILD:-0}"
BUILD_INITRAMFS="${BUILD_INITRAMFS:-1}"

# Make sure every (sub-)make invocation picks the cross toolchain.
export ARCH CROSS_COMPILE

KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v5.x/${KERNEL_TARBALL}"
DRIVER_TARBALL="BX304L01B-SW-99002-${DRIVER_VERSION}.tar"
DRIVER_URL="https://developer.arm.com/-/media/Files/downloads/mali-drivers/kernel/mali-bifrost-gpu/${DRIVER_TARBALL}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DL="$ROOT/downloads"
BUILD="$ROOT/build"
KDIR="$BUILD/kernel-${KERNEL_VERSION}"
MDIR="$BUILD/mali-${DRIVER_VERSION}"
IMG="$BUILD/images"
LOGDIR="$BUILD/logs"
OUT="$ROOT/out"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$ARCH" = arm64 ] || fail "ARCH=$ARCH unsupported; this flow is the arm64/Device Tree path"
case "$MALI_MODE" in jm|csf) ;; *) fail "MALI_MODE must be jm|csf (got $MALI_MODE)";; esac
case "$DRIVER_MODE" in module|builtin) ;; *) fail "DRIVER_MODE must be module|builtin (got $DRIVER_MODE)";; esac

# ---------------------------------------------------------------------------
# [0/9] prerequisite check (install missing packages)
# ---------------------------------------------------------------------------
# package:probe-command   (empty probe => verify with dpkg -s)
DEPS=(
  "build-essential:gcc"
  "gcc-aarch64-linux-gnu:aarch64-linux-gnu-gcc"
  "binutils-aarch64-linux-gnu:aarch64-linux-gnu-ld"
  "device-tree-compiler:dtc"
  "qemu-system-arm:qemu-system-aarch64"
  "wget:wget"
  "xz-utils:xz"
  "bc:bc"
  "bison:bison"
  "flex:flex"
  "python3:python3"
  "cpio:cpio"
  "libssl-dev:"        # kernel module signing / OPENSSL
  "libelf-dev:"        # objtool / ELF tooling
  "libncurses-dev:"    # menuconfig
)
have() { [ -n "$2" ] && command -v "$2" >/dev/null 2>&1 || dpkg -s "$1" >/dev/null 2>&1; }

log "[0/9] checking prerequisites"
missing=()
for d in "${DEPS[@]}"; do
  pkg="${d%%:*}"; cmd="${d#*:}"
  have "$pkg" "$cmd" || missing+=("$pkg")
done
if [ "${#missing[@]}" -gt 0 ]; then
  log "missing packages: ${missing[*]}"
  [ "$AUTO_INSTALL" = 1 ] || fail "install them, or rerun with AUTO_INSTALL=1"
  command -v apt-get >/dev/null 2>&1 || fail "apt-get unavailable; install manually: ${missing[*]}"
  APT=apt-get; [ "$(id -u)" = 0 ] || APT="sudo apt-get"
  $APT update
  $APT install -y "${missing[@]}"
else
  log "all prerequisites present"
fi

# ---------------------------------------------------------------------------
# [1/9] create the working structure
# ---------------------------------------------------------------------------
log "[1/9] creating directory structure"
mkdir -p "$DL" "$KDIR" "$MDIR" "$IMG" "$LOGDIR" "$OUT"
if [ ! -f "$ROOT/.gitignore" ]; then
  cat > "$ROOT/.gitignore" <<'EOF'
# build.sh working tree
/downloads/
/build/
/out/
*.tar
linux-*.tar.xz
*.part
EOF
fi
printf '  %s\n' "downloads/  build/kernel-${KERNEL_VERSION}/  build/mali-${DRIVER_VERSION}/" \
                "build/images/  build/logs/  out/"

# ---------------------------------------------------------------------------
# decide whether the kernel/driver build can be skipped
# ---------------------------------------------------------------------------
# If a previous run already produced the kernel image and the Kbase module in
# out/, reuse them and jump straight to the DTB / initramfs / launch steps.
# Force a full rebuild with FORCE_BUILD=1.
if [ "$FORCE_BUILD" != 1 ] && [ -s "$OUT/Image.gz" ] && [ -s "$OUT/mali_kbase.ko" ]; then
  SKIP_BUILD=1
  log "existing kernel + driver found in $OUT/ -> skipping build steps (FORCE_BUILD=1 to rebuild)"
else
  SKIP_BUILD=0
fi

if [ "$SKIP_BUILD" = 0 ]; then

# ---------------------------------------------------------------------------
# fetch helpers
# ---------------------------------------------------------------------------
# adopt a tarball already present in the repo root (e.g. a manual download)
adopt() { # <basename>
  if [ ! -s "$DL/$1" ] && [ -s "$ROOT/$1" ]; then
    log "adopting existing $1 from repo root"
    mv "$ROOT/$1" "$DL/$1"
  fi
}
fetch() { # <url> <dest>
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then echo "have $(basename "$dest")"; return 0; fi
  echo "downloading $(basename "$dest")"
  wget -q -O "$dest.part" "$url" || { rm -f "$dest.part"; fail "download failed: $url"; }
  mv "$dest.part" "$dest"
}

# ---------------------------------------------------------------------------
# [2/9] fetch sources
# ---------------------------------------------------------------------------
log "[2/9] fetching sources (kernel $KERNEL_VERSION, driver $DRIVER_VERSION)"
adopt "$KERNEL_TARBALL"
adopt "$DRIVER_TARBALL"
fetch "$KERNEL_URL" "$DL/$KERNEL_TARBALL"
fetch "$DRIVER_URL" "$DL/$DRIVER_TARBALL"

# ---------------------------------------------------------------------------
# [3/9] extract
# ---------------------------------------------------------------------------
log "[3/9] extracting"
if [ ! -f "$KDIR/Makefile" ]; then
  tar -C "$KDIR" --strip-components=1 -xJf "$DL/$KERNEL_TARBALL"
fi
# Bifrost tarball has no wrapper dir: entries start at driver/product/...
rm -rf "$MDIR"; mkdir -p "$MDIR"
tar -C "$MDIR" -xf "$DL/$DRIVER_TARBALL"
MDIR_SRC="$MDIR/driver/product/kernel"
[ -d "$MDIR_SRC" ] || fail "driver tree not found under $MDIR"

# ---------------------------------------------------------------------------
# [4/9] integrate Kbase into the kernel tree
# ---------------------------------------------------------------------------
log "[4/9] integrating Kbase into the kernel tree"
cp -a "$MDIR_SRC/drivers/." "$KDIR/drivers/"
if [ ! -f "$KDIR/drivers/gpu/arm/Kconfig" ]; then
  mkdir -p "$KDIR/drivers/gpu/arm"
  cp -a "$MDIR_SRC/drivers/gpu/arm/." "$KDIR/drivers/gpu/arm/"
fi
# wire the driver into the build
if ! grep -q 'gpu/arm' "$KDIR/drivers/gpu/Makefile" 2>/dev/null; then
  echo 'obj-$(CONFIG_MALI_MIDGARD) += arm/' >> "$KDIR/drivers/gpu/Makefile"
fi
if ! grep -q 'source "drivers/gpu/arm/Kconfig"' "$KDIR/drivers/video/Kconfig" 2>/dev/null; then
  echo 'source "drivers/gpu/arm/Kconfig"' >> "$KDIR/drivers/video/Kconfig"
fi
grep -q 'source "drivers/gpu/arm/Kconfig"' "$KDIR/drivers/video/Kconfig" \
  || fail "drivers/video/Kconfig not wired for the Mali arm Kconfig"

# ---------------------------------------------------------------------------
# [5/9] configure
# ---------------------------------------------------------------------------
log "[5/9] configuring the kernel (arm64 / Device Tree, MALI_MODE=$MALI_MODE)"
make -C "$KDIR" ARCH="$ARCH" defconfig >/dev/null
{
  echo
  echo '# --- Mali Kbase (Arm GPU bug bounty virtual platform, arm64/DT) ---'
  [ "$DRIVER_MODE" = module ] && echo 'CONFIG_MALI_MIDGARD=m' || echo 'CONFIG_MALI_MIDGARD=y'
  echo 'CONFIG_MALI_EXPERT=y'
  echo 'CONFIG_MALI_NO_MALI=y'
  echo 'CONFIG_MALI_PLATFORM_NAME="devicetree"'
  [ "$MALI_MODE" = csf ] && echo 'CONFIG_MALI_CSF_SUPPORT=y' || echo '# CONFIG_MALI_CSF_SUPPORT is not set'
  echo 'CONFIG_MALI_DEVFREQ=y'
  echo 'CONFIG_PM=y'
  echo 'CONFIG_PM_DEVFREQ=y'
  echo 'CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=y'
  # base-kernel config from Kernel/README (RANDOMIZE_BASE=n always, for nokaslr)
  [ "$ENABLE_KASAN" = 1 ] && echo 'CONFIG_KASAN=y' || echo '# CONFIG_KASAN is not set'
  [ "$ENABLE_DEBUG_INFO" = 1 ] && echo 'CONFIG_DEBUG_INFO=y' || echo '# CONFIG_DEBUG_INFO is not set'
  echo 'CONFIG_RANDOMIZE_BASE=n'
} >> "$KDIR/.config"
make -C "$KDIR" ARCH="$ARCH" olddefconfig 2>&1 | tee "$LOGDIR/config.log"
grep -q "^CONFIG_MALI_MIDGARD=$([ "$DRIVER_MODE" = module ] && echo m || echo y)" "$KDIR/.config" \
  || fail "CONFIG_MALI_MIDGARD missing from .config"
grep -q '^CONFIG_MALI_PLATFORM_NAME="devicetree"' "$KDIR/.config" \
  || fail "CONFIG_MALI_PLATFORM_NAME not devicetree"

# ---------------------------------------------------------------------------
# [6/9] build
# ---------------------------------------------------------------------------
log "[6/9] building kernel + modules ($JOBS jobs; this can take a while)"
set +e
make -C "$KDIR" ARCH="$ARCH" -j"$JOBS" 2>&1 | tee "$LOGDIR/kernel-build.log"
rc=${PIPESTATUS[0]}
set -e
[ "$rc" -eq 0 ] || { tail -40 "$LOGDIR/kernel-build.log"; fail "kernel build failed (see $LOGDIR/kernel-build.log)"; }
[ -f "$KDIR/arch/arm64/boot/Image.gz" ] || fail "Image.gz not built"

MKO="$(find "$KDIR/drivers/gpu/arm/midgard" -name 'mali_kbase.ko' 2>/dev/null | head -1 || true)"
[ -n "$MKO" ] || fail "mali_kbase.ko not built (is CONFIG_MALI_MIDGARD=m?)"
cp -f "$KDIR/arch/arm64/boot/Image.gz" "$OUT/Image.gz"
cp -f "$MKO"                           "$OUT/mali_kbase.ko"
log "collected out/Image.gz and out/mali_kbase.ko"

fi  # SKIP_BUILD

# ---------------------------------------------------------------------------
# [7/9] build the Mali device-tree blob (only if we don't already have one)
# ---------------------------------------------------------------------------
if [ "$FORCE_BUILD" = 1 ] || [ ! -s "$OUT/virt_mali.dtb" ]; then
  log "[7/9] building the Mali device-tree node into a qemu-virt DTB"
  qemu-system-aarch64 -machine virt -machine "dumpdtb=$IMG/virt_base.dtb" >/dev/null 2>&1
  [ -s "$IMG/virt_base.dtb" ] || fail "qemu dumpdtb failed"
  dtc -I dtb -O dts "$IMG/virt_base.dtb" -o "$IMG/virt_base.dts" >/dev/null 2>&1
  python3 - "$IMG/virt_base.dts" "$IMG/virt_mali.dts" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(True)
# Guide node. With the "dummy model" the driver only parses it, so the MMIO
# address just has to be non-overlapping; we place it well above RAM.
node = '''\t\tgpu@6e000000 {
\t\t\tcompatible = "arm,mali-midgard";
\t\t\treg = <0x0 0x6e000000 0x0 0x200000>;
\t\t\tinterrupts = <0x0 0xa8 0x4>, <0x0 0xa8 0x4>, <0x0 0xa8 0x4>;
\t\t\tinterrupt-names = "JOB", "MMU", "GPU";
\t\t\tclock-names = "apb_pclk";
\t\t\tclocks = <0x8000>;
\t\t};
'''
# find the root node and its closing brace, insert the gpu node as the last child
text = ''.join(lines)
start = text.find('{')
depth = 0
end = -1
for i in range(start, len(text)):
    if text[i] == '{': depth += 1
    elif text[i] == '}':
        depth -= 1
        if depth == 0:
            end = i
            break
if end < 0:
    sys.exit("could not locate root node")
out = text[:end] + '\n' + node + text[end:]
open(dst, 'w').write(out)
PY
  dtc -I dts -O dtb "$IMG/virt_mali.dts" -o "$OUT/virt_mali.dtb" >/dev/null 2>&1
  [ -s "$OUT/virt_mali.dtb" ] || fail "dtc dts->dtb failed"
else
  log "[7/9] using existing out/virt_mali.dtb"
fi

# ---------------------------------------------------------------------------
# [8/9] verify artifacts
# ---------------------------------------------------------------------------
log "[8/9] verifying artifacts"
fdtget -t s "$OUT/virt_mali.dtb" /gpu@6e000000 compatible 2>/dev/null | grep -q 'arm,mali-midgard' \
  || fail "gpu node missing/invalid in $OUT/virt_mali.dtb"
[ -s "$OUT/Image.gz" ]     || fail "out/Image.gz missing"
[ -s "$OUT/mali_kbase.ko" ] || fail "out/mali_kbase.ko missing"

{
  echo "kernel  : $OUT/Image.gz ($(stat -c%s "$OUT/Image.gz") bytes)"
  echo "module  : $OUT/mali_kbase.ko ($(stat -c%s "$OUT/mali_kbase.ko") bytes)"
  echo "dtb     : $OUT/virt_mali.dtb ($(stat -c%s "$OUT/virt_mali.dtb") bytes)"
} | tee "$LOGDIR/summary.txt"

# ---------------------------------------------------------------------------
# [8/9] build the boot initramfs (from scratch)
# ---------------------------------------------------------------------------
if [ "${BUILD_INITRAMFS:-1}" = 1 ]; then
  log "[9/9] building the boot initramfs"
  KO="$OUT/mali_kbase.ko" OUT="$OUT/initramfs-arm64.cpio.gz" \
    ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" JOBS="$JOBS" \
    "$ROOT/initramfs_build.sh" || fail "initramfs build failed"
else
  log "[9/9] skipping initramfs (BUILD_INITRAMFS=0)"
fi

cat <<EOF

==> done. Artifacts copied to $OUT/
==> launch with:

qemu-system-aarch64 \\
    -machine virt \\
    -cpu cortex-a57 \\
    -smp 2 \\
    -m 4096 \\
    -nographic \\
    -net nic -net user \\
    -kernel $OUT/Image.gz \\
    -initrd $OUT/initramfs-arm64.cpio.gz \\
    -dtb $OUT/virt_mali.dtb \\
    -append 'console=ttyAMA0 rdinit=/init acpi=off nokaslr loglevel=7'

# add  -S -gdb tcp::12345  before -kernel to attach gdb
# in the guest (if INITRAMFS_SHELL=1) run:  /load_mod.sh
#   dummy model: expect "Using Dummy Model" / "Probed as mali0" in dmesg
EOF
