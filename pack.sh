#!/bin/bash
# ============================================================
# 功能：打包 boot.img（适用于一加 7T / SM8150）
# 依赖：已运行 2.sh 生成 rootfs 和 initrd
# ============================================================

set -e

# -------------------- 配置区域 --------------------
: "${WORKSPACE:=~/workspaces}"   # 可通过环境变量覆盖
KERNEL_DIR="$WORKSPACE/linux"
ROOTFS_IMG="$WORKSPACE/rootfs-debian.img"
TMP_DIR="$WORKSPACE/tmp_mkboot"

# -------------------- 1. 准备工作目录 --------------------
echo "==> 准备打包目录 $TMP_DIR"
mkdir -p "$TMP_DIR"
rm -rf "$TMP_DIR"/*

# -------------------- 2. 拷贝内核镜像和设备树 --------------------
echo "==> 拷贝内核和 dtb..."
cp "$KERNEL_DIR/arch/arm64/boot/Image.gz" "$TMP_DIR/"
cp "$KERNEL_DIR/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdogb.dtb" "$TMP_DIR/dtb"

# -------------------- 3. （已去掉合并步骤）直接使用 --kernel 和 --dtb --------------------

# -------------------- 4. 检查 initrd --------------------
echo "==> 检查 initrd.img..."
if [ -f "$TMP_DIR/initrd.img" ]; then
    echo "✅ 找到 initrd.img: $(ls -lh $TMP_DIR/initrd.img)"
else
    echo "错误: 未找到 $TMP_DIR/initrd.img，请确保 2.sh 成功拷贝"
    exit 1
fi

# -------------------- 5. 获取 rootfs UUID --------------------
echo "==> 获取 rootfs 的 UUID..."
UUID=$(sudo blkid -s UUID -o value "$ROOTFS_IMG")
if [ -z "$UUID" ]; then
    echo "错误: 无法获取 $ROOTFS_IMG 的 UUID"
    exit 1
fi
echo "   UUID: $UUID"

# -------------------- 6. 打包 boot.img（使用 --dtb 参数） --------------------
echo "==> 使用 mkbootimg 打包..."
mkbootimg --base 0x00000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --tags_offset 0x00000100 \
    --pagesize 4096 \
    --second_offset 0x00f00000 \
    --ramdisk "$TMP_DIR/initrd.img" \
    --cmdline "console=tty0 root=UUID=$UUID rw loglevel=3 splash" \
    --kernel "$TMP_DIR/Image.gz" \
    --dtb "$TMP_DIR/dtb" \
    -o "$TMP_DIR/boot.img"

# -------------------- 7. 输出信息 --------------------
echo "=================================================="
echo "✅ boot.img 生成完成！"
echo "📍 位置: $TMP_DIR/boot.img"
echo "🔑 使用的 UUID: $UUID"
echo "📌 刷机命令: fastboot flash boot $TMP_DIR/boot.img"
echo "=================================================="