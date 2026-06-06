# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx

# Two filesystem trees, copied onto / in order by build.sh:
#   base/     -> base OS + hardening
#   services/ -> the self-hosted service stack (includes /usr/lib/selfhosted/templates/)
#
# There is no config.env here — the image is generic and contains zero personal
# info. All deployment-specific values (domains, IPs, credentials) are injected
# at install time by the kickstart into /etc/selfhosted/config.env on the target
# system. selfhosted-configure.service reads that file at every boot and applies
# @@TOKEN@@ substitution to produce the live config files from the templates baked
# into /usr/lib/selfhosted/templates/.
COPY files/base /base_files/
COPY files/services /services_files/
COPY --chmod=0755 files/scripts /build_files/

# Base Image
FROM quay.io/almalinuxorg/almalinux-bootc:10@sha256:d610236e77654d012253d16814c1d30f029d3dc4ce1b7c4778ab46a6eed216b5

ARG IMAGE_NAME
ARG IMAGE_REGISTRY
ARG VARIANT

RUN --mount=type=tmpfs,dst=/opt \
    --mount=type=tmpfs,dst=/tmp \
    --mount=type=bind,from=ctx,source=/,target=/ctx \
    /ctx/build_files/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
