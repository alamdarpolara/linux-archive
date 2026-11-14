#!/usr/bin/env bash
# distros.sh - the test matrix (sourced by run_all.sh; not a deliverable).
# name|base image|install.sh arguments used to build the test image|platform
# (AlmaLinux 10 needs the separate x86_64_v2 build on CPUs without x86-64-v3;
#  Rocky Linux 10 and the official almalinux:10 image require x86-64-v3.)
# shellcheck disable=SC2034  # used by the sourcing script
DISTROS=(
    "debian12|debian:12|--yes --with-nonfree"
    "debian13|debian:13|--yes --with-nonfree"
    "ubuntu2204|ubuntu:22.04|--yes --with-nonfree"
    "ubuntu2404|ubuntu:24.04|--yes --with-nonfree"
    "ubuntu2604|ubuntu:26.04|--yes --with-nonfree"
    "fedora44|fedora:latest|--yes --with-nonfree"
    "rocky8|rockylinux/rockylinux:8|--yes --with-nonfree"
    "alma8|almalinux:8|--yes --with-nonfree"
    "rocky9|rockylinux/rockylinux:9|--yes --with-nonfree"
    "alma9|almalinux:9|--yes --with-nonfree"
    "alma10|almalinux/10-base:latest|--yes --with-nonfree|linux/amd64/v2"
    "leap16|opensuse/leap:latest|--yes --with-nonfree"
    "tumbleweed|opensuse/tumbleweed:latest|--yes --with-nonfree"
    "arch|archlinux:latest|--yes --with-nonfree"
    "alpine|alpine:latest|--yes --with-nonfree"
)
