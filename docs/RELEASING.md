<!-- Copyright 2020-2026 Samson (https://github.com/georgio-sd). SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 (see LICENSE) -->
# Releasing Flashlight

This guide is for Flashlight developers. It describes how a release is put together and published, and the
rules a change must follow so that existing servers can upgrade to it. The user's side of an upgrade is in
[UPGRADING.md](UPGRADING.md).

## What a release is

A release `X.Y` consists of:

- the templates `1-dns-preset.yaml`, `2-deployment.yaml` and `x-maintenance.yaml` from the repository;
- the installer files from `s3bucket/`, published in the public bucket `flashlight-mail-server` (us-west-2)
  under `vX.Y/` with the same folder layout (`system/base.sh`, `postfix/main.cf`, `packages/...`).

Stage 1 copies the files listed in its `Files` property from `BaseUrl` into the stack's config bucket. The
config bucket is flat: each file is stored by its name only, so file names must be unique across all folders.
Instances read their files from the config bucket only, never from the public bucket.

A published release folder is never changed. Users' stacks point to it, and stage 1 copies it again on later
updates (a changed domain list, the `Updater` switch). A fix is a new release.

### The server image

The instances start from a Flashlight image (AMI) owned by account 112904279782 in us-west-2, with the description
`Mailserver:img_b`. It is not part of a release folder: stage 1 of every release takes the newest image with that
description and copies it into the user's region. It does so when stage 1 is created, updated to a new release, or
updated with the `Updater` switch; CloudFormation doesn't run it on an update that changes nothing it is given.
A new image therefore reaches the users of all releases at their next upgrade or `Updater` switch, so it must work
with all of them. The instance updates its operating system at every install
anyway, but an image on the current AlmaLinux minor release (10.3 after 10.2) has less to update and installs
faster: a release brings a new image when AlmaLinux has a newer minor release (checklist, step 9).

Other accounts can copy the image only if both the image and the snapshot of its disk are public. A public image
alone isn't enough: the copy fails with "You do not have permission to access the storage of this ami", and so
does stage 1 in the user's account. The snapshot must not be encrypted (an encrypted snapshot can't be public).

## Rules for changes

### Files Flashlight owns

Config files, scripts and crontab jobs that Flashlight writes are rebuilt at every boot from the release. A
release can change them freely; no migration is needed. Each config still ends by including the admin's own
settings file (see the table in UPGRADING.md). Keep that include, and keep the "DON'T EDIT" header that points
the admin to it.

The admin's settings files are created once by `custom_file` in `base.sh` and never changed. A release must not
change or delete them. If a release has to change how a setting is applied, it does so in our files, so the
admin's value still wins.

### Data on EFS

Anything that lives on EFS and is not rebuilt at boot is data: databases, the `etc`, `www`, `root` and
`automation` folders, mail. A release that needs a one-off change to the data ships a migration (below).

Mail (`/mnt/mailserver/mail`) and the mail queue are never changed by a migration: they are not in the
upgrade backup.

### Secrets

`/mnt/mailserver/root/secrets` holds the generated values our configs need (database passwords, keys). `base.sh`
reads them with `secrets get`, which fails if a key is missing, and that stops the install. A release that adds a
new secret must therefore:

1. generate it for new installs in `base.sh` (`secrets set`, in the first-install part);
2. generate it for existing installs in its migration;
3. add the key to the `keys` list in `system/secrets`.

### Packages

Web application packages are pinned: the tarball is in `s3bucket/packages/`, named in the `Files` list and in
`base.sh` (`pfa_tar`, `pma_tar`, `rc_tar`, `larry_tar`). The installed package of each application is recorded
in `/mnt/mailserver/versions` (`roundcube=`, `larry=`, `postfixadmin=`, `phpmyadmin=`).

An application is installed on the first install. On existing data, every install runs
`upgrade-data app NAME PACKAGE` for each application. When the recorded package isn't the release's one, it:
1. dumps the application's database and moves its folder into `backup/upgrade-NAME-<date>/`;
2. runs the application's recipe `update_NAME` in `upgrade-data`: the new package goes into an empty folder,
   followed by the application's own upgrade steps (database schema, for example);
