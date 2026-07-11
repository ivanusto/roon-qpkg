# Builder image for the RoonServer QPKG.
# Installs QNAP QDK (qbuild) on Ubuntu; the package itself is
# architecture-independent shell + HTML, so no cross toolchain is needed.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# gcc is required: QDK's InstallToUbuntu.sh compiles qpkg_encrypt, and
# qbuild encrypts the payload with it — QTS App Center rejects an
# unencrypted .qpkg with "file format error".
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates make gcc libc6-dev rsync xz-utils curl dos2unix \
        python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/qnap-dev/QDK.git /tmp/QDK \
    && cd /tmp/QDK \
    && ./InstallToUbuntu.sh install \
    && rm -rf /tmp/QDK

ENV PATH="/usr/share/QDK/bin:${PATH}"

WORKDIR /src
CMD ["qbuild", "--build-arch", "x86_64"]
