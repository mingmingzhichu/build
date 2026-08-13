#!/bin/bash
# ============================================================
# 功能：生成两个独立镜像：esp.img (GRUB) + rootfs.img (Debian)
# 版本：修正版 v2
# ============================================================

set -e

# -------------------- 清理函数 --------------------
cleanup() {
    echo "==> 执行清理..."
    sudo umount "$ESP_MOUNT" 2>/dev/null || true
    sudo umount "$CHROOT_DIR/proc" 2>/dev/null || true
    sudo umount "$CHROOT_DIR/dev/pts" 2>/dev/null || true
    sudo umount "$CHROOT_DIR/dev" 2>/dev/null || true
    sudo umount "$CHROOT_DIR/sys" 2>/dev/null || true
    sudo umount "$CHROOT_DIR" 2>/dev/null || true
    rmdir "$ESP_MOUNT" 2>/dev/null || true
    echo "✅ 清理完成"
}
trap cleanup EXIT

# -------------------- 用户配置区域 --------------------
WORKSPACE="${WORKSPACE:-$PWD}"
ESP_IMG="$WORKSPACE/esp.img"
ROOTFS_IMG="$WORKSPACE/rootfs.img"
ESP_SIZE="256M"
ROOTFS_SIZE="2G"
CHROOT_DIR="$WORKSPACE/chroot"
ESP_MOUNT="$WORKSPACE/esp_mount"
MY_UUID="20336aa9-c9de-431a-b679-dcf10065c121"

# -------------------- 0. 检查依赖 --------------------
echo "==> 检查必要命令..."
for cmd in dd mkfs.ext4 mkfs.vfat debootstrap mount umount img2simg; do
    if ! command -v $cmd &> /dev/null; then
        echo "错误: 未找到 $cmd，请先安装对应软件包"
        exit 1
    fi
done

# 检查 GRUB UEFI 文件是否存在
GRUB_EFI="/usr/lib/grub/arm64-efi/grub.efi"
if [ ! -f "$GRUB_EFI" ]; then
    echo "错误: 未找到 $GRUB_EFI"
    echo "请安装: sudo apt install grub-efi-arm64-bin"
    exit 1
fi

# ============================================================
# 第一部分：生成 ESP 镜像 (GRUB UEFI)
# ============================================================
echo "=================================================="
echo "==> 生成 ESP 镜像: $ESP_IMG (大小: $ESP_SIZE)"
dd if=/dev/zero of="$ESP_IMG" bs=1M count=256 status=progress
mkfs.vfat -F 32 -n EFI "$ESP_IMG"

echo "==> 挂载 ESP 镜像到 $ESP_MOUNT"
mkdir -p "$ESP_MOUNT"
sudo mount "$ESP_IMG" "$ESP_MOUNT"

# 创建 GRUB 目录结构
sudo mkdir -p "$ESP_MOUNT/EFI/BOOT"
sudo mkdir -p "$ESP_MOUNT/EFI/Debian"

echo "==> 复制 GRUB UEFI 文件到 ESP..."
sudo cp "$GRUB_EFI" "$ESP_MOUNT/EFI/BOOT/BOOTAA64.EFI"
sudo cp "$GRUB_EFI" "$ESP_MOUNT/EFI/Debian/grubaa64.efi"

# 创建 grub.cfg
sudo tee "$ESP_MOUNT/EFI/Debian/grub.cfg" > /dev/null << 'EOF'
set timeout=5
set default=0

# 尝试加载图形界面（如果失败则回退到文本模式）
insmod efi_gop
insmod efi_uga

menuentry "Debian Linux" {
    echo "加载内核..."
    linux /Image.gz root=UUID=20336aa9-c9de-431a-b679-dcf10065c121 rw console=tty0 console=ttyMSM0 earlycon loglevel=8 ignore_loglevel
    echo "加载 initrd..."
    initrd /initrd.img
}

menuentry "Debian Linux (恢复模式)" {
    echo "加载内核 (恢复模式)..."
    linux /Image.gz root=UUID=20336aa9-c9de-431a-b679-dcf10065c121 ro single console=tty0 console=ttyMSM0 earlycon loglevel=8
    echo "加载 initrd..."
    initrd /initrd.img
}

menuentry "UEFI Shell" {
    chainloader /EFI/BOOT/shell.efi
}
EOF

# 创建备用 grub.cfg（EFI/BOOT 目录下的后备）
sudo ln -sf ../Debian/grub.cfg "$ESP_MOUNT/EFI/BOOT/grub.cfg"

