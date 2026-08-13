#!/bin/bash
# ============================================================
# 功能：创建带 ESP (GRUB) 的 Debian 根文件系统镜像
# ============================================================

set -e

# -------------------- 用户配置区域 --------------------
WORKSPACE="${WORKSPACE:-$PWD}"
ROOTFS_IMG="$WORKSPACE/rootfs-debian.img"
ROOTFS_SIZE="4G"                # 镜像大小（ESP + rootfs）
ESP_SIZE="400M"                 # EFI 系统分区大小
CHROOT_DIR="$WORKSPACE/chroot"
MY_UUID="20336aa9-c9de-431a-b679-dcf10065c121"

# -------------------- 0. 检查依赖 --------------------
echo "==> 检查必要命令..."
for cmd in dd mkfs.ext4 mkfs.vfat debootstrap mount umount parted kpartx; do
    if ! command -v $cmd &> /dev/null; then
        echo "错误: 未找到 $cmd，请先安装对应软件包"
        exit 1
    fi
done

# -------------------- 1. 创建空白镜像并分区 --------------------
echo "==> 创建空白镜像: $ROOTFS_IMG (大小: $ROOTFS_SIZE)"
dd if=/dev/zero of="$ROOTFS_IMG" bs=1G count=${ROOTFS_SIZE%G} status=progress

echo "==> 创建 GPT 分区表..."
parted -s "$ROOTFS_IMG" mklabel gpt

echo "==> 创建 ESP 分区 (FAT32, $ESP_SIZE)..."
parted -s "$ROOTFS_IMG" mkpart primary fat32 1MiB $ESP_SIZE
parted -s "$ROOTFS_IMG" set 1 esp on

echo "==> 创建 rootfs 分区 (ext4)..."
parted -s "$ROOTFS_IMG" mkpart primary ext4 $ESP_SIZE 100%

# -------------------- 2. 挂载分区并格式化 --------------------
echo "==> 设置 loop 设备并挂载..."
# 使用 kpartx 或 losetup 来映射分区
LOOPDEV=$(losetup -f --show -P "$ROOTFS_IMG")
# 等待分区设备出现
sleep 2
ESP_PART="${LOOPDEV}p1"
ROOT_PART="${LOOPDEV}p2"

echo "==> 格式化 ESP 分区为 FAT32..."
mkfs.vfat -F 32 "$ESP_PART"

echo "==> 格式化 rootfs 分区为 ext4 (UUID: $MY_UUID)..."
mkfs.ext4 -U "$MY_UUID" -F "$ROOT_PART"

# -------------------- 3. 挂载 rootfs 并引导到 chroot --------------------
echo "==> 挂载 rootfs 到 $CHROOT_DIR"
sudo mkdir -p "$CHROOT_DIR"
sudo mount "$ROOT_PART" "$CHROOT_DIR"

# 挂载 ESP 分区（后续用于安装 GRUB）
sudo mkdir -p "$CHROOT_DIR/boot/efi"
sudo mount "$ESP_PART" "$CHROOT_DIR/boot/efi"

echo "==> 执行 debootstrap（从 Debian 官方源拉取 arm64 架构的 trixie）..."
sudo debootstrap --arch arm64 trixie "$CHROOT_DIR" http://deb.debian.org/debian

# -------------------- 4. 挂载必要的虚拟文件系统 --------------------
echo "==> 挂载 /proc /dev /sys"
sudo mount --bind /proc "$CHROOT_DIR/proc"
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
sudo mount --bind /sys "$CHROOT_DIR/sys"

# -------------------- 5. chroot 环境配置（含 GRUB 安装） --------------------
echo "==> 进入 chroot 执行配置脚本..."
sudo chroot "$CHROOT_DIR" /bin/bash << 'EOF'
# 5.1 配置软件源
cat > /etc/apt/sources.list << 'EOL'
deb http://mirrors.ustc.edu.cn/debian trixie main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian trixie-updates main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian trixie-backports main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian-security trixie-security main contrib non-free non-free-firmware
EOL

