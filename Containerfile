# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx

# Three filesystem trees, copied onto / in order by build.sh:
#   base/      -> base OS + hardening
#   services/  -> the self-hosted service stack
#   optionals/ -> deploy-specific extras (e.g. static networking)
COPY files/base /base_files/
COPY files/services /services_files/
COPY files/optionals /optionals_files/
COPY --chmod=0755 files/scripts /build_files/
COPY *.pub /keys/
# Single source of truth for all user customizations (domains, email, app user,
# networking). Sourced by build.sh; tokens substituted by 00-config.sh.
COPY config.env /config.env

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
