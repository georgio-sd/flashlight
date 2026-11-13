# Releasing Flashlight

This guide is for Flashlight developers. It describes how a release is put together and published, and the
rules a change must follow so that existing servers can upgrade to it. The user's side of an upgrade is in
[UPGRADING.md](UPGRADING.md).

## What a release is

A release `X.Y` consists of:

- the templates `1-dns-preset.yaml`, `2-deployment.yaml` and `x-maintenance.yaml` from the repository;
- the installer files from `s3bucket/`, published in the public bucket under `mail-server-bundles/vX.Y/`
  with the same folder layout (`system/base.sh`, `postfix/main.cf`, `packages/...`).

Stage 1 copies the files listed in its `Files` property from `BaseUrl` into the stack's config bucket. The
config bucket is flat: each file is stored by its name only, so file names must be unique across all folders.
Instances read their files from the config bucket only, never from the public bucket.

A published release folder is never changed. Users' stacks point to it, and stage 1 copies it again on later
updates (a changed domain list, the `Updater` switch). A fix is a new release.

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

Currently the applications are installed only on the first install. The first release that bumps one of them
must also add the update step: at every boot, compare the recorded package with the release's one, and if they
differ, install the new one and run the application's own upgrade steps from its upgrade notes (database
schema, config changes). Only then is the new name recorded.

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
- one after another, from the data's release to the installer's release, so a user can skip releases.

If a migration fails, everything is restored from the backup and the install stops. A migration therefore
doesn't need its own rollback, but it must not change anything outside the backup (mail, the queue, other
AWS resources).

A migration runs once per release step and can rely on the data being exactly at `<from>`. It has
`BUCKET_CONFIG` and the other stack variables from UserData, and the helpers in `/usr/local/sbin` (`secrets`,
`instance-log`, `upgrade-data`).

Migrations live in `s3bucket/migrations/` and go into the stage 1 `Files` list. All migrations of all releases
stay in the list for good: a server several releases behind needs every step in between.

## Release checklist

1. **Version.** In `s3bucket/system/upgrade-data`, set `this_release=X.Y` and append `X.Y` to `releases`
   (oldest first, every release listed).
2. **Migration**, if the data change: write `s3bucket/migrations/upgrade-<previous>-X.Y.sh`.
3. **Files list.** Every file in `s3bucket/` that instances use is in the stage 1 `Files` list, including new
   files and all migrations. A missing file is simply absent from the config bucket and fails the install.
4. **BaseUrl.** In `1-dns-preset.yaml`, point `BaseUrl` to `.../vX.Y`.
5. **Maintenance template.** If `2-deployment.yaml` changed, regenerate it:

   ```
   python build/make-maintenance.py 2-deployment.yaml x-maintenance.yaml
   ```

6. **Attachment lists.** Compare `s3bucket/rspamd/attachments-gmail.map` with Google's list of blocked file types
   (https://support.google.com/mail/answer/6590) and `attachments-strict.map` with Microsoft's list of attachments
   Outlook blocks; update them and the date in their headers.
7. **Rspamd package.** The release carries a copy of the Rspamd package, used when rspamd.com can't be reached.
   On an AlmaLinux instance with the Rspamd repository, `dnf download rspamd` the newest 4.x, check it with
   `rpm -K` (key `rspamd/rspamd.asc`), upload it to `packages/`, and update its name in `base.sh` (`rspamd_rpm`)
   and in the stage 1 `Files` list.
   The macro check: compare `s3bucket/rspamd/olefy.py` with the newest olefy
   (https://github.com/HeinleinSupport/olefy), and regenerate `olefy-requirements.txt` from the newest oletools:
   in a Python 3.12 environment, `pip download --only-binary=:all: oletools colorclass python-magic`, then one line
   `name==version --hash=sha256:...` per downloaded file.
8. **Test a fresh install** on a test stand with `CertificateMode=staging`: install READY, mail between the
   stand's own domains, webmail, admin pages, DKIM, DNS records.
9. **Test the upgrade** on a stand installed from the previous release, following UPGRADING.md step by step:
   `UPGRADE` lines in the event log, `flashlight=X.Y` in `versions`, the admin's settings files unchanged, mail
   still there. If the release has a migration, also test a release skip (from two releases back) if one exists,
   and a failing migration. A failing migration is tested on the instance with `MIGRATIONS_DIR`, `RELEASES` and
   `THIS_RELEASE`, which `upgrade-data` reads instead of its built-in values.
10. **Publish the files.** Upload `s3bucket/` to `s3://mail-server-bundles/vX.Y/` keeping the layout, and check
   that every path of the `Files` list is there.
11. **Publish the code.** Merge into `main`, tag `vX.Y`, and write the release notes: what changed, whether the
   release changes the data, and any action the user must take.

## Testing tips

- Use `CertificateMode=staging` on test stands: Let's Encrypt limits production certificates to a few per week
  for the same names.
- Test mail only between the stand's own domains, never with outside addresses.
- `install-finish` has a dry-run mode for its AWS actions (`DRY_RUN=1`); see its header.
