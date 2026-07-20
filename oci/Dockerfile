# Sandbox rootfs as an OCI image for Kata Containers + Firecracker.
#
# Replaces the old build-ubuntu-rootfs.sh ext4 image. Everything the old /init
# did at boot (networking, clock, /dev mounts, recovery sshd) is now handled by
# Kata's guest agent — so this image only needs: the userland tools, the bridge
# binary, and the bridge as ENTRYPOINT reading ENROLL_TOKEN from the env.
#
# Build: scripts/build-oci.sh   (wraps `docker build` with the bridge binary)

FROM ubuntu:24.04

ARG PACKAGES="iproute2 ca-certificates bash coreutils util-linux fuse3 curl wget jq unzip openssh-client socat sudo ripgrep fd-find patch gh git xvfb ffmpeg xdotool x11-utils"

ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C HOME=/root

RUN apt-get update \
 && apt-get install -y --no-install-recommends $PACKAGES \
 && ( [ -x /usr/bin/fdfind ] && ln -sf /usr/bin/fdfind /usr/local/bin/fd || true ) \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /usr/share/man/* /usr/share/doc/* /usr/share/info/*

# websocat: WebSocket client (Ubuntu apt doesn't ship it; grab the static musl binary).
RUN curl -fsSL https://github.com/vi/websocat/releases/download/v1.14.1/websocat.x86_64-unknown-linux-musl \
 -o /usr/local/bin/websocat && chmod +x /usr/local/bin/websocat

# ast-grep: AST structural search/rewrite (not in apt; ships as a zip). Complements
# ripgrep — rg for literal search, ast-grep for structural usages/patterns/codemods.
RUN curl -fsSL https://github.com/ast-grep/ast-grep/releases/download/0.44.1/app-x86_64-unknown-linux-gnu.zip \
 -o /tmp/ast-grep.zip \
 && unzip -q -o /tmp/ast-grep.zip -d /tmp/ast-grep \
 && install -m 0755 /tmp/ast-grep/ast-grep /usr/local/bin/ast-grep \
 && rm -rf /tmp/ast-grep.zip /tmp/ast-grep

# bun: runtime + package manager for npm catalog CLIs (agent-browser, tfa-vault).
RUN export BUN_INSTALL=/usr/local \
 && curl -fsSL https://bun.sh/install | bash \
 && ln -sf /usr/local/bin/bun /usr/local/bin/bunx \
 && ln -sf /usr/local/bin/bun /usr/local/bin/node

# Catalog CLIs tagged preinstallCloud (passed in as a space-separated build arg
# so the package list stays the single source of truth in tool_catalog.json).
# BUN_CACHE_BUST invalidates this layer on each rootfs rebuild so unpinned
# packages (e.g. @todoforai/cli) resolve to latest at deploy time rather than
# reusing a stale docker layer from a previous build.
ARG BUN_PREINSTALL=""
ARG BUN_CACHE_BUST=""
RUN if [ -n "$BUN_PREINSTALL" ]; then export BUN_INSTALL=/usr/local && bun add -g $BUN_PREINSTALL; fi

# agent-browser is only a CDP client — it needs a real Chrome to drive. Its own
# `install` fetches Chrome for Testing (Google's automation channel, version-
# matched to the tool) + the Linux shared-lib deps. It writes Chrome under
# ~/.agent-browser, but at runtime the manager bind-mounts a per-user home.img
# over /root (see internal/vm/manager.go) — which would SHADOW a browser baked
# at /root and force a ~380 MB re-download onto every user's disk. So relocate
# it to a system path baked into the shared rootfs and point the tool there via
# AGENT_BROWSER_EXECUTABLE_PATH, so all sessions reuse one copy. No install-dir
# flag exists, hence the install-then-move. (--with-deps shells out to sudo
# apt-get, which is why `sudo` must be in $PACKAGES above.)
ENV AGENT_BROWSER_EXECUTABLE_PATH=/opt/agent-browser/chrome/chrome
RUN if printf '%s' "$BUN_PREINSTALL" | grep -qw agent-browser; then \
      export BUN_INSTALL=/usr/local \
   && agent-browser install --with-deps \
   && CHROME_BIN="$(find /root/.agent-browser/browsers -maxdepth 2 -name chrome -type f | head -1)" \
   && test -n "$CHROME_BIN" \
   && mkdir -p /opt/agent-browser \
   && mv "$(dirname "$CHROME_BIN")" /opt/agent-browser/chrome \
   && rm -rf /root/.agent-browser \
   && test -x "$AGENT_BROWSER_EXECUTABLE_PATH" \
   && apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# The bridge binary — built/fetched by build-oci.sh and dropped next to this
# Dockerfile as `todoforai-bridge`. The entrypoint redeems ENROLL_TOKEN then
# execs the daemon (see oci/entrypoint.sh).
COPY todoforai-bridge /usr/local/bin/todoforai-bridge
COPY entrypoint.sh /usr/local/bin/sandbox-entrypoint
RUN chmod +x /usr/local/bin/todoforai-bridge /usr/local/bin/sandbox-entrypoint

# browser-manager-cli — static C binary fetched by build-oci.sh from the catalog
# release URL. Best-effort: build-oci.sh may leave a 0-byte placeholder if the
# release isn't published yet, in which case we drop it so the edge auto-installer
# fetches it lazily on first use instead of shadowing PATH with an empty file.
COPY browser-manager-cli /usr/local/bin/browser-manager-cli
RUN if [ -s /usr/local/bin/browser-manager-cli ]; then \
        chmod +x /usr/local/bin/browser-manager-cli; \
    else \
        rm -f /usr/local/bin/browser-manager-cli; \
    fi

# Slim rclone (todoforai backend only) — fetched by build-oci.sh from the
# rclone-backend release and dropped next to this Dockerfile as `rclone`. The
# guest entrypoint uses it to FUSE-mount the user's cloud workspace. Best-effort:
# build-oci.sh may leave a 0-byte placeholder if the release isn't published yet,
# in which case we drop it so the entrypoint's mount step simply no-ops.
COPY rclone /usr/local/bin/rclone
RUN if [ -s /usr/local/bin/rclone ]; then \
        chmod +x /usr/local/bin/rclone; \
    else \
        rm -f /usr/local/bin/rclone; \
    fi

# Self-classify as a sandbox device at enroll time (bridge reads this).
RUN touch /etc/todoforai-sandbox

# DNS resolvers baked into the image. The microVM has no DHCP/resolved to write
# /etc/resolv.conf, and Kata won't inject one (unlike Docker at runtime), so the
# guest would have no resolver and DNS fails (HTTPS to api.todofor.ai times
# out). Public anycast resolvers (oci/resolv.conf); swap that file if a host
# firewalls outbound DNS to its own resolvers.
COPY resolv.conf /etc/resolv.conf

WORKDIR /root
ENTRYPOINT ["/usr/local/bin/sandbox-entrypoint"]
