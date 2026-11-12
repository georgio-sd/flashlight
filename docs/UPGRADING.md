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
| Mail, mailboxes, aliases, domains | Flashlight's own config files (Postfix, Dovecot, Apache, OpenDKIM, fail2ban, the web applications) |
| MariaDB databases (PostfixAdmin, Roundcube, phpMyAdmin) | Our block in the crontab (`# Flashlight begin` ... `# Flashlight end`) |
| Certificates, DKIM keys, passwords (`/mnt/mailserver/root`) | The instance itself: OS, packages, scripts |
| Your own settings files (see below) | |
| Your own crontab lines outside our block | |

Flashlight's config files are rebuilt at every boot, so any change made directly in them is lost at the next
instance replacement, whether or not you upgrade. Your own settings go to the files below. Flashlight creates each
file once with an explanation and an example and never changes it afterwards:

| Program | Your settings file |
|---|---|
| Postfix | `/mnt/mailserver/etc/postfix/main.local.cf` |
| Dovecot | `/mnt/mailserver/etc/dovecot/custom.conf` |
| Apache | `/mnt/mailserver/etc/httpd/custom.conf`, `custom-mail.conf`, `custom-admin.conf` |
| MariaDB | `/mnt/mailserver/etc/mariadb/custom.cnf` |
| fail2ban | `/mnt/mailserver/etc/fail2ban/custom.local` |
| Roundcube | `/mnt/mailserver/etc/roundcube/custom.inc.php` |
| PostfixAdmin | `/mnt/mailserver/etc/postfixadmin/custom.php` |
| phpMyAdmin | `/mnt/mailserver/etc/phpmyadmin/custom.php` |

OpenDKIM has no settings file of its own.

Some releases also need a one-off change to the data, for example a new database column. The new instance
does this itself during the upgrade (see [What happens on the server](#what-happens-on-the-server)).

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
   Keep the parameters as they are. The server instance is shut down; EFS with all the data stays.
2. **Stage 1.** Update the stage 1 stack with the new `1-dns-preset.yaml`. Keep the parameters as they are.
   This copies the new release's installer files into your config bucket.
3. **Stage 2 back to service.** Update the stage 2 stack with the new `2-deployment.yaml`. Keep the parameters
   as they are; new parameters, if the release adds any, come with sensible defaults. A new instance is
   installed from the new release. The update finishes when the server reports that it is ready, usually
   after 6 to 10 minutes.

Why maintenance mode first: in step 2 the installer files in the config bucket are already the new ones. A
running instance that got replaced at that moment (a spot interruption, for example) would be installed from
new files with old settings. In maintenance mode no instance runs. Stage 1 also can't change its list of mail
domains while stage 2 uses it, and in maintenance mode it doesn't.

## Checking the result

Log in to the server and look at the event log:

```
sudo tail /mnt/mailserver/log/instance.log
```

A successful upgrade shows lines like these:

```
BOOT     new Spot instance, installing
UPGRADE  data 1.0 -> 1.1, backup in backup/upgrade-1.0-1.1-2027-03-01-02-10-44
UPGRADE  step 1.0-1.1 done
UPGRADE  data now at 1.1
REBOOT   rebooting
READY    installed and rebooted, services up
```

The `UPGRADE` lines appear only when the release changes the data. `/mnt/mailserver/versions` now shows the
new release. Then send a test message and log in to webmail.

## What happens on the server

The new instance mounts EFS and compares the release of the data with its own release:

- **Same release:** a normal install. Only the configs and the instance are new.
- **Older data:** it starts MariaDB and backs up everything a data change may touch: the databases and the
  `etc`, `www`, `root` and `automation` folders on EFS. Mail itself is never changed by an upgrade and is not
  in this backup. Then it runs the data changes of each release in between, in order. If any of them fails,
  it restores the whole backup, writes a `FAILED` line to the event log and stops; your data are then exactly
  as before the upgrade. The backup stays in `/mnt/mailserver/backup/upgrade-<from>-<to>-<date>` for 90 days.
- **Newer data** (an older release installed over data of a newer one): it stops before changing anything and
  writes a `FAILED` line.

## If the upgrade fails

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

- **Updating stage 2 straight to the new release without maintenance mode.** The old instance stops its
  services while the new one installs. If the new one upgrades the data and then fails, the stack update rolls
  back, but the old instance can't run data of a newer release: it keeps its services stopped and writes a
  `STOP ... upgraded the data` line to the event log. The server stays down until you either run the update to
  the new release again, or restore the upgrade backup by hand; in the second case the old instance resumes by
  itself within a minute.
- **Editing Flashlight's own config files.** Use the settings files listed above.
- **Deleting `/mnt/mailserver/versions` or `/mnt/mailserver/root/secrets`.** The first tells the installer
  which release your data belong to; the second holds the generated passwords and keys that Flashlight's
  configs are rebuilt from.
