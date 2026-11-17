ARG BASE=fedora:44
FROM ${BASE}

COPY .zig-version /usr/local/src/mdf/.zig-version
COPY tools/scripts/install-packages.sh tools/scripts/fetch-zig.py /usr/local/src/mdf/tools/scripts/
COPY tools/container/provision.sh /usr/local/src/mdf/tools/container/
RUN sh /usr/local/src/mdf/tools/container/provision.sh

# Builds write into the bind-mounted checkout, so they run as the caller's uid and gid.
ARG MDF_UID=1000
ARG MDF_GID=1000
RUN getent group "$MDF_GID" >/dev/null || groupadd --gid "$MDF_GID" mdf; \
    getent passwd "$MDF_UID" >/dev/null || useradd --create-home --uid "$MDF_UID" --gid "$MDF_GID" mdf
USER ${MDF_UID}:${MDF_GID}
