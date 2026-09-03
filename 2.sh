#!/bin/bash
set -euo pipefail
# ============================================================
# Debian trixie arm64 内核直启版 适配一加7T(SM8150/hotdogb)
# 产物：boot.img（刷boot分区） + rootfs.img.sparse（刷userdata分区）
# ============================================================

cleanup() {
    echo -e "\n==> 执行清理/卸载..."
    set +e
    sudo umount "$CHROOT_DIR/proc"    2>/dev/null
    sudo umount "$CHROOT_DIR/dev/pts" 2>/dev/null
    sudo umount "$CHROOT_DIR/dev"     2>/dev/null
    sudo umount "$CHROOT_DIR/sys"     2>/dev/null
    sudo umount "$CHROOT_DIR"         2>/dev/null
    rm -rf "$TEMP_DIR" 2>/dev/null
    set -e
    echo "✅ 清理完成"
}
trap cleanup EXIT

# -------------------- 用户配置区域 --------------------
WORKSPACE="${WORKSPACE:-$PWD}"
BOOT_IMG="$WORKSPACE/boot.img"
ROOTFS_IMG="$WORKSPACE/rootfs.img"
ROOTFS_SIZE_G=2
CHROOT_DIR="$WORKSPACE/chroot"
TEMP_DIR="$WORKSPACE/.build_temp"
ROOTFS_UUID="20336aa9-c9de-431a-b679-dcf10065c121"
USER_NAME="mmzc"
USER_PASS="mmzc"

# 内核配置（二选一即可）
# 方式1：把编译好的 linux-*.deb 放在工作目录，脚本自动安装
# 方式2：直接指定本地编译好的文件路径，优先级高于deb
KERNEL_IMAGE=""   # 本地 Image.gz 路径，例如 ~/kernel/arch/arm64/boot/Image.gz
DTB_FILE=""       # 本地 dtb 路径，例如 ~/kernel/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdogb.dtb

# boot.img 参数（SM8150平台通用）
BASE_ADDR="0x00000000"
KERNEL_OFFSET="0x00008000"
TAGS_OFFSET="0x00000100"
PAGE_SIZE="4096"
CMDLINE="root=UUID=$ROOTFS_UUID rw rootwait clk_ignore_unused pd_ignore_unused console=ttyMSM0,115200n8"

# -------------------- 安装&检查依赖 --------------------
echo "==> 安装系统依赖"
sudo apt update
sudo apt install -y qemu-user-static debootstrap dosfstools e2fsprogs \
    android-tools-ext img2simg device-tree-compiler

if ! command -v mkbootimg &>/dev/null; then
    sudo apt install -y mkbootimg || {
        echo "❌ mkbootimg 安装失败，请手动安装高通适配版"
        exit 1
    }
fi

need_cmds=(dd mkfs.ext4 debootstrap mount umount img2simg qemu-aarch64-static mkbootimg)
for cmd in "${need_cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "❌ 缺失命令: $cmd"
        exit 1
    fi
done

mkdir -p "$TEMP_DIR"

# ============================================================
# 第一部分：创建rootfs并安装基础系统
# ============================================================
echo -e "\n==> 创建 rootfs 镜像 (${ROOTFS_SIZE_G}G)"
rm -f "$ROOTFS_IMG"
dd if=/dev/zero of="$ROOTFS_IMG" bs=1G count="$ROOTFS_SIZE_G" status=progress
mkfs.ext4 -U "$ROOTFS_UUID" -F "$ROOTFS_IMG"

echo "==> 挂载 rootfs"
sudo rm -rf "$CHROOT_DIR"
sudo mkdir -p "$CHROOT_DIR"
sudo mount "$ROOTFS_IMG" "$CHROOT_DIR"
sudo cp "$(which qemu-aarch64-static)" "$CHROOT_DIR/usr/bin/"

echo -e "\n==> 执行 debootstrap"
sudo debootstrap --arch arm64 --foreign trixie "$CHROOT_DIR" http://mirrors.ustc.edu.cn/debian

# 挂载虚拟文件系统
sudo mount --bind /proc    "$CHROOT_DIR/proc"
sudo mount --bind /dev     "$CHROOT_DIR/dev"
sudo mount --bind /dev/pts "$CHROOT_DIR/dev/pts"
sudo mount --bind /sys     "$CHROOT_DIR/sys"

# ============================================================
# 第二部分：chroot 系统配置
# ============================================================
echo -e "\n==> 配置系统基础环境"
sudo chroot "$CHROOT_DIR" /bin/bash <<EOF
set -e
/debootstrap/debootstrap --second-stage

# 软件源
cat > /etc/apt/sources.list <<'EOL'
deb http://mirrors.ustc.edu.cn/debian trixie main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian trixie-updates main contrib non-free non-free-firmware
deb http://mirrors.ustc.edu.cn/debian-security trixie-security main contrib non-free non-free-firmware
EOL

