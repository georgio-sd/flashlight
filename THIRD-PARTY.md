<!-- Copyright 2020-2026 Samson (https://github.com/georgio-sd). SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 (see LICENSE) -->

# Third-party components

Flashlight's own code is under the PolyForm Shield License 1.0.0 (see [LICENSE](LICENSE)). The components below
come from other projects and keep their own licenses.

## Packages in the installer's bucket

The release bucket (`s3://flashlight-mail-server/vX.Y/packages/`) carries these packages unchanged, as their
projects publish them (efs-utils built from its unchanged source). Each one includes its own license files.

| Package | Project | License |
|---|---|---|
| `roundcubemail-<version>-complete.tar.gz` | Roundcube Webmail, https://roundcube.net | [GNU GPL 3.0 or later](https://www.gnu.org/licenses/gpl-3.0.html), with the exceptions in its LICENSE; bundled libraries under their own licenses |
| `roundcube-larry-<commit>.tar.gz` | Roundcube skin "Larry", https://github.com/roundcube/larry | [Creative Commons Attribution-ShareAlike 3.0](https://creativecommons.org/licenses/by-sa/3.0/) |
| `postfixadmin-<version>.tar.gz` | PostfixAdmin, https://github.com/postfixadmin/postfixadmin | [GNU GPL 2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html) |
| `phpMyAdmin-<version>-all-languages.tar.gz` | phpMyAdmin, https://www.phpmyadmin.net | [GNU GPL 2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html) |
| `rspamd-<version>.el10.x86_64.rpm` | Rspamd, https://rspamd.com | [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) |
| `amazon-efs-utils-<version>.el10.x86_64.rpm` | Amazon EFS utilities, https://github.com/aws/efs-utils (built as in [build/efs-utils.md](build/efs-utils.md)) | [MIT License](https://github.com/aws/efs-utils/blob/master/LICENSE) |

## Files in this repository

| File | Project | Source | License |
|---|---|---|---|
| `s3bucket/rspamd/olefy.py` | olefy, Heinlein Support GmbH | https://github.com/HeinleinSupport/olefy (commit 9c01c57), unchanged | [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) |
| `s3bucket/rspamd/spamhaus-dqs-rbl.conf`, `s3bucket/rspamd/spamhaus-dqs-rbl_group.conf` | Spamhaus DQS for Rspamd, Spamhaus Technology Ltd. | https://github.com/spamhaus/rspamd-dqs (commit d71470e), unchanged; the installer puts the user's key in | [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) |
| `s3bucket/rspamd/rspamd.asc` | Rspamd | the public key that signs Rspamd's packages, https://rspamd.com | |

Each of these files names its source and license in its header. The attachment lists
(`s3bucket/rspamd/attachments-*.map`) are file types taken from Google's and Microsoft's published lists, named
in their headers.

## The server image

Stage 1 starts the server from an image (AMI) published by Flashlight's author with the description
`Mailserver:img_b`. It is an unchanged copy of the official AlmaLinux OS image (https://almalinux.org), published
again so that every stack finds the image it was tested with under one name. AlmaLinux OS is a collection of
programs under their own licenses, most of them free software licenses such as the GNU GPL; the source code of its
packages is available from AlmaLinux at https://vault.almalinux.org. AlmaLinux is a trademark of the AlmaLinux OS
Foundation; Flashlight is not affiliated with or endorsed by it.

## Installed from the operating system's repositories

The server also installs programs from AlmaLinux's and EPEL's package repositories (Postfix, Dovecot, MariaDB,
Apache, PHP, ClamAV, fail2ban and others). They are installed, not distributed by Flashlight, and are under
their own licenses.