# 5.2 更新并安装基础包 + GRUB UEFI
apt update
apt upgrade -y
apt install -y man man-db bash-completion vim tmux network-manager \
    chrony openssh-server initramfs-tools locales sudo \
    grub-efi-arm64-bin grub-efi-arm64-signed \
    dosfstools efibootmgr nano axel wget curl firmware-qcom-soc\
    --no-install-recommends

# 5.3 设置 locale 和时区
locale-gen en_US.UTF-8 zh_CN.UTF-8
rm -f /etc/localtime
ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 5.4 设置 hostname
echo 'oneplus-7t' > /etc/hostname

# 5.5 创建用户 hol
useradd -m -s /bin/bash mmzc
usermod -aG sudo mmzc
echo "mmzc:mmzc" | chpasswd

# 5.6 配置自动扩展文件系统服务
cat > /etc/systemd/system/resizefs.service << 'EOL'
[Unit]
Description=Expand root filesystem to fill partition
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'exec /usr/sbin/resize2fs $(findmnt -nvo SOURCE /)'
ExecStartPost=/usr/bin/systemctl disable resizefs.service
RemainAfterExit=true

[Install]
WantedBy=default.target
EOL
systemctl enable resizefs.service

# 5.7 安装 GRUB 到 ESP 分区
echo "==> 安装 GRUB 到 /boot/efi..."
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=Debian --recheck --no-floppy

# 5.8 生成 GRUB 配置文件
cat > /etc/default/grub << 'EOL'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=tty0 console=ttyMSM0 earlycon loglevel=4"
EOL

# 5.9 生成 grub.cfg
mkdir -p /boot/grub
update-grub

# 5.10 清理
apt clean
rm -f /tmp/*
history -c
EOF

# -------------------- 6. 拷贝内核 .deb 包（如果存在） --------------------
echo "==> 尝试安装预编译的内核 .deb 包..."
if ls "$WORKSPACE"/linux-*.deb 1> /dev/null 2>&1; then
    sudo cp "$WORKSPACE"/linux-*.deb "$CHROOT_DIR/tmp/"
    sudo chroot "$CHROOT_DIR" /bin/bash << 'EOF'
cd /tmp
dpkg -i linux-*.deb || true
apt --fix-broken install -y

# 安装内核后重新生成 initrd
KERNEL_VERSION=$(ls /lib/modules/ | head -1)
if [ -n "$KERNEL_VERSION" ]; then
    echo "==> 生成 initrd for kernel $KERNEL_VERSION"
    update-initramfs -c -k $KERNEL_VERSION
fi
# 更新 GRUB 以识别新内核
update-grub
EOF
fi

# -------------------- 7. 拷贝 firmware（如果存在） --------------------
if [ -d "$WORKSPACE/firmware" ]; then
    echo "==> 拷贝 firmware 到 rootfs"
    sudo cp -r "$WORKSPACE/firmware/"* "$CHROOT_DIR/usr/lib/firmware/"
    sudo chroot "$CHROOT_DIR" ldconfig
fi

# -------------------- 8. 清理并卸载 --------------------
echo "==> 清理并卸载挂载点"
sudo umount "$CHROOT_DIR/boot/efi" || true
sudo umount "$CHROOT_DIR/proc" || true
sudo umount "$CHROOT_DIR/dev/pts" || true
sudo umount "$CHROOT_DIR/dev" || true
sudo umount "$CHROOT_DIR/sys" || true
sudo umount "$CHROOT_DIR" || true

# 释放 loop 设备
sudo losetup -d "$LOOPDEV" 2>/dev/null || true

echo "=================================================="
echo "✅ Debian rootfs.img (含 ESP + GRUB) 生成完成！"
echo "📍 镜像位置: $ROOTFS_IMG"
echo "🔑 rootfs UUID: $MY_UUID"
echo "📌 启动流程: 刷写镜像 -> UEFI 引导 -> GRUB -> Linux"
echo "=================================================="
