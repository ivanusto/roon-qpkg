# Build the RoonServer QPKG inside a Docker container with QDK (qbuild).
# Output: build/RoonServer_<version>_x86_64.qpkg (+ .md5)
#
# Usage:
#   make            # build the .qpkg via the qdk-builder image
#   make builder    # (re)build the builder image only
#   make clean

BUILDER_IMAGE := roon-qpkg-builder
SRC           := $(CURDIR)

.PHONY: all builder qpkg clean

all: qpkg

builder:
	docker build -t $(BUILDER_IMAGE) .

qpkg: builder
	docker run --rm -v "$(SRC)":/src -w /src $(BUILDER_IMAGE) \
		qbuild --build-arch x86_64
	@ls -l build/*.qpkg

clean:
	rm -rf build
