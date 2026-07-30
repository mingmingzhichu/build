#!/bin/bash
# ============================================================
# 功能：创建指定 UUID 的 Debian 12 (Bookworm) rootfs.img
# ============================================================

set -e

# -------------------- 用户配置区域 --------------------
ROOTFS_IMG="$WORKSPACE/rootfs-debian.img"
ROOTFS_SIZE="2G"                # 镜像大小
CHROOT_DIR="$WORKSPACE/chroot"
MY_UUID="20336aa9-c9de-431a-b679-dcf10065c121"   # 自定义UUID

# -------------------- 0. 检查依赖 --------------------
echo "==> 检查必要命令..."
for cmd in dd mkfs.ext4 debootstrap mount umount img2simg; do
    if ! command -v $cmd &> /dev/null; then
        echo "错误: 未找到 $cmd，请先安装对应软件包"
        exit 1
    fi
done

# -------------------- 1. 创建空白镜像并指定 UUID --------------------
echo "==> 创建空白镜像并指定 UUID: $MY_UUID"
dd if=/dev/zero of="$ROOTFS_IMG" bs=1G count=${ROOTFS_SIZE%G} status=progress
mkfs.ext4 -U "$MY_UUID" -F "$ROOTFS_IMG"

# -------------------- 2. 挂载镜像并 debootstrap（Debian Bookworm） --------------------
echo "==> 挂载镜像到 $CHROOT_DIR"
sudo mkdir -p "$CHROOT_DIR"
sudo mount "$ROOTFS_IMG" "$CHROOT_DIR"

echo "==> 执行 debootstrap（从 Debian 官方源拉取 arm64 架构的 bookworm）..."
sudo debootstrap --arch arm64 trixie "$CHROOT_DIR" http://deb.debian.org/debian

# -------------------- 3. 挂载必要的虚拟文件系统 --------------------
echo "==> 挂载 /proc /dev /sys"
sudo mount --bind /proc "$CHROOT_DIR/proc"
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
sudo mount --bind /sys "$CHROOT_DIR/sys"

# -------------------- 4. chroot 环境配置 --------------------
echo "==> 进入 chroot 执行配置脚本..."
sudo chroot "$CHROOT_DIR" /bin/bash << 'EOF'
# 4.1 替换为国内源（可选，这里使用中科大镜像加速）
cat > /etc/apt/sources.list << 'EOL'
deb http://mirrors.ustc.edu.cn/debian bookworm main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian bookworm-updates main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian bookworm-backports main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian-security bookworm-security main contrib non-free non-free-firmware
EOL

# 4.2 更新并安装基础包
apt update
apt upgrade -y
apt install -y man man-db bash-completion vim tmux network-manager \
    chrony openssh-server initramfs-tools locales sudo --no-install-recommends

# 4.3 设置 locale 和时区
locale-gen en_US.UTF-8 zh_CN.UTF-8
rm -f /etc/localtime
ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 4.4 设置 hostname
echo 'xiaomi-mido' > /etc/hostname

# 4.5 创建用户 hol 并加入 sudo 组
useradd -m -s /bin/bash hol
usermod -aG sudo hol
echo "hol:hol" | chpasswd

# 4.6 （Debian 无 netplan，跳过卸载）

# 4.7 配置自动扩展文件系统服务
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

# 4.8 开启串口登录（ttyGS0）
cat > /etc/systemd/system/serial-getty@ttyGS0.service << 'EOL'
[Unit]
Description=Serial Console Service on ttyGS0

[Service]
ExecStart=-/usr/sbin/agetty -L 115200 ttyGS0 xterm+256color
Type=idle
Restart=always
RestartSec=0

[Install]
WantedBy=multi-user.target
EOL
systemctl enable serial-getty@ttyGS0.service
echo g_serial >> /etc/modules

# 4.9 清理临时文件
apt clean
rm -f /tmp/*
history -c
EOF

# -------------------- 5. 安装内核 .deb 包（如果存在） --------------------
echo "==> 尝试安装预编译的内核 .deb 包..."
if ls "$WORKSPACE"/linux-*.deb 1> /dev/null 2>&1; then
    sudo cp "$WORKSPACE"/linux-*.deb "$CHROOT_DIR/tmp/"
    sudo chroot "$CHROOT_DIR" /bin/bash << 'EOF'
cd /tmp
dpkg -i linux-*.deb || true
apt --fix-broken install -y

# 手动生成 initrd（确保 initramfs-tools 已安装）
apt install -y initramfs-tools kmod  # 确保这两个包存在
KERNEL_VERSION=$(ls /lib/modules/ | head -1)
if [ -n "$KERNEL_VERSION" ]; then
    echo "==> 生成 initrd for kernel $KERNEL_VERSION"
    update-initramfs -c -k $KERNEL_VERSION
fi
EOF
else
    echo "警告: 未找到内核 .deb 包，请编译后手动安装。"
fi
# -------------------- 6. 拷贝 firmware（如果存在） --------------------
if [ -d "$WORKSPACE/firmware" ]; then
    echo "==> 拷贝 firmware 到 rootfs"
    sudo cp -r "$WORKSPACE/firmware/"* "$CHROOT_DIR/usr/lib/firmware/"
    sudo chroot "$CHROOT_DIR" ldconfig
else
    echo "警告: 未找到 firmware 目录，请手动准备。"
fi
# -------------------- 6.5 拷贝 initrd 到持久目录 --------------------
echo "==> 拷贝 initrd 到 tmp_mkboot..."
mkdir -p "$WORKSPACE/tmp_mkboot"
INITRD_FILE=$(sudo ls "$CHROOT_DIR/boot"/initrd.img-* 2>/dev/null | head -1)
if [ -n "$INITRD_FILE" ]; then
    sudo cp "$INITRD_FILE" "$WORKSPACE/tmp_mkboot/initrd.img"
    sudo chown $USER:$USER "$WORKSPACE/tmp_mkboot/initrd.img"   # 修正权限
    echo "✅ initrd 已拷贝: $WORKSPACE/tmp_mkboot/initrd.img"
else
    echo "警告: 未找到 initrd"
fi
# -------------------- 7. 清理并卸载 --------------------
echo "==> 清理并卸载挂载点"
sudo umount "$CHROOT_DIR/proc" || true
sudo umount "$CHROOT_DIR/dev/pts" || true
sudo umount "$CHROOT_DIR/dev" || true
sudo umount "$CHROOT_DIR/sys" || true
sudo umount "$CHROOT_DIR" || true

# -------------------- 8. 转换为 sparse 格式（刷机用） --------------------
echo "==> 转换为 sparse 格式"
mkdir -p "$WORKSPACE/tmp_mkboot"
img2simg "$ROOTFS_IMG" "$WORKSPACE/tmp_mkboot/rootfs.img"

# -------------------- 输出信息 --------------------
echo "=================================================="
echo "✅ Debian rootfs.img 生成完成！"
echo "📍 镜像位置: $WORKSPACE/tmp_mkboot/rootfs.img"
echo "🔑 文件系统 UUID: $MY_UUID"
echo "📌 请将以下 UUID 填入 mkbootimg 的 cmdline:"
echo "   root=UUID=$MY_UUID"
echo "=================================================="