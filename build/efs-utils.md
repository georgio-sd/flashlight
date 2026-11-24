<!-- Copyright 2020-2026 Samson (https://github.com/georgio-sd). SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 (see LICENSE) -->
# Building amazon-efs-utils for AlmaLinux 10

The mail server installs amazon-efs-utils from a prebuilt RPM in the public bucket,
not from source. Nothing in this file runs on the mail server. Use a temporary
EC2 instance and terminate it when you are done.

Current build: `amazon-efs-utils-3.4.0-1.el10.x86_64.rpm`, built 2026-11-23 on
AlmaLinux 10.3 with Rust 1.100.0 (rustup).
SHA-256: `42de00058d806c9a4569ca8ee2fc10f42dc974bd143e4be55734d8df566eb9f7`.
Published in `packages/` of the release folder (`s3://mail-server-bundles/vX.Y/packages/`).

## When to rebuild

- A security fix or a needed bug fix in efs-utils.
- A new AlmaLinux major version (11). Minor updates (10.x) keep working with the same RPM.

## Build host

- AMI: the current `Mailserver:img_b` image (clean AlmaLinux 10).
- At least t3a.medium (2 vCPU, 4 GB RAM) and a 20 GB disk. The Rust build takes about 18 minutes on 2 vCPU.

## Steps (as root)

```bash
# 1. Build tools from the stock repos (no Rust: the system Rust is too old, see below)
dnf install -y git rpm-build make openssl-devel gcc gcc-c++ cmake perl golang clang wget

# 2. Current Rust from rustup, installed under /root only
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o rustup-init.sh
sh rustup-init.sh -y --profile minimal --no-modify-path
export PATH=/root/.cargo/bin:$PATH

# 3. Sources of the wanted release
git clone --depth 1 --branch v3.4.0 https://github.com/aws/efs-utils
cd efs-utils
make sources

# 4. Build. On EL10 the AWS-LC FIPS part needs clang, because GCC 14 breaks it
export CC=clang CXX=clang++
export CFLAGS="-Wno-unused-command-line-argument" CXXFLAGS="-Wno-unused-command-line-argument"
B=build/rpmbuild
mkdir -p $B/{SPECS,SOURCES,BUILD,RPMS,SRPMS}
cp amazon-efs-utils.spec $B/SPECS/
cp amazon-efs-utils.tar.gz config.toml $B/SOURCES/
unset MAKEFLAGS MFLAGS MAKELEVEL
rpmbuild -ba --define "_topdir $(pwd)/$B" --define "include_vendor_tarball false" \
  $B/SPECS/amazon-efs-utils.spec --without system_rust

ls $B/RPMS/x86_64/
```

## Pitfalls we hit

- **The system Rust is too old.** AlmaLinux 10.2 ships Rust 1.92. efs-utils 3.3.5 pulls AWS SDK
  crates that need Rust 1.94.1 or newer, so `make rpm` stops within seconds with
  `rustc 1.92.0 is not supported by the following packages: aws-config@... requires rustc 1.94.1`.
  Use rustup, and don't install the `rust` or `cargo` packages next to it.
- **Don't use `make rpm-without-system-rust`.** It calls `$(MAKE) rpm-only RPM_BUILD_FLAGS="--without system_rust"`.
  The value with a space gets mangled in `MAKEFLAGS`, and after about 8 minutes the jemalloc
  build fails with `make[2]: *** No rule to make target '-j'`. Run `rpmbuild` directly, as above.

## Checks before publishing

```bash
R=build/rpmbuild/RPMS/x86_64/amazon-efs-utils-*.rpm
rpm -qpR $R | grep -v '^rpmlib('   # only base system packages, no *-devel or rust
dnf install -y ./$R                 # pulls only stunnel (and nfs-utils if missing)
mount.efs --version
sha256sum $R
```

Upload it to `s3://mail-server-bundles/vX.Y/packages/` and update the file name in `base.sh`
(`efs_rpm`) and in the `Files` list of `1-dns-preset.yaml`.
