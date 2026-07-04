self: super:

{
  switch-to-configuration-ng = super.switch-to-configuration-ng.overrideAttrs
    (oldAttrs: {
      doCheck = false;
      patches = (oldAttrs.patches or [ ])
        ++ [ ./0001-Bypass-system-dbus.patch ];
    });
}
