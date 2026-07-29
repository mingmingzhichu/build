#!/bin/bash
# ============================================================
# 功能：打包 boot.img（适用于一加 7T / SM8150）
# 依赖：已运行 2.sh 生成 rootfs 和 initrd
# ============================================================

set -e

# -------------------- 配置区域 --------------------
# 如果是在 Codespaces 中，WORKSPACE 可能是 $PWD，根据实际情况调整
: "${WORKSPACE:=~/workspaces}"   # 默认 ~/workspaces，可通过环境变量覆盖
KERNEL_DIR="$WORKSPACE/linux"
ROOTFS_IMG="$WORKSPACE/rootfs-debian.img"   # 2.sh 生成的 rootfs
TMP_DIR="$WORKSPACE/tmp_mkboot"
CHROOT_DIR="$WORKSPACE/chroot"

# -------------------- 1. 准备工作目录 --------------------
echo "==> 准备打包目录 $TMP_DIR"
mkdir -p "$TMP_DIR"
rm -rf "$TMP_DIR"/*

# -------------------- 2. 拷贝内核镜像和设备树 --------------------
echo "==> 拷贝内核和 dtb..."
# 注意：这里使用 sm8150-oneplus-hotdogb.dtb（一加7T）
# 如果你编译的是其他设备，请修改文件名
cp "$KERNEL_DIR/arch/arm64/boot/Image.gz" "$TMP_DIR/"
cp "$KERNEL_DIR/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdogb.dtb" "$TMP_DIR/dtb"

# -------------------- 3. 合并内核 + dtb --------------------
echo "==> 合并 Image.gz 和 dtb 为 kernel-dtb..."
cat "$TMP_DIR/Image.gz" "$TMP_DIR/dtb" > "$TMP_DIR/kernel-dtb"

# -------------------- 4. 拷贝 initrd（从 chroot 中获取） --------------------
echo "==> 拷贝 initrd.img..."
INITRD_FILE=$(ls "$CHROOT_DIR/boot"/initrd.img-* 2>/dev/null | head -1)
if [ -z "$INITRD_FILE" ]; then
    echo "错误: 未找到 initrd.img，请确保 2.sh 成功执行并生成了 initrd"
    exit 1
fi
cp "$INITRD_FILE" "$TMP_DIR/initrd.img"
echo "   使用 initrd: $INITRD_FILE"

# -------------------- 5. 获取 rootfs 的 UUID --------------------
echo "==> 获取 rootfs 的 UUID..."
UUID=$(sudo blkid -s UUID -o value "$ROOTFS_IMG")
if [ -z "$UUID" ]; then
    echo "错误: 无法获取 $ROOTFS_IMG 的 UUID"
    exit 1
fi
echo "   UUID: $UUID"

# -------------------- 6. 打包 boot.img --------------------
echo "==> 使用 mkbootimg 打包..."
mkbootimg --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 \
    --pagesize 4096 \
    --second_offset 0x00f00000 \
    --ramdisk "$TMP_DIR/initrd.img" \
    --cmdline "console=tty0 root=UUID=$UUID rw loglevel=3 splash" \
    --kernel "$TMP_DIR/kernel-dtb" \
    -o "$TMP_DIR/boot.img"

# -------------------- 7. 输出信息 --------------------
echo "=================================================="
echo "✅ boot.img 生成完成！"
echo "📍 位置: $TMP_DIR/boot.img"
echo "🔑 使用的 UUID: $UUID"
echo "📌 刷机命令: fastboot flash boot $TMP_DIR/boot.img"
echo "=================================================="