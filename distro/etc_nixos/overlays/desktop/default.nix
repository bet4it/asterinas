self: super:

{
  xorg-server = super.xorg-server.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ])
      ++ [ ./patches/xorgServer/0001-Skip-checking-graphics-under-sys.patch ];
    # Asterinas does not yet provide a functional sysfs or udev.
    buildInputs = (oldAttrs.buildInputs or [ ]) ++ [ self.libudev-zero ];
    mesonFlags = self.lib.filter
      (flag: flag != "-Dxkb_output_dir=$out/share/X11/xkb/compiled")
      (oldAttrs.mesonFlags or [ ]) ++ [
        "-Dglamor=true"
        "-Dxkb_output_dir=$out/share/X11/xkb"
        "-Doptimization=0"
        "-Dudev=false"
        "-Dudev_kms=false"
      ];
    postInstall = (oldAttrs.postInstall or "") + ''
      mkdir -p $out/share/X11/xorg.conf.d
      cp ${
        ./patches/xorgServer/10-fbdev.conf
      } $out/share/X11/xorg.conf.d/10-fbdev.conf
    '';
  });

  xorg = super.xorg // { xorgserver = self.xorg-server; };

  xfwm4 = super.xfwm4;

  xfdesktop = super.xfdesktop.overrideAttrs (oldAttrs: {
    patches = (oldAttrs.patches or [ ]) ++ [
      ./patches/xfdesktop4/0001-Fix-not-using-consistent-monitor-identifiers.patch
    ];
  });

  xfce = super.xfce // {
    xfwm4 = self.xfwm4;
    xfdesktop = self.xfdesktop;
  };
}