apt update
apt upgrade -y
apt install -y bash-completion vim tmux network-manager chrony openssh-server \
    initramfs-tools locales locales-all sudo systemd-resolved dosfstools e2fsprogs \
    firmware-misc-nonfree systemd-growfs

# 基础配置
locale-gen en_US.UTF-8 zh_CN.UTF-8
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
echo 'Asia/Shanghai' > /etc/timezone
echo 'oneplus-7t' > /etc/hostname
echo '127.0.1.1 oneplus-7t' >> /etc/hosts

# 用户
useradd -m -s /bin/bash ${USER_NAME}
usermod -aG sudo ${USER_NAME}
echo "${USER_NAME}:${USER_PASS}" | chpasswd

# fstab
cat > /etc/fstab <<FSTAB
UUID=${ROOTFS_UUID}  /       ext4    errors=remount-ro   0   1
tmpfs                /tmp    tmpfs   defaults            0   0
FSTAB

# 开机自动扩容
systemctl enable systemd-growfs@-.service
EOF

# ============================================================
# 第三部分：安装内核
# ============================================================
echo -e "\n==> 安装内核"
if [ -n "$KERNEL_IMAGE" ] && [ -n "$DTB_FILE" ]; then
    echo "→ 使用本地指定内核文件"
    cp "$KERNEL_IMAGE" "$TEMP_DIR/kernel.gz"
    cp "$DTB_FILE" "$TEMP_DIR/dtb"
    KERNEL_VER="custom"
else
    # 优先用工作目录的deb包
    if compgen -G "${WORKSPACE}/linux-*.deb" > /dev/null; then
        echo "→ 安装本地内核deb包"
        sudo cp ${WORKSPACE}/linux-*.deb "$CHROOT_DIR/tmp/"
        sudo chroot "$CHROOT_DIR" /bin/bash <<'INNER'
cd /tmp
dpkg -i linux-*.deb || apt -y --fix-broken install
rm -f linux-*.deb
INNER
    else
        echo "→ 安装Debian官方内核（注意：官方内核不含SM8150专用DTB）"
        sudo chroot "$CHROOT_DIR" apt install -y linux-image-arm64 --no-install-recommends
    fi

    # 提取内核版本和文件
    KERNEL_VER=$(sudo chroot "$CHROOT_DIR" ls /lib/modules/ | head -1)
    echo "→ 内核版本: $KERNEL_VER"
    sudo cp "$CHROOT_DIR/boot/vmlinuz-$KERNEL_VER" "$TEMP_DIR/kernel.gz"
    
    DTB_PATH="$CHROOT_DIR/usr/lib/linux-image-$KERNEL_VER/qcom/sm8150-oneplus-hotdogb.dtb"
    if [ -f "$DTB_PATH" ]; then
        sudo cp "$DTB_PATH" "$TEMP_DIR/dtb"
    else
        echo "❌ 未找到一加7T对应的DTB文件，请指定本地DTB路径"
        exit 1
    fi
fi

# 生成initrd
echo "==> 生成 initrd"
sudo chroot "$CHROOT_DIR" update-initramfs -c -k "$KERNEL_VER"
sudo cp "$CHROOT_DIR/boot/initrd.img-$KERNEL_VER" "$TEMP_DIR/initrd.img"

# ============================================================
# 第四部分：打包 boot.img
# ============================================================
echo -e "\n==> 打包 boot.img"
# 拼接内核+DTB（高通ABL标准格式）
cat "$TEMP_DIR/kernel.gz" "$TEMP_DIR/dtb" > "$TEMP_DIR/kernel_blob"

mkbootimg \
    --kernel "$TEMP_DIR/kernel_blob" \
    --ramdisk "$TEMP_DIR/initrd.img" \
    --base "$BASE_ADDR" \
    --kernel_offset "$KERNEL_OFFSET" \
    --tags_offset "$TAGS_OFFSET" \
    --pagesize "$PAGE_SIZE" \
    --cmdline "$CMDLINE" \
    -o "$BOOT_IMG"

# ============================================================
# 第五部分：输出产物
# ============================================================
echo -e "\n==> 转换 rootfs 为 sparse 格式"
img2simg "$ROOTFS_IMG" "${WORKSPACE}/rootfs.img.sparse"

echo "============================================="
echo "🎉 构建完成！"
echo ""
echo "📦 输出文件："
echo "   - boot.img          刷入 boot_a / boot_b 分区"
echo "   - rootfs.img.sparse 刷入 userdata 分区"
echo ""
echo "🔑 rootfs UUID: $ROOTFS_UUID"
echo ""
echo "📱 刷机命令（务必先备份原厂分区！）："
echo "   1. 关闭vbmeta校验（必须）"
echo "      fastboot --disable-verity flash vbmeta_a vbmeta.img"
echo "   2. 刷入系统"
echo "      fastboot flash boot_a boot.img"
echo "      fastboot flash userdata rootfs.img.sparse"
echo "   3. 切换到A分区启动"
echo "      fastboot set_active a"
echo ""
echo "⚠️  注意：首次开机会自动扩容rootfs到整个userdata分区"
echo "============================================="

exit 0
