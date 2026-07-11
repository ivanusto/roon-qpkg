# Builder image for the RoonServer QPKG.
# Installs QNAP QDK (qbuild) on Ubuntu; the package itself is
# architecture-independent shell + HTML, so no cross toolchain is needed.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates make rsync xz-utils curl dos2unix \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/qnap-dev/QDK.git /tmp/QDK \
    && cd /tmp/QDK \
    && ./InstallToUbuntu.sh install \
    && rm -rf /tmp/QDK

ENV PATH="/usr/share/QDK/bin:${PATH}"

WORKDIR /src
CMD ["qbuild", "--build-arch", "x86_64"]
