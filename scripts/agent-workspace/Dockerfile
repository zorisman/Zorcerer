# Zorcerer isolated development image.
#
# Toolchain: Debian 13 (trixie), Zig 0.16.0, LLVM/Clang 21, OpenCode.
#
# The repository is intentionally not baked into the image. Mount it at
# /workspace so edits and build artifacts stay on the host:
#
#   docker build \
#       --build-arg USER_UID="$(id -u)" \
#       --build-arg USER_GID="$(id -g)" \
#       -t zorcerer-dev .
#
#   docker run --rm -it \
#       --cap-drop=ALL \
#       --security-opt=no-new-privileges \
#       -v "$PWD:/workspace" \
#       -w /workspace \
#       zorcerer-dev
#
# Append `opencode` to the run command to start OpenCode instead of bash.
#
# Do not add --privileged, --user 0, or a bind mount of
# /var/run/docker.sock. The image has no sudo and no Docker client; its
# entrypoint refuses to start as root or with a Docker socket mounted.
#
# Root is used only while building the image to install packages. The
# runtime user is the unprivileged "dev" account created below.
#
# build.zig invokes unversioned `llvm-config` and `clang++`, so those names
# are symlinked to the LLVM 21 tools below.
#
# The Zig stage downloads the x86_64-linux build, matching build.zig's
# default target. Build with --platform=linux/amd64 on other hosts.

ARG ZIG_VERSION=0.16.0

# ---------------------------------------------------------------------------
# Zig 0.16.0, downloaded from ziglang.org and verified against index.json.
# ---------------------------------------------------------------------------
FROM debian:13-slim AS zig

ARG ZIG_VERSION

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        python3 \
        xz-utils; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    curl -fsSL https://ziglang.org/download/index.json -o /tmp/index.json; \
    url="$(python3 -c 'import json, sys; print(json.load(open("/tmp/index.json"))[sys.argv[1]]["x86_64-linux"]["tarball"])' "${ZIG_VERSION}")"; \
    sha="$(python3 -c 'import json, sys; print(json.load(open("/tmp/index.json"))[sys.argv[1]]["x86_64-linux"]["shasum"])' "${ZIG_VERSION}")"; \
    test -n "$url"; \
    test -n "$sha"; \
    curl -fsSL "$url" -o /tmp/zig.tar.xz; \
    echo "$sha  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm -f /tmp/index.json /tmp/zig.tar.xz; \
    /opt/zig/zig version

# ---------------------------------------------------------------------------
# OpenCode, installed by its official installer into /opt/opencode. Only the
# resulting binary is copied into the runtime image. The installer tracks the
# latest OpenCode release at image build time.
# ---------------------------------------------------------------------------
FROM debian:13-slim AS opencode

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        unzip; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    curl -fsSL https://opencode.ai/install -o /tmp/opencode-install.sh; \
    OPENCODE_INSTALL_DIR=/opt/opencode bash /tmp/opencode-install.sh; \
    if [ ! -x /opt/opencode/opencode ]; then \
        found="$(command -v opencode || true)"; \
        if [ -z "$found" ]; then \
            found="$(find /root /opt /usr/local -type f -name opencode -perm /111 2>/dev/null | head -n 1)"; \
        fi; \
        test -n "$found"; \
        install -Dm0755 "$found" /opt/opencode/opencode; \
    fi; \
    HOME=/tmp /opt/opencode/opencode --version; \
    rm -rf /root/.opencode /tmp/opencode-install.sh

# ---------------------------------------------------------------------------
# Runtime image: Debian 13, LLVM/Clang 21 development packages, Zig 0.16.0,
# OpenCode, and an unprivileged development user.
# ---------------------------------------------------------------------------
FROM debian:13-slim AS runtime

ARG USER_UID=1000
ARG USER_GID=1000
ARG ZIG_VERSION

COPY --from=zig /opt/zig /opt/zig
COPY --from=opencode /opt/opencode/opencode /usr/local/bin/opencode

RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    test "${USER_UID}" -ne 0; \
    test "${USER_GID}" -ne 0; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        g++ \
        git \
        libc6-dev; \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key -o /etc/apt/keyrings/llvm.asc; \
    echo "deb [signed-by=/etc/apt/keyrings/llvm.asc] https://apt.llvm.org/trixie/ llvm-toolchain-trixie-21 main" > /etc/apt/sources.list.d/llvm.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        clang-21 \
        libclang-21-dev \
        libclang-cpp21 \
        libllvm21 \
        llvm-21 \
        llvm-21-dev; \
    if [ ! -e /usr/lib/llvm-21/lib/libclang-cpp.so ]; then \
        libclang_cpp="$(find /usr/lib/llvm-21/lib -maxdepth 1 -name 'libclang-cpp.so.*' | sort | head -n 1)"; \
        test -n "$libclang_cpp"; \
        ln -s "$libclang_cpp" /usr/lib/llvm-21/lib/libclang-cpp.so; \
    fi; \
    llvm_config="$(command -v llvm-config-21 || true)"; \
    if [ -z "$llvm_config" ]; then llvm_config=/usr/lib/llvm-21/bin/llvm-config; fi; \
    llvm_config="$(readlink -f "$llvm_config")"; \
    test -x "$llvm_config"; \
    ln -sf "$llvm_config" /usr/local/bin/llvm-config; \
    clang_cxx="$(command -v clang++-21 || true)"; \
    if [ -z "$clang_cxx" ]; then clang_cxx=/usr/lib/llvm-21/bin/clang++; fi; \
    clang_cxx="$(readlink -f "$clang_cxx")"; \
    test -x "$clang_cxx"; \
    ln -sf "$clang_cxx" /usr/local/bin/clang++; \
    ln -sf /opt/zig/zig /usr/local/bin/zig; \
    chmod 0755 /usr/local/bin/opencode; \
    if getent group "${USER_GID}" >/dev/null; then \
        groupadd --non-unique --gid "${USER_GID}" dev; \
    else \
        groupadd --gid "${USER_GID}" dev; \
    fi; \
    if getent passwd "${USER_UID}" >/dev/null; then \
        useradd --non-unique --uid "${USER_UID}" --gid dev --create-home --shell /bin/bash dev; \
    else \
        useradd --uid "${USER_UID}" --gid dev --create-home --shell /bin/bash dev; \
    fi; \
    install -d -o dev -g dev /workspace; \
    install -d -o dev -g dev \
        /home/dev/.cache \
        /home/dev/.config \
        /home/dev/.local \
        /home/dev/.local/share \
        /home/dev/.local/state; \
    printf '%s\n' \
        '#!/bin/sh' \
        'set -eu' \
        'if [ "$(id -u)" -eq 0 ]; then' \
        '    echo "zorcerer-dev: refusing to run as root" >&2' \
        '    exit 1' \
        'fi' \
        'for socket in /var/run/docker.sock /run/docker.sock; do' \
        '    if [ -S "$socket" ]; then' \
        '        echo "zorcerer-dev: refusing to run with a Docker socket mounted ($socket)" >&2' \
        '        exit 1' \
        '    fi' \
        'done' \
        'exec "$@"' \
        > /usr/local/bin/docker-entrypoint.sh; \
    chmod 0755 /usr/local/bin/docker-entrypoint.sh; \
    apt-get purge -y curl; \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

ENV HOME=/home/dev
ENV USER=dev
ENV SHELL=/bin/bash
ENV TERM=xterm-256color
ENV LANG=C.UTF-8
ENV ZIG_GLOBAL_CACHE_DIR=/home/dev/.cache/zig

WORKDIR /workspace
USER dev

RUN set -eux; \
    test "$(zig version)" = "${ZIG_VERSION}"; \
    test "$(llvm-config --version | cut -d. -f1)" = "21"; \
    clang++ --version; \
    opencode --version

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["bash"]
