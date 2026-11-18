# Test image (not a deliverable): a clean distribution, linux-archive's
# dependencies installed by the REAL install.sh, plus test-only tools.
#   docker build -f linux-archive_test/Dockerfile --build-arg BASE=debian:13 \
#                --build-arg INSTALL_ARGS="--yes --with-nonfree" -t la-test:debian13 .
ARG BASE=debian:13
FROM ${BASE}
ARG INSTALL_ARGS="--yes --with-nonfree"
# Stage 1: install the dependencies with the real install.sh and show the end of its log.
COPY install.sh /opt/la-src/install.sh
# `sh` is dash (Debian/Ubuntu), busybox ash (Alpine) or bash (others).
RUN sh /opt/la-src/install.sh ${INSTALL_ARGS} >/var/log/la-install.log 2>&1; rc=$?; \
    tail -n 45 /var/log/la-install.log; echo "install.sh exit code: $rc"; exit $rc
# Stage 2: add the tools only the tests need, and the unprivileged "tester" user.
COPY linux-archive_test/testdeps.sh /opt/la-src/testdeps.sh
RUN sh /opt/la-src/testdeps.sh