# 卸载 ESP（稍后会重新挂载拷贝内核）
sudo umount "$ESP_MOUNT"
echo "✅ ESP 镜像生成完成: $ESP_IMG"

# ============================================================
# 第二部分：生成 Rootfs 镜像 (Debian)
# ============================================================
echo "=================================================="
echo "==> 生成 Rootfs 镜像: $ROOTFS_IMG (大小: $ROOTFS_SIZE)"
dd if=/dev/zero of="$ROOTFS_IMG" bs=1G count=${ROOTFS_SIZE%G} status=progress
mkfs.ext4 -U "$MY_UUID" -F "$ROOTFS_IMG"

echo "==> 挂载 rootfs 到 $CHROOT_DIR"
sudo mkdir -p "$CHROOT_DIR"
sudo mount "$ROOTFS_IMG" "$CHROOT_DIR"

echo "==> 执行 debootstrap（从 Debian 官方源拉取 arm64 架构的 trixie）..."
sudo debootstrap --arch arm64 trixie "$CHROOT_DIR" http://deb.debian.org/debian

# -------------------- 挂载必要的虚拟文件系统 --------------------
echo "==> 挂载 /proc /dev /sys"
sudo mount --bind /proc "$CHROOT_DIR/proc"
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
sudo mount --bind /sys "$CHROOT_DIR/sys"

# -------------------- chroot 环境配置 --------------------
echo "==> 进入 chroot 执行配置脚本..."
sudo chroot "$CHROOT_DIR" /bin/bash << 'EOF'
# 配置软件源（使用中科大镜像加速）
cat > /etc/apt/sources.list << 'EOL'
deb http://mirrors.ustc.edu.cn/debian trixie main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian trixie-updates main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian trixie-backports main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian-security trixie-security main contrib non-free non-free-firmware
EOL

# 更新并安装基础包
apt update
apt upgrade -y
apt install -y man man-db bash-completion vim tmux network-manager \
    chrony openssh-server initramfs-tools locales sudo firmware-qcom-soc \
    systemd-resolved \
    grub-efi-arm64-bin grub-efi-arm64-signed \
    dosfstools efibootmgr \
    --no-install-recommends
# 设置 locale 和时区
locale-gen en_US.UTF-8 zh_CN.UTF-8
rm -f /etc/localtime
ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 设置 hostname
echo 'oneplus-7t' > /etc/hostname

# 创建用户 hol
useradd -m -s /bin/bash mmzc
usermod -aG sudo mmzc
echo "mmzc:mmzc" | chpasswd

# 配置自动扩展文件系统服务
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
# -------------------- 安装 GRUB 到 ESP --------------------
echo "==> 安装 GRUB 到 ESP 分区..."
# 注意：此时 ESP 分区应该已经挂载到 /boot/efi
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=Debian --recheck --no-floppy

# 生成 GRUB 配置文件
cat > /etc/default/grub << 'EOL'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyMSM0 earlycon loglevel=8 ignore_loglevel"
GRUB_CMDLINE_LINUX=""
EOL

update-grub

