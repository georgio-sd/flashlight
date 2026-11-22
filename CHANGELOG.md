<!-- Copyright 2020-2026 Samson (https://github.com/georgio-sd). SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 (see LICENSE) -->
# Changelog

All notable changes of Flashlight Mail Server. Each release has a tag (`v1.0`, ...) and a page under GitHub
Releases with its templates. How to move a server to a newer release: [docs/UPGRADING.md](docs/UPGRADING.md).

## [Unreleased]

Changes for the next release (1.1). Its installer files are in the public bucket folder `v1.1/`; the `v1.0/`
folder is frozen.

### Upgrading from 1.0

Follow [docs/UPGRADING.md](docs/UPGRADING.md). The data need no changes. Most stacks keep all their parameters;
three settings that 1.0 allowed must change, already in step 1 (the maintenance template has the same
parameters):

| Your 1.0 stack | The update stops with | Choose instead |
|---|---|---|
| InstanceType `t3.large` | `Parameter 'InstanceType' must be one of AllowedValues` | `t3.medium` with `t3a.medium`; for 8 GB of memory `m7i.large` with `m6a.large`, or `t3.xlarge` with `t3a.xlarge`, both with DiskVolumeSize 12 or more |
| Swap `DISABLED` with DiskVolumeSize `8` | `Parameter 'DiskVolumeSize' must be one of AllowedValues` | DiskVolumeSize `10` (`12` on types with 8 GB of memory or more) |
| `t3.xlarge`, Swap `DISABLED`, DiskVolumeSize `10` | `Parameter validation failed: ... need a disk (DiskVolumeSize) of at least 12 GiB` | DiskVolumeSize `12` |

The Swap parameter is gone: the console no longer shows it, and a command line update must not pass it
(`Parameters: [Swap] do not exist in the template`). The new AlertEmail parameter is optional and empty by
default.

### Added

- A license: Flashlight is under the PolyForm Shield License 1.0.0 ([LICENSE](LICENSE)), free to use, including
  by companies for their own mail, except for offering a competing product or service. Components from other
  projects keep their own licenses ([THIRD-PARTY.md](THIRD-PARTY.md)). Bug reports and feature requests:
  [CONTRIBUTING.md](CONTRIBUTING.md).
- Alert emails (new optional stage 2 parameter AlertEmail, up to 3 outside addresses): an email when the server
  can't come back after an instance replacement (the install on the new instance failed, is retried or given up,
  or worked again after failures; or the install can't even start), and when AWS can't start any instance for
  15 minutes (no free capacity of the instance types), with a second email once an instance runs again. Each
  address is confirmed once with the link in an email from AWS Notifications; the server reports addresses that
  aren't confirmed in its event log.
- Web applications are updated at upgrades: when a release brings a newer PostfixAdmin (later also Roundcube or
  phpMyAdmin), the server installs it with the application's own upgrade steps, after a backup of its database and
  files, and puts the old version back if anything fails.
- The costs of each server in the billing: every resource of both stacks has the tag `flashlight:installation`
  with the stage 1 stack name, the server image copy too (it counts for the server that copied it). The
  `Name` tag (`<stack name>-Flashlight`) is now also on the instance's disk and network interface, the launch
  template, the log groups, the alert topic and alarm, and on the image copy (`Flashlight <image name>`).
  INSTALL: naming the stacks after the main domain (`example-com`, `example-com-server`), turning the tag on in
  the billing and seeing each server's costs in Cost Explorer. At the upgrade from 1.0 the resources get the
  tags; an image copy made by 1.0 stays untagged until the next image.

### Security

- PostfixAdmin 4.0.7: fixes a cross-site scripting hole in the alias lists (CVE-2026-127178), and a domain admin
  can no longer list the logins of all admins. A server installed with 1.0 gets it at the upgrade.
- The install log no longer contains the generated passwords and the Spamhaus DQS key, and the console output of
  the instance no longer shows the key. Install logs written by 1.0 still contain them: on the server
  (`/var/log/flashlight-install.log`, and `/mnt/mailserver/log/`) and, for failed installs, in `install-logs/` of
  the config bucket (90 days). Delete them if that matters to you.

### Fixed

- A new server's install failed about one time in four, at creating the PostfixAdmin administrator: its generated
  password sometimes had fewer than the 2 digits PostfixAdmin requires.
- A failed first creation of stage 1 no longer deletes the domain's own DNS records on its rollback. The rollback
  cleaned up every record whose value matched Flashlight's, so an existing MX to `mail.<domain>` and a DKIM key at
  `mail._domainkey` were deleted although stage 1 had never written them.
- With three Availability Zones, the first server no longer starts before the mail storage can be mounted in the
  third zone. Stage 2 waited only for the first two zones, so an instance placed in the third one could fail to
  install while its EFS mount target was still being created.
- A stack update that changes only InstanceType, InstanceType2 or InstanceLifecycle now replaces the server, as
  the documentation says. Before, the Auto Scaling group applied the new type or Spot setting only to the next
  instance it started (after a Spot interruption or the scheduled rebuild).
- After a server start, mail is taken only once the spam filter (and the virus scanner, with Antivirus) answer.
  Before, Postfix could take mail while they were still starting, and with Antivirus the mail of the first
  half-minute or so passed without the virus scan. A crashed virus scanner now restarts by itself.
- After a server start, the spam filter's first DNS lookups no longer fail now and then. With an empty cache,
  the burst of lookups for the mail queued during a replacement raced to fetch the DNSSEC keys, and some of them
  (blocklists, SPF of other domains) failed for the first messages. Unbound now fetches the keys of the root and
  of net, com and org first.
- The database (MariaDB) restarts by itself after it stops on an error, like the mail services. Before, it came
  back only after a crash, and an exit on an error (a short outage of the mail storage, for example) left the
  server without logins until someone started it.
- During a server replacement the old and the new server no longer disturb each other's connection to the mail
  storage. Both introduced themselves to EFS by the same hostname, so EFS took them for one client, and the new
  server could lose its file locks when the old one shut down.
- Around 1000 connected mail programs no longer slow every login down: Dovecot's internal services were limited
  to 1000 connections, and mail programs waiting for new mail (IDLE) ran out of the kernel's notification
  instances after 128.

### Changed

- The server image is on AlmaLinux 10.3 (it was 10.2), so an install has less to update. Updating stage 1 to a new
  release now also takes the newest server image; before, only the Updater switch did.
- An install that hangs (a download that never finishes, for example) is stopped after 60 minutes and counts as a
  failed install: after an instance replacement it is retried on a new instance, with the alert emails. Before, the
  server stayed down until someone noticed.
- Stage 2 waits up to 30 minutes for the install instead of 20: an install can take 12 minutes on a slower
  instance type or region.
- When a new instance can't even begin the install (the AWS CLI can't be installed or the config bucket can't be
  read), it now waits 30 minutes instead of 5 before it turns itself off and the next instance tries.
