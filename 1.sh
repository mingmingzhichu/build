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
EOF