# 清理临时文件
apt clean
rm -f /tmp/*
history -c
EOF

# -------------------- 安装自定义内核 .deb 包（如果存在） --------------------
echo "==> 尝试安装预编译的内核 .deb 包..."
if ls "$WORKSPACE"/linux-*.deb 1> /dev/null 2>&1; then
    sudo cp "$WORKSPACE"/linux-*.deb "$CHROOT_DIR/tmp/"
    sudo chroot "$CHROOT_DIR" /bin/bash << 'EOF'
cd /tmp
dpkg -i linux-*.deb 2>/dev/null || true
apt --fix-broken install -y

# 生成 initrd
KERNEL_VERSION=$(ls /lib/modules/ 2>/dev/null | head -1)
if [ -n "$KERNEL_VERSION" ]; then
    echo "==> 生成 initrd for kernel $KERNEL_VERSION"
    update-initramfs -c -k $KERNEL_VERSION
fi
# 清理临时文件
rm -f /tmp/linux-*.deb
EOF
else
    echo "警告: 未找到内核 .deb 包，将在 chroot 中安装 Debian 官方内核"
    sudo chroot "$CHROOT_DIR" /bin/bash << 'EOF'
apt install -y linux-image-arm64 --no-install-recommends
KERNEL_VERSION=$(ls /lib/modules/ 2>/dev/null | head -1)
if [ -n "$KERNEL_VERSION" ]; then
    update-initramfs -c -k $KERNEL_VERSION
fi
EOF
fi

# -------------------- 拷贝 firmware（如果存在） --------------------
if [ -d "$WORKSPACE/firmware" ]; then
    echo "==> 拷贝 firmware 到 rootfs"
    sudo cp -r "$WORKSPACE/firmware/"* "$CHROOT_DIR/usr/lib/firmware/"
    sudo chroot "$CHROOT_DIR" ldconfig
else
    echo "警告: 未找到 firmware 目录，请手动准备"
fi

# -------------------- 拷贝内核和 initrd 到 ESP 镜像 --------------------
echo "==> 拷贝内核和 initrd 到 ESP 镜像..."
sudo mount "$ESP_IMG" "$ESP_MOUNT"

# 查找内核文件（兼容 vmlinuz 和 Image）
KERNEL_FILE=$(sudo ls "$CHROOT_DIR/boot"/vmlinuz-* 2>/dev/null | head -1)
if [ -z "$KERNEL_FILE" ]; then
    KERNEL_FILE=$(sudo ls "$CHROOT_DIR/boot"/Image-* 2>/dev/null | head -1)
fi
if [ -n "$KERNEL_FILE" ]; then
    sudo cp "$KERNEL_FILE" "$ESP_MOUNT/Image.gz"
    echo "✅ 内核已拷贝: $(basename $KERNEL_FILE)"
else
    echo "警告: 未找到内核文件，请检查 /boot 目录"
fi

# 查找 initrd
INITRD_FILE=$(sudo ls "$CHROOT_DIR/boot"/initrd.img-* 2>/dev/null | head -1)
if [ -n "$INITRD_FILE" ]; then
    sudo cp "$INITRD_FILE" "$ESP_MOUNT/initrd.img"
    echo "✅ initrd 已拷贝: $(basename $INITRD_FILE)"
else
    echo "警告: 未找到 initrd，请检查 /boot 目录"
fi
sudo umount "$ESP_MOUNT"
rmdir "$ESP_MOUNT" 2>/dev/null || true

# -------------------- 清理并卸载 rootfs --------------------
echo "==> 清理并卸载挂载点"
sudo umount "$CHROOT_DIR/proc" || true
sudo umount "$CHROOT_DIR/dev/pts" || true
sudo umount "$CHROOT_DIR/dev" || true
sudo umount "$CHROOT_DIR/sys" || true
sudo umount "$CHROOT_DIR" || true

# -------------------- 转换为 sparse 格式（刷机用） --------------------
echo "==> 转换为 sparse 格式..."
which img2simg >/dev/null 2>&1 || { echo "错误: img2simg 未安装"; exit 1; }
img2simg "$ROOTFS_IMG" "$WORKSPACE/rootfs.img.sparse" || {
    echo "警告: 转换 rootfs 为 sparse 失败，保留原始镜像"
    cp "$ROOTFS_IMG" "$WORKSPACE/rootfs.img.sparse"
}
img2simg "$ESP_IMG" "$WORKSPACE/esp.img.sparse" || {
    echo "警告: 转换 esp 为 sparse 失败，保留原始镜像"
    cp "$ESP_IMG" "$WORKSPACE/esp.img.sparse"
}

# -------------------- 输出信息 --------------------
echo "=================================================="
echo "✅ 镜像生成完成！"
echo ""
echo "📍 生成的文件："
echo "   - ESP 镜像 (原始): $ESP_IMG"
echo "   - ESP 镜像 (sparse): $WORKSPACE/esp.img.sparse"
echo "   - Rootfs 镜像 (原始): $ROOTFS_IMG"
echo "   - Rootfs 镜像 (sparse): $WORKSPACE/rootfs.img.sparse"
echo ""
echo "🔑 rootfs UUID: $MY_UUID"
echo ""
echo "📌 刷机命令："
echo "   fastboot flash boot $WORKSPACE/esp.img.sparse"
echo "   fastboot flash userdata $WORKSPACE/rootfs.img.sparse"
echo ""
echo "📌 或使用原始镜像（如果 sparse 不兼容）："
echo "   fastboot flash boot $ESP_IMG"
echo "   fastboot flash userdata $ROOTFS_IMG"
echo ""
echo "📌 启动后 GRUB 菜单将出现，选择 Debian Linux 启动"
echo "=================================================="

# 清理 trap 会执行
exit 0