- The mail storage (EFS) is named `<stage 2 stack name>-Flashlight` in the EFS console, also after the stack
  is deleted, so it is clear whose file system it is.
- Switching Antivirus off removes the virus signature database (about 110 MB) from the mail storage at the next
  install; switching it on again downloads it again.
- INSTALL: deleting the server step by step, including emptying the config bucket before deleting stage 1, and
  what to do when AWS keeps the Elastic IP locked to the account.
- INSTALL: asking AWS to allow outgoing mail on port 25 step by step, with a ready request text; the limit is
  lifted per region.
- INSTALL: turning on termination protection for both stacks after the install, so they can't be deleted by
  mistake (updates and upgrades are not affected).
- INSTALL: setting up mail programs step by step: where to add the account in the common programs, why every
  domain uses `mail.<main domain>`, what is supported and what isn't, and the usual cause when sending fails.
- INSTALL: choosing the instance type, from load tests: how many webmail users and mail program connections each
  type carries, why mailboxes are not active users, and how the t3 CPU credits work.
- Instance types: c7i (with c6a as its pair) and m7i (with m6a) in large and xlarge, which have the whole CPU at all
  times with no credits; t3.large is gone (no more CPU than t3.medium, at about the price of m6a.large). InstanceType2
  must be the pair of InstanceType: t3a for t3, c6a for c7i, m6a for m7i. A stack on t3.large chooses another type
  at the upgrade (see Upgrading from 1.0).
- The swap file is always made; the Swap parameter is gone and DiskVolumeSize starts at 10 GiB (12 for 8 GB of
  memory and more). A stack with Swap = DISABLED and a smaller disk sets a bigger one at the upgrade (see
  Upgrading from 1.0).
- The database log no longer fills with "Aborted connection" notes (dozens an hour under load): Postfix ends its
  lookup connections without a goodbye, which is harmless. MariaDB logs at level 1 instead of 2; errors and real
  warnings are still logged.
- The network helper nm-cloud-setup is off: the server has one network interface and nothing for it to set up.
  It polled the instance metadata every 5 minutes and logged "code=killed, status=15/TERM" at every boot.