3. records the new package. If the recipe fails, it puts the old folder and database back, writes `FAILED` and
   stops the install.

It never installs an older package than the recorded one (`WARN`, kept). An application without a recipe stops
the install with `FAILED ... no update recipe` as soon as its package changes. The recipes exist for: PostfixAdmin, Roundcube.

To bump an application:
1. Read its release notes and upgrade notes. Compare its default config with the old one: a new setting that
   Flashlight must set goes into our config in `s3bucket/`.
2. Check the download against the checksum of the project (GitHub shows a `sha256:` digest for release files).
3. Upload the tarball to `packages/` in the public bucket, and change its name in the `Files` list and in `base.sh`.
4. Without a recipe yet, write `update_NAME` with `app_dir` and `app_db` in `upgrade-data`, from the
   application's upgrade notes. A one-off step that isn't part of every update goes into a migration instead.
5. On the stand: replace the instance on data with the old package (an `UPGRADE NAME ... now at ...` line, the
   application works), replace it once more (nothing to do), and make the recipe fail once (the old package is
   restored).

Old package files stay in the public bucket folder of the release that used them.

### OS packages

OS packages come from AlmaLinux and EPEL at install time, always the newest ones for the OS release; EPEL is
pinned to the OS minor branch. Nothing to do per release, unless a package is added or removed in `base.sh`.

## Migrations

A migration is a script `upgrade-<from>-<to>.sh` that brings the data of release `<from>` to release `<to>`,
where `<from>` is the previous release. It is needed only when the data must change; for most releases there is
none.

`upgrade-data run` executes migrations on the new instance:

- after EFS is mounted and MariaDB is running, before any other service is configured;
- with `bash -e`, so the first failing command fails the migration;
- after a backup of all databases and of the `etc`, `www`, `root` and `automation` folders;
- one after another, from the data's release to the installer's release, so a user can skip releases. A release
  step without a migration only raises the release recorded for the data.

If a migration fails, everything is restored from the backup and the install stops. A migration therefore
doesn't need its own rollback, but it must not change anything outside the backup (mail, the queue, other
AWS resources).

A migration runs once per release step and can rely on the data being exactly at `<from>`. It has
`BUCKET_CONFIG` and the other stack variables from UserData, and the helpers in `/usr/local/sbin` (`secrets`,
`instance-log`, `upgrade-data`).

Migrations live in `s3bucket/migrations/` and go into the stage 1 `Files` list. All migrations of all releases
stay in the list for good: a server several releases behind needs every step in between.

## Starting a version

Released versions are on `main`; the next version is worked on in the `develop` branch. As soon as work on `X.Y`
starts, the code names `X.Y` everywhere, so a stand installed from `develop` is an `X.Y` server:

1. In `s3bucket/system/upgrade-data`, set `this_release=X.Y` and append `X.Y` to `releases` (oldest first, every
   release listed). The flag file on EFS and the `versions` file take the number from there.
2. In `1-dns-preset.yaml`, point `BaseUrl` under `Mappings` to `.../vX.Y` (the one place it is set; DnsPreset
   gets it too, so an upgrade also takes the newest server image).
3. In `CHANGELOG.md`, open an `[Unreleased]` section for the changes of `X.Y`, with the version table under its
   first paragraph: the previous release's column and an `X.Y` column, same rows in the same order (AlmaLinux,
   Roundcube, Larry, PostfixAdmin, phpMyAdmin, Rspamd, oletools, olefy, amazon-efs-utils).
