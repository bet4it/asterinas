final: prev: {
  runc =
    prev.runc.overrideAttrs (oldAttrs: { patches = oldAttrs.patches or [ ]; });
  podman = (prev.podman.overrideAttrs
    (oldAttrs: { patches = oldAttrs.patches or [ ]; })).override {
      runc = final.runc;
    };
}
