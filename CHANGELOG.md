# Changelog

All notable changes of Flashlight Mail Server. Each release has a tag (`v1.0`, ...) and a page under GitHub
Releases with its templates. How to move a server to a newer release: [docs/UPGRADING.md](docs/UPGRADING.md).

## [Unreleased]

Changes for the next release (1.1). Its installer files are in the public bucket folder `v1.1/`; the `v1.0/`
folder is frozen.

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
