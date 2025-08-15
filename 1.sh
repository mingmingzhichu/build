 # 确保系统是最新的
          cd ~
          sudo apt update

          # 安装必要的依赖
          sudo apt install -y curl axel git build-essential flex bison libssl-dev \
              libncurses5-dev libelf-dev bc python3 rsync file
          axel https://raw.githubusercontent.com/mingmingzhichu/build/refs/heads/main/AnyKernel3-master.zip

          # 安装 aarch64 和 arm32 交叉编译工具链
          sudo apt install -y gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
              gcc-arm-linux-gnueabi g++-arm-linux-gnueabi

          # 克隆内核源码和 Clang 工具链
          git clone https://github.com/yaap/kernel_oneplus_sm8150.git -b sixteen kernel --depth=1
          git clone https://gitlab.com/crdroidandroid/android_prebuilts_clang_host_linux-x86_clang-r536225 clang --depth=1

          # 设置环境变量
          export KBUILD_BUILD_USER=mmzch
          export KBUILD_BUILD_HOST=localhost
          export HOME=~/
          export CLANG_PATH=$HOME/clang/bin
          export PATH="$CLANG_PATH:$PATH"
          export CROSS_COMPILE=aarch64-linux-gnu-
          export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
          export ARCH=arm64
          export SUBARCH=arm64
          export LLVM=1
          export LLVM_IAS=1

          # 进入内核目录并应用补丁
          cd kernel
          axel https://raw.githubusercontent.com/mingmingzhichu/build/refs/heads/main/su.patch
          patch -p1 < su.patch

          # 集成 KernelSU
          curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s nongki

          # 配置内核选项（新增关闭模块签名认证配置）
          echo "CONFIG_KSU_MANUAL_HOOK=y" >> ~/kernel/arch/arm64/configs/gulch_defconfig
          echo "CONFIG_KSU=y" >> ~/kernel/arch/arm64/configs/gulch_defconfig
          # 关闭内核模块签名认证
          echo "CONFIG_MODULES=y" >> ~/kernel/arch/arm64/configs/gulch_defconfig

          echo "CONFIG_MODULE_SIG=n" >> ~/kernel/arch/arm64/configs/gulch_defconfig
          echo "CONFIG_MODULE_SIG_ALL=n" >> ~/kernel/arch/arm64/configs/gulch_defconfig
          echo "CONFIG_MODULE_SIG_SHA1=n" >> ~/kernel/arch/arm64/configs/gulch_defconfig
          echo "CONFIG_MODULE_SIG_SELF=n" >> ~/kernel/arch/arm64/configs/gulch_defconfig



          # 清理并配置内核
          make clean
          make mrproper
          make O=../out ARCH=arm64 gulch_defconfig