- Valkey and Unbound use IPv4 only (IPv6 is off): no more warnings at every start, and no DNS queries wasted on
  IPv6 servers; ManageSieve (webmail filters) listens only on 127.0.0.1. Services the server doesn't use are off:
  fwupd (firmware updates, of which an EC2 instance has none), the dnf metadata refresh, SSSD and gssproxy;
  tuned applies its profile at boot and exits instead of staying in memory.
- The number of mail program connections grows with the server's memory: about 2350 on 8 GB with the antivirus,
  6350 on 16 GB (1024, Dovecot's default, on 2-4 GB servers).

## [1.0] - 2026-11-14

A rewrite of the installer on current software, with a spam filter, automatic recovery and upgrades between
releases.

### Upgrading from 0.5

There is no automatic upgrade from 0.5. Install 1.0 as a new server and move the mailboxes to it: the PostfixAdmin
and Roundcube databases (PostfixAdmin and Roundcube upgrade their own schema) and the Maildirs. Users keep their
passwords. From 1.0 on, upgrades between releases are automatic ([docs/UPGRADING.md](docs/UPGRADING.md)).

### Added

- **Spam filter** (Rspamd 4.3, stack parameter Antispam, on by default): sender checks (SPF, DKIM, DMARC, ARC),
  blocklists, Bayes learning, spam to the Junk folder, obvious spam refused. Optional Spamhaus DQS with a free key
  (SpamhausDQSKey).
- Learning from users: moving a message into or out of Junk, or the Spam / Not spam buttons in webmail.
- Rspamd web interface on the admin site, with a whitelist of partner domains.
- Office documents with suspicious macros go to Junk (oletools).
- Risky attachments: refused like Gmail does, or stricter (stack parameter AttachmentPolicy).
- Optional virus scanning with ClamAV (stack parameter Antivirus, medium instance types and larger).
- **Outgoing mail guarded against stolen passwords:** users send only as their own addresses, at most 30 messages
  an hour, 300 a day and 20 recipients per message; the admin gets an e-mail about a mailbox that may be
  compromised.
- **Automatic recovery:** a failed install is retried on a new instance; a failed stack update rolls back while
  the running server keeps working; only one instance ever uses the data.
- Scheduled rebuild on current packages (stack parameter RebuildAfterDays, default 30 days).
- **Upgrades between releases:** the data on EFS know their release, a new release upgrades them with a backup
  and restores everything if anything fails.
- The admin's own settings files for every program, kept apart from Flashlight's and never touched by upgrades.
- Event log of the server (`/mnt/mailserver/log/instance.log`); install logs kept on EFS and, for failed
  installs, in the config bucket.
- Reverse DNS of the Elastic IP is set automatically.
- Swap file sized automatically (stack parameter Swap).
- Deleted mailboxes: their mail goes to a 30-day trash.
- Full mailboxes are refused during the SMTP session instead of bouncing later.
- Documentation: README, installation guide, description of the server, upgrading and releasing.

### Changed

- AlmaLinux 10 instead of AlmaLinux 8; Postfix 3.8, Dovecot 2.3, MariaDB 10.11, PHP 8.3, Roundcube 1.7.6,
  PostfixAdmin 4.0.6, phpMyAdmin 5.2.3.
- Let's Encrypt certificates validated through DNS (Route 53): renewals no longer stop the web server. Staging
  certificates for test installs (stack parameter CertificateMode).
- DKIM keys of 2048 bits; SPF `-all` and DMARC `p=reject` written by the server. An SPF record that already allows
  the server's address and an existing DMARC record are left as the admin set them.
- Spot: the instance is replaced through the Auto Scaling group; a weekly price check moves it to a cheaper pool.
- Two interchangeable instance types of the same size (InstanceType, InstanceType2); t3 and t3a.
- fail2ban on nftables, on by default; it also protects webmail and the admin site.
- Stage 1 Lambdas rewritten in Python 3.14 inside the template. Stage 1 copies the server image into the region
  and waits until it can be used, and removes Flashlight's DNS records when the stack is deleted.
- The maintenance template is generated from the stage 2 template.

### Security

- The server's disk is encrypted; EFS is mounted over TLS.
- The instance's rights in AWS narrowed: TXT records of its own zones only, read-only installer files.
- Instance metadata (AWS credentials of the instance) reachable by root only.
- The mail storage outlives the stack (`DeletionPolicy: RetainExceptOnCreate`).
- Login for sending mail only on ports 587 and 465, with TLS 1.2 or newer.

### Removed

- The iptables service, Remi PHP, building packages on the server, the AWS CloudFormation helper scripts.

## [0.5] - 2025-11-07

The original version, on AlmaLinux 8 (branch `dev`). Not maintained any more.