4. Create the bucket folder `vX.Y/` (the public bucket's policy already makes every `v*/` folder readable).
   Until the release it holds the work in progress and is updated from `develop`; test stands install from it.

A stand installed from `develop` marks its data as `X.Y` at its next install. If a migration to `X.Y` is added
later, the stand's data won't run it. To test it there, set the data back with
`upgrade-data set flashlight <previous>` and replace the instance, or use a stand installed from the previous
release (checklist, step 11).

## Release checklist

The release fixes what was done on `develop` and builds the bridge from the previous release.

1. **Version.** `this_release`, the last entry of `releases` and `BaseUrl` name `X.Y` (set when the work
   started, see above).
2. **Migration**, if the data change: write `s3bucket/migrations/upgrade-<previous>-X.Y.sh` and add the step
   `<previous>-X.Y` to `migrations` in `upgrade-data`. A step that isn't listed there runs no script.
   A new MariaDB release series (the first two numbers, e.g. 10.11 to 11.4, usually with a new AlmaLinux) changes
   the format of the data on EFS: the migration then runs `mariadb-upgrade`, tested on a stand with a copy of the
   previous release's data. Updates within a series (10.11.18 to 10.11.19), which every rebuild may bring, need
   nothing: the package's own start check (`mariadb-check-upgrade`) compares only the series.
3. **Files list.** Every file in `s3bucket/` that instances use is in the stage 1 `Files` list, including new
   files and all migrations. A missing file is simply absent from the config bucket and fails the install.
4. **Maintenance template.** If `2-deployment.yaml` changed, regenerate it:

   ```
   python build/make-maintenance.py 2-deployment.yaml x-maintenance.yaml
   ```

5. **Attachment lists.** Compare `s3bucket/rspamd/attachments-gmail.map` with Google's list of blocked file types
   (https://support.google.com/mail/answer/6590) and `attachments-strict.map` with Microsoft's list of attachments
   Outlook blocks; update them and the date in their headers.
6. **Rspamd package.** Instances install only the Rspamd package that comes with the release (`packages/`), never
   from Rspamd's repository: the repository keeps only its newest package, and bug-fix releases have changed what
   Flashlight relies on (4.3.0 stopped creating Rspamd's user, 4.3.1 moved the web interface settings). Keep the
   package unless a newer one fixes something that matters; to take a newer one, read its release notes
   (https://github.com/rspamd/rspamd/releases), download it from
   `https://rspamd.com/rpm-stable/centos-10/x86_64/` (compare its SHA-256 with the repository's `primary.xml`),
   check it with `rpm -K` (key `rspamd/rspamd.asc`) on an instance, upload it to `packages/`, update its name in
   `base.sh` (`rspamd_rpm`) and in the stage 1 `Files` list, and test a fresh install and an instance replacement
   with it, including the settings changed in the web interface.
   The macro check: compare `s3bucket/rspamd/olefy.py` with the newest olefy
   (https://github.com/HeinleinSupport/olefy), and regenerate `olefy-requirements.txt` from the newest oletools:
   in a Python 3.12 environment, `pip download --only-binary=:all: oletools colorclass python-magic`, then one line
   `name==version --hash=sha256:...` per downloaded file.
7. **efs-utils package.** Look at the efs-utils releases (https://github.com/aws/efs-utils/releases) newer than
   ours (`efs_rpm` in `base.sh`) and read what they change. Rebuild only for a security fix or a fix that matters
   to Flashlight (mounting, TLS, efs-proxy, the watchdog), as in [build/efs-utils.md](../build/efs-utils.md):
   upload the package to `packages/`, update its name in `base.sh` (`efs_rpm`) and in the stage 1 `Files` list,
   update the version, date and SHA-256 in build/efs-utils.md, and test a fresh install and an instance
   replacement with it.
8. **Valkey.** It comes from AlmaLinux (AppStream), unpinned, and follows it at every install; Red Hat moves it
   to a newer version within RHEL 10 now and then (8.0 to 8.1 in 2026). Compare `dnf repoquery valkey` on an
   instance with the version in the table of [ARCHITECTURE](ARCHITECTURE.md). If its minor or major version is
   newer, check on a stand with learned data that a `dump.rdb` written by the older Valkey loads after an
   instance replacement (`/var/log/valkey/valkey.log`: "DB loaded from disk", no RDB version error; the data
   are only Rspamd's learning, so a failure costs relearning, not mail), and update the version in the table.
9. **Server image.** Look up the newest official AlmaLinux image (owner `764336703387`, name
   `AlmaLinux OS 10.* x86_64`). If its minor release is newer than our image's, copy it, unencrypted, with the name
   `Flashlight ` + its full name, taken as it is (`Flashlight AlmaLinux OS 10.3.20261116.0 x86_64`: unique, and it
   tells the build it was made from) and the description `Mailserver:img_b`, and with the tags `Name` = the same name and
   `flashlight:installation` = `release` (the cost of publishing Flashlight, like the public bucket, which has the
   same tag), then make the image and the snapshot of its disk public and check both:

   ```
   aws ec2 describe-images --region us-west-2 --owners 764336703387 \
     --filters "Name=name,Values=AlmaLinux OS 10*x86_64*" --query 'reverse(sort_by(Images,&CreationDate))[:3].[ImageId,Name]'
   SRC=ami-...    # the newest one from the list above
   NAME="Flashlight $(aws ec2 describe-images --region us-west-2 --image-ids $SRC --query 'Images[0].Name' --output text)"
   aws ec2 copy-image --region us-west-2 --source-region us-west-2 --source-image-id $SRC \
     --name "$NAME" --description Mailserver:img_b --tag-specifications \
     "ResourceType=image,Tags=[{Key=Name,Value=$NAME},{Key=flashlight:installation,Value=release}]" \
     "ResourceType=snapshot,Tags=[{Key=Name,Value=$NAME},{Key=flashlight:installation,Value=release}]"
   aws ec2 modify-image-attribute --region us-west-2 --image-id ami-... --launch-permission "Add=[{Group=all}]"
   aws ec2 modify-snapshot-attribute --region us-west-2 --snapshot-id snap-... \
     --attribute createVolumePermission --operation-type add --group-names all
   aws ec2 describe-image-attribute --region us-west-2 --image-id ami-... --attribute launchPermission
   aws ec2 describe-snapshot-attribute --region us-west-2 --snapshot-id snap-... --attribute createVolumePermission
   ```

   The snapshot ID is in the image's block device mapping (`aws ec2 describe-images --image-ids ami-...`). Do this
   before the tests, so they run on the new image. The real test of the sharing is stage 1 in another AWS account:
   it copies the image and waits until the copy is available.
10. **Test a fresh install** on a test stand with `CertificateMode=staging`: install READY, mail between the
   stand's own domains, webmail, admin pages, DKIM, DNS records.
11. **Test the upgrade** on a stand installed from the previous release, following UPGRADING.md step by step:
   `UPGRADE` lines in the event log, `flashlight=X.Y` in `versions`, the admin's settings files unchanged, mail
   still there. If the release has a migration, also test a release skip (from two releases back) if one exists,
   and a failing migration. A failing migration is tested on the instance with `MIGRATIONS_DIR`, `RELEASES` and
   `THIS_RELEASE`, which `upgrade-data` reads instead of its built-in values.
12. **Publish the files.** Upload `s3bucket/` to `s3://flashlight-mail-server/vX.Y/` once more, keeping the layout,
   so the folder matches the release, and check that every path of the `Files` list is there. From now on the
   folder is frozen.
13. **Publish the code.** In `CHANGELOG.md`, turn `[Unreleased]` into `[X.Y] - <date>` and check its version table
   against the newest server image (step 9), the `Files` list (`packages/`), `olefy-requirements.txt` and
   `olefy.py`: a version that changed is in bold. Merge into `main`, tag `vX.Y`, and write the release notes:
   what changed, whether the release changes the data, and any action the user must take. Then start the next
   version on `develop` (see above).

## Testing tips

- Use `CertificateMode=staging` on test stands: Let's Encrypt limits production certificates to a few per week
  for the same names.
- Test mail only between the stand's own domains, never with outside addresses.
- `install-finish` has a dry-run mode for its AWS actions (`DRY_RUN=1`); see its header.
