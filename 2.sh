#!/bin/bash
# ============================================================
# 功能：生成两个独立镜像：esp.img (GRUB) + rootfs.img (Debian)
# 版本：修正版 v3 - 在 chroot 内真正安装 GRUB
# ============================================================

set -e

# -------------------- 清理函数 --------------------
cleanup() {
    echo "==> 执行清理..."
    sudo umount "$ESP_MOUNT" 2>/dev/null || true
    sudo umount "$CHROOT_DIR/boot/efi" 2>/dev/null || true
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

# ============================================================
# 第一部分：创建并格式化镜像文件（不复制 GRUB）
# ============================================================
echo "=================================================="
echo "==> 生成 ESP 镜像: $ESP_IMG (大小: $ESP_SIZE)"
dd if=/dev/zero of="$ESP_IMG" bs=1M count=256 status=progress
mkfs.vfat -F 32 -n EFI "$ESP_IMG"

echo "=================================================="
echo "==> 生成 Rootfs 镜像: $ROOTFS_IMG (大小: $ROOTFS_SIZE)"
dd if=/dev/zero of="$ROOTFS_IMG" bs=1G count=${ROOTFS_SIZE%G} status=progress
mkfs.ext4 -U "$MY_UUID" -F "$ROOTFS_IMG"

# ============================================================
# 第二部分：挂载并安装系统
# ============================================================
echo "==> 挂载 rootfs 到 $CHROOT_DIR"
sudo mkdir -p "$CHROOT_DIR"
sudo mount "$ROOTFS_IMG" "$CHROOT_DIR"

echo "==> 挂载 ESP 到 $CHROOT_DIR/boot/efi（用于 chroot 内安装 GRUB）"
sudo mkdir -p "$CHROOT_DIR/boot/efi"
sudo mount "$ESP_IMG" "$CHROOT_DIR/boot/efi"

echo "==> 执行 debootstrap（从 Debian 官方源拉取 arm64 架构的 trixie）..."
sudo debootstrap --arch arm64 trixie "$CHROOT_DIR" http://deb.debian.org/debian

# -------------------- 挂载必要的虚拟文件系统 --------------------
echo "==> 挂载 /proc /dev /sys"
sudo mount --bind /proc "$CHROOT_DIR/proc"
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
sudo mount --bind /sys "$CHROOT_DIR/sys"

# -------------------- chroot 环境配置（含 GRUB 安装） --------------------
echo "==> 进入 chroot 执行配置脚本..."
sudo chroot "$CHROOT_DIR" /bin/bash << 'EOF'
# 配置软件源（使用中科大镜像加速）
cat > /etc/apt/sources.list << 'EOL'
deb http://mirrors.ustc.edu.cn/debian trixie main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian trixie-updates main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian trixie-backports main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian-security trixie-security main contrib non-free non-free-firmware
EOL

# 更新并安装基础包（包含 GRUB UEFI 包）
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

# ============================================================
# 在 chroot 内真正安装 GRUB 到 ESP
# ============================================================
echo "==> 安装 GRUB 到 /boot/efi..."
grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=Debian --recheck --no-floppy

# 生成 GRUB 配置文件
cat > /etc/default/grub << 'EOL'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR=`lsb_release -i -s 2> /dev/null || echo Debian`
GRUB_CMDLINE_LINUX_DEFAULT="console=tty0 console=ttyMSM0 earlycon loglevel=8 ignore_loglevel"
GRUB_CMDLINE_LINUX=""
EOL

# 更新 GRUB 配置
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
# 更新 GRUB 以识别新内核
update-grub
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
update-grub
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

# ============================================================
# 清理并卸载（trap 会自动处理）
# ============================================================
echo "==> 清理并卸载挂载点..."
# trap 中的 cleanup 函数会在脚本退出时自动执行

# ============================================================
# 转换为 sparse 格式（刷机用）
# ============================================================
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
echo "📌 GRUB 已安装在 ESP 中，启动后应显示 GRUB 菜单"
echo "=================================================="

exit 0
