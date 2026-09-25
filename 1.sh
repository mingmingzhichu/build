#!/bin/sh
cat >> arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdogb.dts << 'EOF'
&pm8150b_vbus {
    status = "okay";
};
&usb_1 {
    status = "okay";
    vbus-supply = <&pm8150b_vbus>;
};
&i2c5 {
    status = "okay";
    touchscreen@20 {
        compatible = "syna,rmi4-s3706b-i2c", "synaptics-s3706";
        reg = <0x20>;

        interrupt-parent = <&tlmm>;
        interrupts = <122 IRQ_TYPE_LEVEL_LOW>;

        reset-gpios = <&tlmm 54 GPIO_ACTIVE_LOW>;
        vcc_1v8-supply = <&vreg_l7a_1p8>;

        touchscreen-size-x = <1080>;
        touchscreen-size-y = <2400>;
    };
};
--- linux/arch/arm64/boot/dts/qcom/sm8150-oneplus-hotdogb.dts	2026-09-24 13:15:33.061836609 +0000
+++ qcom/sm8150-oneplus-hotdogb.dts	2026-09-25 00:52:48.102742944 +0000
@@ -7,11 +7,12 @@
 
 #include <dt-bindings/regulator/qcom,rpmh-regulator.h>
 #include <dt-bindings/gpio/gpio.h>
+#include <dt-bindings/usb/pd.h>
 #include "sm8150-oneplus-common.dtsi"
 
 / {
 	model = "OnePlus 7T";
-	compatible = "oneplus,hotdobg", "oneplus,oneplus7", "qcom,sm8150";
+	compatible = "oneplus,hotdogb", "oneplus,oneplus7", "qcom,sm8150";
 
 	aliases {
 		display0 = &framebuffer0;
@@ -62,4 +63,49 @@
 			ecc-size = <0x0>;
 		};
 	};
+};
+
+&ufs_mem_hc {
+	/delete-property/ reset-gpios;
+};
+
+&pm8150b_vbus {
+	status = "okay";
+};
+
+&pm8150b_typec {
+	vdd-pdphy-supply = <&vreg_l2a_3p1>;
+	status = "okay";
+
+	connector {
+		compatible = "usb-c-connector";
+		power-role = "dual";
+		data-role = "dual";
+		self-powered;
+
+		source-pdos = <PDO_FIXED(5000, 3000,
+					 PDO_FIXED_DUAL_ROLE |
+					 PDO_FIXED_USB_COMM |
+					 PDO_FIXED_DATA_SWAP)>;
+
+		sink-pdos = <PDO_FIXED(5000, 3000,
+					PDO_FIXED_DUAL_ROLE |
+					PDO_FIXED_USB_COMM |
+					PDO_FIXED_DATA_SWAP)>;
+
+		op-sink-microwatt = <10000000>;
+
+		ports {
+			#address-cells = <1>;
+			#size-cells = <0>;
+
+			port@0 {
+				reg = <0>;
+
+				pm8150b_role_switch_in: endpoint {
+					remote-endpoint = <&usb_1_dwc3_hs>;
+				};
+			};
+		};
	};
};
EOF