<!-- Copyright 2020-2026 Samson (https://github.com/georgio-sd). SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 (see LICENSE) -->
# Upgrading Flashlight

This guide is for the person who runs a Flashlight mail server and wants to move it to a newer Flashlight
release. It applies to servers installed with Flashlight 1.0 or later. Servers installed with 0.5 or older
can't be upgraded this way; they are moved to 1.0 by hand.

## What an upgrade changes

A Flashlight release is a set of CloudFormation templates plus the installer files they point to. An upgrade
replaces the server instance with a new one built from the new release. Everything that matters lives on EFS
and stays:

| Kept as it is | Replaced by the new release |
|---|---|
| Mail, mailboxes, aliases, domains | The instance itself: OS, packages, programs |
| MariaDB databases (PostfixAdmin, Roundcube, phpMyAdmin) | Flashlight's own config files (Postfix, Dovecot, Apache, OpenDKIM, Rspamd, fail2ban, the web applications) |
| Certificates, DKIM keys, passwords (`/mnt/mailserver/root`) | The web applications (Roundcube, PostfixAdmin, phpMyAdmin), when the release brings newer versions: updated by their own upgrade steps, after a backup |
| **Your own settings files for every program**, which upgrades never change (`/mnt/mailserver/etc`, listed in [Customizing the server](INSTALL.md#customizing-the-server)) | Flashlight's scripts (`/mnt/mailserver/automation`) and its block in the same crontab (`# Flashlight begin` ... `# Flashlight end`) |
| Your own lines in the crontab (`/mnt/mailserver/etc/crontab`, outside Flashlight's block) | The admin site's start page and its Mail storage statistics page |
| The spam filter's learning, its web interface settings, statistics and the whitelist of partner domains (`/mnt/mailserver/valkey`, `/mnt/mailserver/rspamd`) | |
| The mail storage statistics and their history (database `flashlight`) | |
| The event log, install logs, database dumps and upgrade backups (`/mnt/mailserver/log`, `/mnt/mailserver/backup`) | |
| The mail of deleted mailboxes, for its 30 days (`/mnt/mailserver/mail/.deleted`) | |

Everything in the left column is what this guide calls **the data**: it lives on EFS and outlives every
instance. The `flashlight=` line of `/mnt/mailserver/versions` records which release the data belong to. Some
upgrades from one release to the next also need a one-off change to the data, for example a new database
column or a file moved to another folder; mail itself is never changed. The new instance makes these changes
itself during the upgrade and then records its own release for the data (see [What happens on the server](#what-happens-on-the-server)).

## Before you start

1. Read the release notes of every release between yours and the new one. You can skip releases: the new
   instance applies all the data changes in between, one after another.
2. Check which release your data are at:

   ```
   sudo cat /mnt/mailserver/versions
   ```

   The `flashlight=` line is the release.
3. Download the templates of the new release: `1-dns-preset.yaml`, `2-deployment.yaml` and
   `x-maintenance.yaml`.
4. Plan for about 30 minutes without mail service. Other mail servers keep the messages they couldn't deliver
   and retry for several days, so incoming mail arrives after the upgrade. Webmail and IMAP are unavailable
   during this time.

## Upgrade steps

Run the three stack updates in this order, in the CloudFormation console, choosing **Replace current
template** each time. Wait for each update to finish before starting the next one.

1. **Stage 2 into maintenance mode.** Update the stage 2 stack with `x-maintenance.yaml` of the new release.
   Keep the parameters as they are, except those that the section "Upgrading from <your release>" of the new
   release in [CHANGELOG.md](../CHANGELOG.md) asks to change: the maintenance template already has the new
   release's parameters. The server instance is shut down; EFS with all the data stays.
2. **Stage 1.** Update the stage 1 stack with the new `1-dns-preset.yaml`. Keep the parameters as they are; the
   `Updater` switch isn't needed, a new release runs the stack's setup by itself. This copies the new release's
   installer files into your config bucket, takes the newest server image and writes the DNS records again.
3. **Stage 2 back to service.** Update the stage 2 stack with the new `2-deployment.yaml`. Keep the parameters
   as they are after step 1; new parameters, if the release adds any, come with sensible defaults. A new instance is
   installed from the new release. The update finishes when the server reports that it is ready, usually
   after 6 to 10 minutes.

Why maintenance mode first: in step 2 (the stage 1 update) the installer files in the config bucket are
already the new ones. A running instance that got replaced at that moment (a spot interruption, for example)
would be installed from the new files by the old stage 2 template (its install commands and parameters). In
maintenance mode no instance runs. Also, the stage 1 update takes the newest server image, and CloudFormation
doesn't let it change the image while stage 2 is in service: when a newer image exists, the update is rolled
back.

## Checking the result

Log in to the server and look at the event log:

```
sudo tail /mnt/mailserver/log/instance.log
```

A successful upgrade shows lines like these:

```
BOOT     new Spot instance, installing
UPGRADE  data 1.0 -> 1.1, backup in backup/upgrade-1.0-1.1-20270301-021044
UPGRADE  step 1.0-1.1 done
UPGRADE  data now at 1.1
REBOOT   rebooting
READY    installed and rebooted, services up
```

The `UPGRADE data` lines are about [the data](#what-an-upgrade-changes): the release they belong to, each
release's change to them (`step`), and the release they are at now.

A release that doesn't change the data shows one line instead: `UPGRADE data 1.0 -> 1.1, no data changes in
between`. `/mnt/mailserver/versions` now shows the new release. Then send a test message and log in to webmail.

## What happens on the server

The new instance mounts EFS and compares the release of the data with its own release:

- **Same release:** a normal install. Only the configs and the instance are new.
- **Older data, no data changes between the two releases:** only the release recorded for the data is raised.
- **Older data, with data changes between the two releases:** it starts MariaDB and backs up everything a data
  change may touch: the databases and the `etc`, `www`, `root` and `automation` folders on EFS. Mail itself is
  never changed by an upgrade and is not in this backup. Then it runs the data changes one release after
  another. If any of them fails, it restores the whole backup, writes a `FAILED` line to the event log and
  stops; your data are then exactly as before the upgrade. The backup stays in
  `/mnt/mailserver/backup/upgrade-<from>-<to>-<date>` for 90 days.
- **Newer data** (an older release installed over data of a newer one): it stops before changing anything and
  writes a `FAILED` line.

Then it compares the web applications on EFS (PostfixAdmin, phpMyAdmin, Roundcube) with the release's versions.
An older one is updated: its database and folder go to `/mnt/mailserver/backup/upgrade-<application>-<date>`
(kept 90 days), the new version is installed with the application's own upgrade steps, and the event log shows
`UPGRADE postfixadmin ... now at ...`. If that fails, the old version and its database are put back, a `FAILED`
line is written and the install stops. Your settings files for the applications are not touched.

## If the upgrade fails

**A parameter value is no longer allowed.** CloudFormation refuses the update at once with
`Parameter '...' must be one of AllowedValues`, or starts it and rolls it back within a minute with
`Parameter validation failed: assertion error: ...`, which says what to choose. Nothing changed: choose the value
(see "Upgrading from <your release>" in the CHANGELOG) and run the same step again.

When the new instance fails to install, step 3 fails within a few minutes and CloudFormation rolls the stage 2
stack back to maintenance mode. The server stays down until you act. To find the cause:

- The install log of the failed instance is kept in your config bucket, in `install-logs/`, for 90 days.
- `/mnt/mailserver/log/instance.log` shows how far it got.

Then either:

- **Fix the cause and run step 3 again.** This is the usual way: a failed data change has already been
  rolled back, so the next attempt starts from the old data again.
- **Go back to your previous release.** Update stage 1 with the previous release's `1-dns-preset.yaml` (this
  puts the previous installer files back into the config bucket), then stage 2 with the previous
  `2-deployment.yaml`. This works only if the data were not upgraded: check `flashlight=` in
  `/mnt/mailserver/versions`. If the log shows `UPGRADE data now at ...` and the install failed after that,
  the data belong to the new release and the previous release refuses to touch them. In that case fix the
  cause and run step 3 again, or restore the upgrade backup by hand.

## Things to avoid

- **Updating stage 2 straight to the new release without maintenance mode** (see why in
  [Upgrade steps](#upgrade-steps)). If such an update fails after the new instance has upgraded the data, the
  stack rolls back to the old instance, which can't run data of a newer release: it keeps its services stopped
  and writes a `STOP ... upgraded the data` line to the event log until you run the update to the new release
  again, or restore the upgrade backup by hand (it then resumes by itself within a minute).
- **Editing Flashlight's own config files.** Use your own settings files instead (see
  [Customizing the server](INSTALL.md#customizing-the-server)).
- **Deleting `/mnt/mailserver/versions` or `/mnt/mailserver/root/secrets`.** The first tells the installer
  which release your data belong to; the second holds the generated passwords and keys that Flashlight's
  configs are rebuilt from.
