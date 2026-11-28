#!/bin/bash -xe
# Copyright 2020-2026 Samson (https://github.com/georgio-sd)
# SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 (see LICENSE)
#
# The stack's variables come from UserData. Without them some steps would act on empty values (an empty
# domain list, for example, would delete every DKIM key), so stop before touching anything.
for var in EIP_ID EIP AWS_REGION STACK MAIL_STORAGE BUCKET_CONFIG TIMEZONE ADMIN_EMAIL CERT_MODE INSTANCE_LIFECYCLE \
    DOMAIN_NAMES DOMAIN_ZONE_IDS ADMIN_DOMAIN MAIL_DOMAIN REBUILD_AFTER_DAYS ANTISPAM ATTACHMENT_POLICY ANTIVIRUS; do
  [ -n "${!var}" ] || { echo "base.sh: $var is not set, nothing done"; exit 1; }
done
#
# EC2 instance metadata (IMDSv2: get a token, then ask with it)
imds() {
  local token
  token=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/$1
}
#
# Services that keep data or config on EFS: a systemd drop-in makes them start only after /mnt/mailserver
# is mounted, and not at all if it isn't (so MariaDB can't start on an empty local folder, for example).
# The package's own unit file stays untouched.
efs_unit() {
  mkdir -p /etc/systemd/system/$1.service.d
  printf '[Unit]\nRequiresMountsFor=/mnt/mailserver\n' > /etc/systemd/system/$1.service.d/efs.conf
  systemctl daemon-reload
}
#
# Start order: a service that uses another one starts after it is ready. Wants, not Requires: restarting or
# stopping the other one later doesn't stop this one too.
# usage: start_after UNIT OTHER.service ...
start_after() {
  local unit=$1
  shift
  mkdir -p /etc/systemd/system/$unit.service.d
  printf '[Unit]\nWants=%s\nAfter=%s\n' "$*" "$*" > /etc/systemd/system/$unit.service.d/order.conf
  systemctl daemon-reload
}
#
# Environment of a service, in a systemd drop-in (env.conf)
# usage: unit_env UNIT "NAME=value ..."
unit_env() {
  mkdir -p /etc/systemd/system/$1.service.d
  printf '[Service]\nEnvironment=%s\n' "$2" > /etc/systemd/system/$1.service.d/env.conf
  systemctl daemon-reload
}
#
# A crashed service starts again by itself after 30 seconds, with no limit on the attempts: a short EFS outage, for
# example, stops the services, and they come back once EFS is there again (systemd's default gives up after 5
# quick attempts). "systemctl stop" (services-shutdown, replace-instance) and a clean exit never restart it.
# usage: restart_unit UNIT [MODE] (MODE: on-failure, the default, or the package's own, e.g. always)
restart_unit() {
  mkdir -p /etc/systemd/system/$1.service.d
  printf '%s\n' '[Unit]' 'StartLimitIntervalSec=0' '[Service]' "Restart=${2:-on-failure}" 'RestartSec=30' \
    > /etc/systemd/system/$1.service.d/restart.conf
  systemctl daemon-reload
}
#
# The admin's own settings file of a program, on EFS: created once with an explanation, then never changed
# (our files are rewritten at every boot; settings that must survive upgrades go to these files)
# usage: custom_file PATH "comment line" ...
custom_file() {
  local file=$1
  shift
  [ -f "$file" ] && return 0
  mkdir -p "${file%/*}"
  printf '%s\n' "$@" > "$file"
}
#
# Steps that handle passwords and keys run untraced: set -x would write them into the install log, which is also
# kept in the config bucket. "secret_step what it does" names the step in the log (install-finish names it when
# the install fails there) and turns the trace off; "set -x" turns it back on. Errors still reach the log.
secret_step() { { set +x; } 2> /dev/null; }
#
# Setting up system settings
timedatectl set-timezone $TIMEZONE
hostnamectl set-hostname $MAIL_DOMAIN
flag=/mnt/mailserver/flag
systemctl stop crond
#
# Disabling IPv6 (the VPC has no IPv6; the kernel parameter takes effect after the final reboot)
grubby --update-kernel ALL --args ipv6.disable=1
sed -i "s/^udp6\(.*\)/#udp6\1/; s/^tcp6\(.*\)/#tcp6\1/" /etc/netconfig
#
# Disabling amazon-ssm-agent
systemctl disable amazon-ssm-agent
#
# Disabling EC2 Instance Connect: the image's package makes sshd look up temporary keys in the instance metadata at
# every key login, as user ec2-instance-connect, which the metadata rule below refuses (root only), so it only logged
# "failed to get IMDS token". The server is entered with the stack's key pair. sshd keeps the first value it reads
# and reads its drop-ins in name order, so this file wins over the package's 60-ec2-instance-connect.conf, also
# after package updates. To use Instance Connect, delete it (its lookup also needs the metadata).
echo 'AuthorizedKeysCommand none' > /etc/ssh/sshd_config.d/50-flashlight.conf
#
# Disabling nm-cloud-setup: it sets up extra private IPs and network interfaces from the instance metadata, and the
# server has one interface with one IP (AWS maps the Elastic IP itself). Left on, it polls the metadata every 5
# minutes, and at boot NetworkManager restarts it several times a second, which logs "code=killed, status=15/TERM"
# at every boot. Masked, so NetworkManager's dispatcher can't start it either.
if systemctl list-unit-files nm-cloud-setup.service > /dev/null 2>&1; then
  systemctl disable --now nm-cloud-setup.timer
  systemctl mask nm-cloud-setup.service
fi
#
# Disabling fwupd: it updates the firmware of the hardware, and an EC2 instance has none it can update; its timer
# only downloads the firmware catalogue twice a day. The package stays (shim-x64, the UEFI boot loader, needs it
# through dbxtool); masked, so D-Bus can't start the daemon either.
if systemctl list-unit-files fwupd.service > /dev/null 2>&1; then
  systemctl disable --now fwupd-refresh.timer
  systemctl mask fwupd.service fwupd-refresh.service
fi
#
# Disabling what the server doesn't use, all in the AlmaLinux image: the dnf metadata cache refresh (packages are
# installed only at an install), SSSD (LDAP, Active Directory and Kerberos logins) and gssproxy (NFS with
# Kerberos; EFS is mounted over TLS without it). Masked, so nothing starts them.
for unit in dnf-makecache.timer sssd.service sssd-kcm.socket gssproxy.service; do
  if systemctl list-unit-files $unit > /dev/null 2>&1; then
    systemctl disable --now $unit
    systemctl mask $unit
  fi
done
# tuned applies its profile (virtual-guest) at boot and then exits: its dynamic tuning is off, so the daemon would
# only keep about 27 MB of memory
sed -i 's/^daemon = 1/daemon = 0/' /etc/tuned/tuned-main.conf
#
# Installing amazon-efs-utils (prebuilt RPM, see build/efs-utils.md) and mounting EFS
cd ~
efs_rpm=amazon-efs-utils-3.4.0-1.el10.x86_64.rpm
aws s3 cp s3://$BUCKET_CONFIG/$efs_rpm .
dnf install -y ./$efs_rpm
rm $efs_rpm
mkdir /mnt/mailserver
# A unique NFS client identity for this instance. Without it Linux introduces itself to EFS by the hostname,
# which the old and the new instance share during a replacement: EFS takes them for one client, and when one
# of them reconnects or unmounts, it wipes the other's state (its file locks are lost). modprobe.d applies at
# every boot, modprobe now to the mount below.
echo "options nfs nfs4_unique_id=$(imds instance-id)" > /etc/modprobe.d/flashlight-nfs.conf
modprobe nfs
# tls: encrypt traffic to EFS (costs about 1 s of CPU per GB transferred, no visible speed loss)
echo -e "$MAIL_STORAGE:/ /mnt/mailserver efs _netdev,tls 0 0" >> /etc/fstab
mount -a
#
# Instance helpers: imds (IMDSv2 metadata), instance-log (event log on EFS), instance-shutdown-log,
# upgrade-data (Flashlight data version on EFS and upgrades between releases), secrets (generated secrets for our configs)
for tool in imds instance-log instance-shutdown-log upgrade-data secrets; do
  aws s3 cp s3://$BUCKET_CONFIG/$tool /usr/local/sbin/
  chmod 755 /usr/local/sbin/$tool
done
#
# Data from a newer Flashlight release must not be touched by this one: stop before taking over anything
# (the Elastic IP and the EFS flag below), so the instance that runs now doesn't even notice
/usr/local/sbin/upgrade-data check
#
# Setting up ElasticIP
instid=$(imds instance-id)
# right after boot the instance's network interface may not be visible to the Elastic IP service yet
# (InvalidNetworkInterfaceID.NotFound, which the AWS CLI doesn't retry): try every 10 seconds for up to 3 minutes
for try in $(seq 18); do
  aws ec2 associate-address --instance-id $instid --allocation-id $EIP_ID --region $AWS_REGION && break
  [ $try -lt 18 ] || exit 1
  sleep 10
done
# kept for services-shutdown, which takes the address back if a newer instance fails and is terminated
echo "$EIP_ID" > /usr/local/etc/eip-allocation-id
#
# Creating directories and the vmail user (owner of all mailboxes).
# Writing this instance's EFS flag makes the instance that runs now stop its services (double-inst-prot).
rm -f /mnt/mailserver/flag-ec2id-*
printf "Do not delete this file" > /mnt/mailserver/flag-ec2id-$instid
groupadd -g 5000 vmail
useradd -M -d /mnt/mailserver/mail -g 5000 -u 5000 -s /sbin/nologin vmail
if [ ! -f $flag ]; then
  mkdir /mnt/mailserver/root /mnt/mailserver/automation /mnt/mailserver/log /mnt/mailserver/backup
  mkdir /mnt/mailserver/www /mnt/mailserver/etc /mnt/mailserver/mail
  mkdir /mnt/mailserver/mail/shared-folders /mnt/mailserver/mail/sieve /mnt/mailserver/spool
  chmod 700 /mnt/mailserver/backup
  chown -R vmail: /mnt/mailserver/mail
fi
/usr/local/sbin/instance-log BOOT "new $INSTANCE_LIFECYCLE instance, installing"
# image of this instance and its OS before and after the OS update (information only)
/usr/local/sbin/upgrade-data set image "$(imds ami-id) ${IMAGE_OS:-unknown OS}"
/usr/local/sbin/upgrade-data set os "$(. /etc/os-release && echo "$PRETTY_NAME")"
# SHUTDOWN / REBOOT lines when the instance goes down (started now, so the install's own reboot is logged too)
aws s3 cp s3://$BUCKET_CONFIG/shutdown-log.service /etc/systemd/system
systemctl daemon-reload
systemctl enable --now shutdown-log
#
# upload/ in the config bucket: the admin's place for files from the server to keep (aws s3 cp FILE
# s3://$BUCKET_CONFIG/upload/). Besides install-logs/, it is the only place in the bucket the server can write to.
# An empty file there reminds the admin of it. (Files in the bucket also stop the stage 1 stack deletion until
# the bucket is emptied by hand, so nothing there is lost by accident.)
marker=upload/the-mail-server-can-write-to-this-folder
aws s3api head-object --bucket $BUCKET_CONFIG --key $marker > /dev/null 2>&1 ||
  aws s3api put-object --bucket $BUCKET_CONFIG --key $marker > /dev/null ||
  echo "base.sh: could not create s3://$BUCKET_CONFIG/$marker"
#
# Installing the base set of packages (AlmaLinux AppStream/BaseOS + EPEL)
dnf install -y epel-release
# EPEL builds for the newest RHEL minor release, and AlmaLinux can be a minor release behind it: the newest
# EPEL packages may then need libraries this OS doesn't have yet (certbot did on AlmaLinux 10.2 vs EPEL 10.3).
# EPEL keeps a branch per minor release, so use the one of this OS. The version is read after the OS update
# in UserData, so a newer AlmaLinux release gets its matching EPEL branch.
os_minor=$(. /etc/os-release && echo "${VERSION_ID#*.}")
sed -i "s/-\$releasever&/-\$releasever.$os_minor\&/" /etc/yum.repos.d/epel.repo
# Postfix 3.8.5-11 leaves its queue folder to its tmpfiles rules, which run only at the end of the install, after
# its own install script has looked for the folder ("fatal: chdir(/var/spool/postfix)" in the mail log otherwise)
mkdir -p /var/spool/postfix
dnf install -y php php-cli php-fpm php-mysqlnd php-mbstring php-intl php-xml php-gd php-pecl-zip php-opcache \
  httpd httpd-tools mod_ssl mariadb mariadb-server \
  postfix postfix-mysql dovecot dovecot-mysql dovecot-pigeonhole \
  opendkim opendkim-tools certbot python3-certbot-dns-route53 pwgen python3-boto3 bind-utils mc nftables
#
# Quiet logs: each step below removes a warning that would otherwise appear at every boot
# - chrony: IPv4 only (IPv6 is off, and its command socket on ::1 fails)
if [ -f /etc/sysconfig/chronyd ]; then sed -i 's/^OPTIONS="\(.*\)"$/OPTIONS="\1 -4"/' /etc/sysconfig/chronyd; fi
# - chrony's folders belong to root in the image, so chronyd can't save its clock drift (an error every hour)
if id chrony > /dev/null 2>&1; then chown chrony:chrony /var/lib/chrony /var/log/chrony; fi
# - rpcbind and rpc.statd serve NFSv3 only (EFS is mounted with NFSv4); they also fail on IPv6 sockets
systemctl mask rpcbind.service rpcbind.socket rpc-statd.service rpc-statd-notify.service
# - NFSv4 ID mapping domain (EFS maps users by number; without it the default is reported at every mount)
sed -i 's/^#Domain = .*/Domain = localdomain/' /etc/idmapd.conf
# - the logrotate rule of sssd-common (sssd itself isn't installed) rotates as user sssd, which can't read the
#   root-owned log folder
if id sssd > /dev/null 2>&1 && [ -d /var/log/sssd ]; then chown sssd:sssd /var/log/sssd; fi
# - the tmpfiles rules of httpd, mariadb and postfix create folders where we keep links to EFS (/var/www,
#   /var/lib/mysql, the mail queue /var/spool/postfix): the same rules without those lines (a file in
#   /etc/tmpfiles.d replaces the package's one of the same name). They run before EFS is mounted, and would report
#   the links as broken. Postfix's rules are all about its queue (since 3.8.5-11), so its file ends up empty.
grep -vE '^d /var/www( |/)' /usr/lib/tmpfiles.d/httpd.conf > /etc/tmpfiles.d/httpd.conf
grep -vE '^d /var/lib/mysql ' /usr/lib/tmpfiles.d/mariadb.conf > /etc/tmpfiles.d/mariadb.conf
if [ -f /usr/lib/tmpfiles.d/postfix.conf ]; then
  grep -vE '^[a-zA-Z] /var/spool/postfix( |/|$)' /usr/lib/tmpfiles.d/postfix.conf > /etc/tmpfiles.d/postfix.conf || true
fi
# - the boot image (initramfs) of the AlmaLinux cloud image has NFS support, which starts rpcbind, rpc.statd and
#   rpc.idmapd early in the boot with their own warnings. The root file system is on EBS and EFS is mounted after
#   the boot, so it is left out; the image of the kernel this instance boots next is rebuilt (about 45 seconds)
printf '%s\n' "# Flashlight: no NFS in the boot image (root is on EBS; EFS is mounted after the boot)" \
  'omit_dracutmodules+=" nfs "' > /etc/dracut.conf.d/flashlight-no-nfs.conf
dracut -f --kver "$(grubby --default-kernel | sed 's|^/boot/vmlinuz-||')"
#
# Instance metadata (IMDS, 169.254.169.254) for root only. It hands out the instance role's AWS credentials and the
# UserData with the stack's parameters to any local process that asks; a broken-into web application (they run
# as apache) would get the server's rights in AWS: DNS records, the Elastic IP, replacing the instance.
# Everything of ours that needs it runs as root: the AWS CLI, boto3 scripts, certbot, the EFS mount helper, cron
# jobs. A service that isn't root and needs AWS access would fail here with a refused connection.
# (nftables.service loads the file at every boot; fail2ban keeps its own tables next to it)
printf '%s\n' "# Flashlight: instance metadata for root only (base.sh). DON'T EDIT: rewritten at every install." \
  'table inet flashlight_imds {' '  chain output {' '    type filter hook output priority 0; policy accept;' \
  '    ip daddr 169.254.169.254 meta skuid != 0 reject' '  }' '}' > /etc/nftables/flashlight-imds.nft
echo 'include "/etc/nftables/flashlight-imds.nft"' >> /etc/sysconfig/nftables.conf
systemctl enable --now nftables
#
# Swap: a cushion for short memory peaks (ClamAV holds two copies of its database while it loads new signatures,
# for example), so the kernel doesn't stop a service when memory runs out for a moment; the server slows down
# instead (if that happens often, it needs a bigger instance type). Idle mail connections are what goes out first.
# Half the memory, at most 4 GB: 2 GB of memory -> 1 GB of swap, 4 -> 2, 8 and more -> 4. Besides it the disk keeps
# 1.5 GB free; the template's rules ask for a big enough disk, and if the swap still doesn't fit, it is made
# smaller (or none) with a WARN line in instance.log. The disk is encrypted, so whatever goes to swap is too.
mem_mb=$(awk '/^MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
# (memory rounded to whole GB, as the instance types are sold, then halved)
swap_mb=$(( (mem_mb + 512) / 1024 * 512 ))
if [ $swap_mb -gt 4096 ]; then swap_mb=4096; fi
fit_mb=$(( $(df -m --output=avail / | tail -1) - 1536 ))
if [ $fit_mb -lt $swap_mb ]; then
  /usr/local/sbin/instance-log WARN "swap: only $(( fit_mb > 0 ? fit_mb : 0 )) of $swap_mb MB fit on the disk, choose a bigger DiskVolumeSize"
  swap_mb=$(( fit_mb > 0 ? fit_mb / 256 * 256 : 0 ))
fi
if [ $swap_mb -ge 256 ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=$swap_mb status=none
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi
# swap only under real memory pressure
echo 'vm.swappiness = 10' > /etc/sysctl.d/90-flashlight-swap.conf
sysctl -p /etc/sysctl.d/90-flashlight-swap.conf
#
# Every IMAP connection waiting in IDLE uses an inotify instance of the vmail user: the kernel's default of 128
# was exceeded at ~1000 connections in load tests, and Dovecot then falls back to checking the folders by timer.
# The kernel spends memory on these only for what is in use.
printf '%s\n' 'fs.inotify.max_user_instances = 8192' 'fs.inotify.max_user_watches = 524288' \
  > /etc/sysctl.d/90-flashlight-inotify.conf
sysctl -p /etc/sysctl.d/90-flashlight-inotify.conf
#
# One-time jobs after the final reboot: /etc/cron.once runs once from @reboot. install-finish puts the
# READY check there (services up -> READY and the CloudFormation signal), only after a good install.
cd ~
mkdir -p /etc/cron.once
printf '#!/bin/bash\n#\nfor script in `find /etc/cron.once -type f`; do $script; rm $script; done\n' \
  > /usr/bin/cron-boot-runner
chmod 744 /usr/bin/cron-boot-runner
#
# Credentials file creating (the install trace goes to the root-only flashlight-install.log; the passwords
# themselves are untraced, see secret_step)
if [ ! -f $flag ]; then
  chmod 700 /mnt/mailserver/root
  touch /mnt/mailserver/root/credentials
  chmod 600 /mnt/mailserver/root/credentials
fi
ln -s /mnt/mailserver/root/credentials /root/credentials
# root-only folders and files stay root-only (checked at every boot)
chmod 700 /mnt/mailserver/root /mnt/mailserver/backup
chmod 600 /mnt/mailserver/root/credentials
# secrets our config files need, so any release can rebuild them (built once on installs made before the file existed)
/usr/local/sbin/secrets init
#
# Starting MariaDB. The data live on EFS; the package's config stays on the instance (/etc/my.cnf.d), with
# our settings in flashlight.cnf (rewritten at every boot) and the admin's in custom.cnf on EFS, read last.
if [ ! -f $flag ]; then
  mv /var/lib/mysql /mnt/mailserver
fi
rm -rf /var/lib/mysql
ln -s /mnt/mailserver/mysql /var/lib/mysql
# all clients are local (unix socket), so don't listen on the network. log_warnings 1 instead of MariaDB's
# default 2: Postfix's proxymap ends its database connections without a goodbye when it exits (after 100
# clients, as every Postfix process), and level 2 logs each of them as "Aborted connection" (dozens an hour
# under load). Real errors and warnings are still logged; set 2 in custom.cnf to see these again.
printf '%s\n' "# Flashlight's MariaDB settings. DON'T EDIT: rewritten at every boot from the Flashlight release." \
  "# Your own settings go to /mnt/mailserver/etc/mariadb/custom.cnf (zz-custom.cnf here, read last)." \
  "[mysqld]" "bind-address = 127.0.0.1" "log_warnings = 1" > /etc/my.cnf.d/flashlight.cnf
custom_file /mnt/mailserver/etc/mariadb/custom.cnf \
  "# Your MariaDB settings. MariaDB reads this file last (as /etc/my.cnf.d/zz-custom.cnf), so the values set" \
  "# here win; Flashlight upgrades never change this file. Restart MariaDB after editing it. Example:" \
  "#   [mysqld]" "#   max_connections = 200"
ln -sf /mnt/mailserver/etc/mariadb/custom.cnf /etc/my.cnf.d/zz-custom.cnf
# v1.0 kept the whole config folder on EFS; the package's own files are used now
rm -rf /mnt/mailserver/etc/my.cnf.d
efs_unit mariadb
# (variables the package's unit uses without setting them; reported at every start)
unit_env mariadb "MYSQLD_OPTS= _WSREP_NEW_CLUSTER="
# if memory runs out anyway, the kernel stops other processes first (Rspamd and the PHP workers come back by
# themselves; without the database, logins and mail lookups fail)
printf '[Service]\nOOMScoreAdjust=-500\n' > /etc/systemd/system/mariadb.service.d/oom.conf
# the package restarts it only after a crash signal (on-abort); an exit on an error (a short EFS outage, a lost
# NFS lock) left it stopped and the server without logins
restart_unit mariadb
systemctl enable --now mariadb
#
# Data from an older Flashlight release: back up, run the migrations up to this release, restore all on a failure
/usr/local/sbin/upgrade-data run
#
# The database of the "Mail storage statistics" page of the admin site: created where missing, so new installs and
# upgrades from older releases get it alike. storage-stats fills it every night; the page reads it as the apache user
# through the unix socket (SELECT only, no password). Mail works without it, so a failure here is only a warning.
aws s3 cp s3://$BUCKET_CONFIG/storage-stats.sql /root/storage-stats.sql
mysql -u root < /root/storage-stats.sql ||
  /usr/local/sbin/instance-log WARN "storage statistics: database not set up (details in the install log)"
rm -f /root/storage-stats.sql
#
# Installing phpMyAdmin and postfixadmin (pinned releases from the config bucket)
pfa_tar=postfixadmin-v4.0.7-php74.tar.gz
pma_tar=phpMyAdmin-5.2.3-all-languages.tar.gz
if [ ! -f $flag ]; then
  cd ~
  mkdir /mnt/mailserver/www/admin
  #
  # The release tarball already contains vendor/ (no composer needed); the php74 build runs on PHP 7.4+
  aws s3 cp s3://$BUCKET_CONFIG/$pfa_tar .
  mkdir /mnt/mailserver/www/admin/padmin
  tar xzf $pfa_tar -C /mnt/mailserver/www/admin/padmin --strip-components=1 --no-same-owner
  /usr/local/sbin/upgrade-data set postfixadmin $pfa_tar
  rm $pfa_tar
  chown -R apache: /mnt/mailserver/www/admin/padmin/templates_c
  #
  aws s3 cp s3://$BUCKET_CONFIG/$pma_tar .
  mkdir /mnt/mailserver/www/admin/phpmyadmin
  tar xzf $pma_tar -C /mnt/mailserver/www/admin/phpmyadmin --strip-components=1 --no-same-owner
  /usr/local/sbin/upgrade-data set phpmyadmin $pma_tar
  rm $pma_tar
  mkdir /mnt/mailserver/www/admin/phpmyadmin/tmp
  chown -R apache: /mnt/mailserver/www/admin/phpmyadmin/tmp
  #
  # The passwords of the admin site, PostfixAdmin and the databases: in /root/credentials for the admin, and in the
  # secrets file for our configs
  secret_step generate the passwords of the admin site, PostfixAdmin and the databases
  webadmpass="$(pwgen 16 1)"
  htpasswd -bcB /mnt/mailserver/www/admin/.htpasswd admin $webadmpass
  printf "Admin web access\n   Link: https://$ADMIN_DOMAIN\n" >> /root/credentials
  printf "   login: admin\n   password: $webadmpass\n\n" >> /root/credentials
  # PostfixAdmin refuses a password with fewer than 2 digits; pwgen promises only one (1 password in 4 has fewer)
  postfixadminpassword="$(pwgen 16 1)"
  until [[ $postfixadminpassword =~ [0-9].*[0-9] ]]; do postfixadminpassword="$(pwgen 16 1)"; done
  printf "PostfixAdmin superadmin\n   Link: https://$ADMIN_DOMAIN/padmin\n" >> /root/credentials
  printf "   login: $ADMIN_EMAIL\n   password: $postfixadminpassword\n\n" >> /root/credentials
  setuppassword="$(pwgen 16 1)"
  setuphash=$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$setuppassword")
  /usr/local/sbin/secrets set padmin_setup_hash "$setuphash"
  printf "PostfixAdmin setup password\n   password: $setuppassword\n\n" >> /root/credentials
  db_postfix_password="$(pwgen 16 1)"
  /usr/local/sbin/secrets set postfix_db_password $db_postfix_password
  printf "MariaDB\n   login: postfix\n   password: $db_postfix_password\n\n" >> /root/credentials
  pmapassword="$(pwgen 16 1)"
  roundcubepassword="$(pwgen 16 1)"
  blowfishsecret="$(pwgen 32 1)"
  /usr/local/sbin/secrets set pma_db_password $pmapassword
  /usr/local/sbin/secrets set roundcube_db_password $roundcubepassword
  /usr/local/sbin/secrets set pma_blowfish_secret $blowfishsecret
  printf "MariaDB\n   login: pma\n   password: $pmapassword\n\n" >> /root/credentials
  printf "MariaDB\n   login: roundcube\n   password: $roundcubepassword\n\n" >> /root/credentials
  set -x
else
  # Existing data with an older package of an application: updated by its recipe in upgrade-data (with a backup,
  # restored on a failure), before our configs below are written into the application's folder
  /usr/local/sbin/upgrade-data app postfixadmin $pfa_tar
  /usr/local/sbin/upgrade-data app phpmyadmin $pma_tar
fi
#
# Our configs of PostfixAdmin and phpMyAdmin, rebuilt at every boot from the release with the values from the
# secrets file. Each ends by including the admin's own settings from EFS (custom.php), so those win.
# (the values are read in separate assignments, so a missing secret stops the install)
padmin_conf=/mnt/mailserver/www/admin/padmin/config.local.php
pma_conf=/mnt/mailserver/www/admin/phpmyadmin/config.inc.php
aws s3 cp s3://$BUCKET_CONFIG/config.local.php $padmin_conf
aws s3 cp s3://$BUCKET_CONFIG/config.inc.php $pma_conf
secret_step write the passwords into the PostfixAdmin and phpMyAdmin configs
padmin_db_password=$(/usr/local/sbin/secrets get postfix_db_password)
padmin_setup_hash=$(/usr/local/sbin/secrets get padmin_setup_hash)
# '|' as the sed delimiter: the bcrypt setup hash can contain '/'
sed -i "s|{database_password}|$padmin_db_password|; s|{admin_email}|$ADMIN_EMAIL|g; \
  s|{admindomain}|$ADMIN_DOMAIN|g; s|{setup_password}|$padmin_setup_hash|" $padmin_conf
pma_db_password=$(/usr/local/sbin/secrets get pma_db_password)
pma_blowfish_secret=$(/usr/local/sbin/secrets get pma_blowfish_secret)
sed -i "s/{pmapassword}/$pma_db_password/; s/{blowfish_secret}/$pma_blowfish_secret/" $pma_conf
set -x
custom_file /mnt/mailserver/etc/postfixadmin/custom.php "<?php" \
  "// Your PostfixAdmin settings. Flashlight's config.local.php includes this file at its end, so the values set" \
  "// here win; Flashlight upgrades never change this file. Example:" "//   \$CONF['page_size'] = '50';"
custom_file /mnt/mailserver/etc/phpmyadmin/custom.php "<?php" \
  "// Your phpMyAdmin settings. Flashlight's config.inc.php includes this file at its end, so the values set" \
  "// here win; Flashlight upgrades never change this file. Example:" "//   \$cfg['MaxRows'] = 100;"
# the configs hold database passwords (and so may the admin's files): readable by the web server only
chown root:apache $padmin_conf $pma_conf /mnt/mailserver/etc/postfixadmin/custom.php /mnt/mailserver/etc/phpmyadmin/custom.php
chmod 640 $padmin_conf $pma_conf /mnt/mailserver/etc/postfixadmin/custom.php /mnt/mailserver/etc/phpmyadmin/custom.php
#
# Databases and the PostfixAdmin superadmin (first install only; PostfixAdmin needs its config above for this)
if [ ! -f $flag ]; then
  mysql -u root < /mnt/mailserver/www/admin/phpmyadmin/sql/create_tables.sql
  mysql -u root -e "CREATE DATABASE postfix CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -u root -e "CREATE DATABASE roundcube CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  secret_step create the database users with their passwords
  mysql -u root -e "GRANT ALL PRIVILEGES ON postfix.* TO 'postfix'@'localhost' identified by '$db_postfix_password';"
  mysql -u root -e "GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'pma'@'localhost' identified by '$pmapassword';"
  mysql -u root -e "GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'localhost' identified by '$roundcubepassword';"
  set -x
  mysql -u root -e "FLUSH PRIVILEGES;"
  #
  # creating postfix db
  php /mnt/mailserver/www/admin/padmin/public/upgrade.php
  secret_step create the PostfixAdmin superadmin
  /mnt/mailserver/www/admin/padmin/scripts/postfixadmin-cli admin add $ADMIN_EMAIL --superadmin 1 --active 1 \
    --password $postfixadminpassword --password2 $postfixadminpassword
  set -x
fi
rm -r /var/www
ln -s /mnt/mailserver/www /var/www
#
# Mail domains of the stack that PostfixAdmin doesn't have yet are added at every boot (no limits, with the
# abuse@ and postmaster@ aliases from config.local.php). Existing domains, mailboxes and aliases are never
# changed, and domains removed from the stack stay in PostfixAdmin: deleting one would delete its mailboxes.
pfa_cli=/mnt/mailserver/www/admin/padmin/scripts/postfixadmin-cli
for domain in ${DOMAIN_NAMES//,/ }; do
  if ! $pfa_cli domain view $domain > /dev/null 2>&1; then
    $pfa_cli domain add $domain --description "added from the stack's domain list" ||
      echo "PostfixAdmin: could not add domain $domain"
  fi
done
#
# Getting SSL certificates (certbot) and preparing crontab
# Renewal runs from certbot-renew.timer (EPEL package, twice a day); the hooks below apply to it.
# Domain validation is DNS-01 through Route 53: certbot adds a temporary _acme-challenge TXT record to the
# domain's zone, waits until Route 53 has it on all its servers, and removes it after the check. No web server
# or open port is involved, so Apache keeps running during renewals.
if [ ! -f $flag ]; then
  # CERT_MODE=staging (stack parameter) uses the Let's Encrypt test CA: untrusted certs, no production rate limits
  certbot_test=""
  [ "$CERT_MODE" = 'staging' ] && certbot_test="--test-cert"
  # RSA: understood by every mail server and client, including old ones
  certbot certonly --dns-route53 $certbot_test --key-type rsa -d $MAIL_DOMAIN,$ADMIN_DOMAIN -m $ADMIN_EMAIL \
    --agree-tos --non-interactive
  mv /etc/letsencrypt /mnt/mailserver/etc
  # no cron mail: jobs write their own logs to /mnt/mailserver/log (our jobs are added below, at every boot)
  sed -i 's/^MAILTO=.*/MAILTO=""/' /etc/crontab
  mv /etc/crontab /mnt/mailserver/etc
fi
rm -f /etc/crontab
efs_unit crond
ln -s /mnt/mailserver/etc/crontab /etc/crontab
# the local cron files (hourly runner, anacron daily/weekly jobs) don't send mail either
sed -i 's/^MAILTO=.*/MAILTO=""/' /etc/cron.d/0hourly /etc/anacrontab
rm -rf /etc/letsencrypt
ln -s /mnt/mailserver/etc/letsencrypt /etc/letsencrypt
# only when a new certificate was actually issued: services reload it, connections stay up (written at every boot)
printf '#!/bin/bash\nsystemctl try-reload-or-restart postfix dovecot httpd\n' > /etc/letsencrypt/renewal-hooks/deploy/srv-reload
# (a variable the package's renewal unit uses, but its /etc/sysconfig/certbot doesn't set; reported at every run)
unit_env certbot-renew "RENEW_HOOK="
chmod 744 /etc/letsencrypt/renewal-hooks/deploy/srv-reload
# CertificateMode can be switched from staging to production with a stack update: the next instance replaces
# the test certificate on EFS with a trusted one (same names and key type; renewals then use production too).
# If that fails (e.g. Let's Encrypt limits), the server keeps working on the test certificate.
if [ "$CERT_MODE" = 'production' ] && \
   openssl x509 -in /etc/letsencrypt/live/$MAIL_DOMAIN/cert.pem -noout -issuer | grep -q STAGING; then
  if certbot certonly --dns-route53 --key-type rsa -d $MAIL_DOMAIN,$ADMIN_DOMAIN -m $ADMIN_EMAIL \
       --cert-name $MAIL_DOMAIN --force-renewal --agree-tos --non-interactive; then
    /usr/local/sbin/instance-log CERT "test certificate replaced with a trusted one (CertificateMode=production)"
  else
    /usr/local/sbin/instance-log CERT "trusted certificate NOT issued, keeping the test one (details in the install log)"
  fi
fi
#
# Spot instances: on the interruption notice and on the weekly price check the instance stops its
# services and asks the ASG to replace it (replace-instance); events go to /mnt/mailserver/log/instance.log
for tool in replace-instance rebuild-check mailbox-cleanup db-backup outbound-alert valkey-check storage-stats; do
  aws s3 cp s3://$BUCKET_CONFIG/$tool /mnt/mailserver/automation/
  chmod 700 /mnt/mailserver/automation/$tool
done
if [ "$INSTANCE_LIFECYCLE" = 'Spot' ]; then
  for tool in spot-instance-shutdown spotprices.py; do
    aws s3 cp s3://$BUCKET_CONFIG/$tool /mnt/mailserver/automation/
    chmod 700 /mnt/mailserver/automation/$tool
  done
  aws s3 cp s3://$BUCKET_CONFIG/autoshutdown.service /etc/systemd/system
  systemctl enable autoshutdown
fi
#
# Our cron jobs: one block between markers, rewritten at every boot, so a new release or a stack update
# changes them. Lines outside the block are the admin's and stay as they are.
crontab=/mnt/mailserver/etc/crontab
{
  # everything outside our block, without our jobs from the time before the block existed
  awk '/^# Flashlight begin/ {skip=1} !skip {print} /^# Flashlight end/ {skip=0}' $crontab |
    grep -vE 'cron-boot-runner|/mnt/mailserver/automation/(db-backup|mailbox-cleanup|spotprices\.py|rebuild-check)' || true
  echo '# Flashlight begin: our jobs, rewritten at every boot (add your own jobs outside this block)'
  echo 'MAILTO=""'
  # one-time jobs after the final reboot of an install (READY check)
  echo '@reboot         root /usr/bin/cron-boot-runner'
  # database backups, kept 28 days
  echo '55  22  *  *  * root /mnt/mailserver/automation/db-backup'
  # mailboxes deleted in PostfixAdmin: their mail goes to the trash, kept 30 days
  echo '*/10 *  *  *  * root /mnt/mailserver/automation/mailbox-cleanup'
  # spot instances: weekly price check, Saturday -> Sunday night
  [ "$INSTANCE_LIFECYCLE" = 'Spot' ] && echo '15   1  *  *  0 root /mnt/mailserver/automation/spotprices.py'
  # scheduled rebuild (stack parameter RebuildAfterDays, 0 = off), two hours after the price check
  [ "$REBUILD_AFTER_DAYS" -gt 0 ] && echo "15   3  *  *  0 root /mnt/mailserver/automation/rebuild-check $REBUILD_AFTER_DAYS"
  # spam filter: warns the admin about mailboxes that may have been taken over (sending limits, outgoing spam)
  [ "$ANTISPAM" = 'ENABLED' ] && echo "*/10 *  *  *  * root /mnt/mailserver/automation/outbound-alert $ADMIN_EMAIL $(echo "$DOMAIN_NAMES" | cut -d',' -f 1) $ADMIN_DOMAIN"
  # spam filter: a WARN line in instance.log while its data in Valkey take more than 85% of the memory cap
  [ "$ANTISPAM" = 'ENABLED' ] && echo '40   5  *  *  * root /mnt/mailserver/automation/valkey-check'
  # the night's snapshot for the admin site's "Mail storage statistics" page (an hour after the scheduled rebuild)
  echo "15   4  *  *  * root /mnt/mailserver/automation/storage-stats $MAIL_STORAGE $AWS_REGION"
  echo '# Flashlight end'
} > $crontab.new
mv $crontab.new $crontab
#
# Double instance service protection
aws s3 cp s3://$BUCKET_CONFIG/double-inst-prot.service /etc/systemd/system
aws s3 cp s3://$BUCKET_CONFIG/services-shutdown /usr/bin
chmod 700 /usr/bin/services-shutdown
systemctl enable double-inst-prot
#
# Configuring postfix. The package's own files stay in /etc/postfix on the instance (dynamicmaps.cf, for one,
# registers the lmdb and mysql table types); our main.cf, master.cf and database lookups come from the release at
# every boot. The admin's own main.cf settings live on EFS in main.local.cf and are applied over ours.
# The mail queue and the DKIM keys stay on EFS.
cd ~
aws s3 cp s3://$BUCKET_CONFIG/main.cf /etc/postfix
aws s3 cp s3://$BUCKET_CONFIG/master.cf /etc/postfix
# milters: the Rspamd spam check first (stack parameter Antispam), then the OpenDKIM signature
milters="inet:127.0.0.1:8891"
[ "$ANTISPAM" = 'ENABLED' ] && milters="inet:127.0.0.1:11332, $milters"
sed -i "s/{MainDomain}/$(echo "$DOMAIN_NAMES" | cut -d',' -f 1)/; s/{MailDomain}/$MAIL_DOMAIN/; \
  s/{SmtpdMilters}/$milters/" /etc/postfix/main.cf
# lookups in the PostfixAdmin database; the files hold its password: root and the postfix group only
# (the password is read in a separate assignment, so a missing secret stops the install)
mkdir -p /etc/postfix/mysql
for map in virtual_mailbox_domains virtual_mailbox_maps virtual_alias_domain_mailbox_maps virtual_alias_maps \
    virtual_alias_domain_maps virtual_alias_domain_catchall_maps relay_domains sender_login_maps; do
  aws s3 cp s3://$BUCKET_CONFIG/$map.cf /etc/postfix/mysql/
done
secret_step write the database password into the Postfix lookups
postfix_db_password=$(/usr/local/sbin/secrets get postfix_db_password)
sed -i "s/{database_password}/$postfix_db_password/" /etc/postfix/mysql/*.cf
set -x
chown root:postfix /etc/postfix/mysql/*.cf
chmod 640 /etc/postfix/mysql/*.cf
# the admin's own settings, applied over ours one by one (a continuation line, starting with a space, belongs
# to the setting above it); a setting postconf rejects is reported and skipped
custom_file /mnt/mailserver/etc/postfix/main.local.cf \
  "# Your Postfix settings, in main.cf format. At every boot each setting here is applied over Flashlight's" \
  "# /etc/postfix/main.cf with \"postconf -e\" (it replaces ours or is added), so the values set here win;" \
  "# Flashlight upgrades never change this file. To apply a change now: rerun the same postconf -e line, then" \
  "# \"systemctl reload postfix\". Example:" "#   message_size_limit = 31457280"
awk '/^[[:space:]]*(#|$)/ {next} /^[[:space:]]/ {setting = setting " " $0; next}
     {if (setting != "") print setting; setting = $0} END {if (setting != "") print setting}' \
  /mnt/mailserver/etc/postfix/main.local.cf |
  while IFS= read -r setting; do
    postconf -e "$setting" || echo "main.local.cf: postconf rejected: $setting"
  done
# DKIM keys and OpenDKIM's config stay on EFS in /mnt/mailserver/etc/postfix/dkim (see the DKIM part below),
# used by that path everywhere: a link to it in /etc/postfix makes Postfix warn about the link's permissions
# v1.0 kept all of /etc/postfix on EFS: only the DKIM folder and the admin's file stay there now
find /mnt/mailserver/etc/postfix -mindepth 1 -maxdepth 1 ! -name dkim ! -name main.local.cf -exec rm -rf {} +
# the mail queue lives on EFS
if [ ! -f $flag ]; then
  mv /var/spool/postfix /mnt/mailserver/spool
fi
rm -rf /var/spool/postfix
ln -s /mnt/mailserver/spool/postfix /var/spool/postfix
efs_unit postfix
restart_unit postfix
# its lookups go to the PostfixAdmin database; with the spam filter it also waits for Rspamd (and Rspamd for the
# virus scanner), so mail isn't taken before it can be checked. Ordering only: if Rspamd fails, Postfix still starts
postfix_after="mariadb.service"
[ "$ANTISPAM" = 'ENABLED' ] && postfix_after="$postfix_after rspamd.service"
start_after postfix $postfix_after
systemctl enable postfix
#
# Configuring dovecot. Our dovecot.conf and dovecot-mysql.conf come from the release at every boot (the package's
# own config isn't used); the admin's own settings live on EFS in custom.conf, included at the end of ours.
# (/etc/dovecot is the package's folder, or a link to EFS on a v1.0 install: replace it, don't write through it)
rm -rf /etc/dovecot
mkdir /etc/dovecot
aws s3 cp s3://$BUCKET_CONFIG/dovecot.conf /etc/dovecot
# DH parameters for ssl_dh: the standard ffdhe2048 group (written out at once, nothing is computed)
openssl genpkey -genparam -algorithm DH -pkeyopt group:ffdhe2048 -out /etc/dovecot/dh.pem
# Mail that Rspamd marked as spam goes to the Junk folder; "stop" also keeps the user's own filters (vacation
# replies, for one) away from it. Without Antispam no message is marked, and the script does nothing.
mkdir /etc/dovecot/sieve
cat > /etc/dovecot/sieve/spam-to-junk.sieve <<'EOF'
require ["fileinto", "mailbox"];
if header :is "X-Spam" "Yes" {
  fileinto :create "Junk";
  stop;
}
EOF
# compiled now: Dovecot delivers as vmail, which can't write the compiled script next to it. An empty config:
# compiling needs no users or mail folders (with ours, sievec looks up root in the not yet configured userdb)
sievec -c /dev/null /etc/dovecot/sieve/spam-to-junk.sieve
aws s3 cp s3://$BUCKET_CONFIG/dovecot-mysql.conf /etc/dovecot
imap_sieve=""
[ "$ANTISPAM" = 'ENABLED' ] && imap_sieve=" imap_sieve"
# IMAP connections the memory holds: ~2 MB each (1.5-1.6 MB measured in load tests), after the services (about
# 1.5 GB, 2.5 GB with ClamAV; its second copy while loading new signatures goes to swap) and 512 MB left for the
# page cache. Never below Dovecot's default of 1024: 2-4 GB servers keep it (too many connections there means
# swapping, which is better than refused mail programs); 8 GB with ClamAV gets ~2350, 16 GB ~6350.
services_mb=1536
[ "$ANTIVIRUS" = 'ENABLED' ] && services_mb=2560
imap_limit=$(( (mem_mb - services_mb - 512) / 2 ))
[ $imap_limit -lt 1024 ] && imap_limit=1024
sed -i "s/{MainDomain}/$(echo "$DOMAIN_NAMES" | cut -d',' -f 1)/; s/{MailDomain}/$MAIL_DOMAIN/; s/{ImapSievePlugin}/$imap_sieve/" \
  /etc/dovecot/dovecot.conf
sed -i "s/{ImapProcessLimit}/$imap_limit/; s/{ServiceClientLimit}/$(( imap_limit + 1000 ))/g" /etc/dovecot/dovecot.conf
# (a separate assignment, so a missing secret stops the install instead of leaving an empty password)
secret_step write the database password into the Dovecot lookups
postfix_db_password=$(/usr/local/sbin/secrets get postfix_db_password)
sed -i "s/{database_password}/$postfix_db_password/" /etc/dovecot/dovecot-mysql.conf
set -x
# the lookup file holds the database password: root and Dovecot only
chown root:dovecot /etc/dovecot/dovecot-mysql.conf
chmod 640 /etc/dovecot/dovecot-mysql.conf
# v1.0 kept our two files on EFS; they are rewritten on the instance now
rm -f /mnt/mailserver/etc/dovecot/dovecot.conf /mnt/mailserver/etc/dovecot/dovecot-mysql.conf
custom_file /mnt/mailserver/etc/dovecot/custom.conf \
  "# Your Dovecot settings. Flashlight's /etc/dovecot/dovecot.conf includes this file at its end, so the values" \
  "# set here win; Flashlight upgrades never change this file. Reload Dovecot after editing (systemctl reload" \
  "# dovecot). Example:" "#   protocol imap {" "#     mail_max_userip_connections = 50" "#   }"
efs_unit dovecot
restart_unit dovecot
# logins are checked against the PostfixAdmin database
start_after dovecot mariadb.service
systemctl enable dovecot
#
# Installing Roundcube (webmail) with the optional Larry skin (users pick it in their settings)
rc_tar=roundcubemail-1.7.7-complete.tar.gz
larry_tar=roundcube-larry-03ccd35.tar.gz
if [ ! -f $flag ]; then
  cd ~
  aws s3 cp s3://$BUCKET_CONFIG/$rc_tar .
  aws s3 cp s3://$BUCKET_CONFIG/$larry_tar .
  mkdir /var/www/webmail
  tar xzf $rc_tar -C /var/www/webmail --strip-components=1 --no-same-owner
  /usr/local/sbin/upgrade-data set roundcube $rc_tar
  mkdir /var/www/webmail/skins/larry
  tar xzf $larry_tar -C /var/www/webmail/skins/larry --strip-components=1 --no-same-owner
  /usr/local/sbin/upgrade-data set larry $larry_tar
  rm $rc_tar $larry_tar
  # the web installer isn't needed: the database and the config are prepared here
  rm -rf /var/www/webmail/installer /var/www/webmail/public_html/installer.php
  chown -R apache: /var/www/webmail/temp /var/www/webmail/logs
  secret_step generate the Roundcube encryption key
  /usr/local/sbin/secrets set roundcube_des_key "$(pwgen 32 1)"
  set -x
  mysql roundcube < /var/www/webmail/SQL/mysql.initial.sql
else
  # an older package on existing data: updated by its recipe in upgrade-data, as PostfixAdmin above
  /usr/local/sbin/upgrade-data app roundcube $rc_tar
  /usr/local/sbin/upgrade-data app larry $larry_tar
fi
# Our Roundcube config, rebuilt at every boot from the release with the values from the secrets file; it ends by
# including the admin's own settings from EFS (custom.inc.php), so those win
rc_conf=/var/www/webmail/config/config.inc.php
aws s3 cp s3://$BUCKET_CONFIG/config.inc.php.rc $rc_conf
rc_antispam=""
[ "$ANTISPAM" = 'ENABLED' ] && rc_antispam=", 'markasjunk'"
secret_step write the database password and the encryption key into the Roundcube config
rc_db_password=$(/usr/local/sbin/secrets get roundcube_db_password)
rc_des_key=$(/usr/local/sbin/secrets get roundcube_des_key)
sed -i "s|{des_key}|$rc_des_key|; s|{RoundcubePassword}|$rc_db_password|; s|{AntispamPlugins}|$rc_antispam|" $rc_conf
set -x
custom_file /mnt/mailserver/etc/roundcube/custom.inc.php "<?php" \
  "// Your Roundcube settings. Flashlight's config/config.inc.php includes this file at its end, so the values set" \
  "// here win; Flashlight upgrades never change this file. Example:" "//   \$config['product_name'] = 'My Mail';"
# the config holds the database password (and so may the admin's file): readable by the web server only
chown root:apache $rc_conf /mnt/mailserver/etc/roundcube/custom.inc.php
chmod 640 $rc_conf /mnt/mailserver/etc/roundcube/custom.inc.php
# Roundcube's logs on EFS (errors.log, sendmail.log ...) are rotated weekly by the system's logrotate and kept
# 13 weeks, like the other logs. Roundcube opens the file for every line, so it needs no reload; fail2ban follows
# the rotated errors.log by itself.
cat > /etc/logrotate.d/roundcube <<'EOF'
# Flashlight: Roundcube logs on EFS. DON'T EDIT: rewritten at every boot from the Flashlight release.
/mnt/mailserver/www/webmail/logs/*.log {
    su apache apache
    weekly
    rotate 13
    compress
    delaycompress
    missingok
    notifempty
    create 640 apache apache
}
EOF
#
# PHP settings, rewritten at every boot (the package's php.ini stays untouched):
# time zone, and attachments up to the 25 MB message limit of Postfix (an 18 MB file is about 25 MB once encoded)
cat > /etc/php.d/99-flashlight.ini <<EOF
date.timezone = $TIMEZONE
upload_max_filesize = 18M
post_max_size = 25M
EOF
#
# MariaDB root password and daily database backups.
# A fresh MariaDB 10.11 has no anonymous users or test database, so only root needs a password (for phpMyAdmin);
# root on the server itself (shell, db-backup) keeps logging in through the unix socket without one.
if [ ! -f $flag ]; then
  secret_step set the MariaDB root password
  db_root_password="$(pwgen 16 1)"
  printf "MariaDB\n   Link: https://$ADMIN_DOMAIN/myadmin\n" >> /root/credentials
  printf "   login: root\n   password: $db_root_password\n\n" >> /root/credentials
  mysql -u root -e "ALTER USER root@localhost IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$db_root_password');"
  set -x
fi
#
# Configuring Apache. The package's own config (httpd.conf, ssl.conf, modules) stays on the instance, so it
# always matches the installed Apache. Our sites (sites.conf) come from the release at every boot; the admin's
# own settings live on EFS in custom.conf (global, read after ours) and custom-mail.conf / custom-admin.conf
# (included inside our webmail and administration sites).
# (a v1.0 install has a link to EFS here: replace it, don't write through it)
rm -f /etc/httpd/conf.d/sites.conf
aws s3 cp s3://$BUCKET_CONFIG/sites.conf /etc/httpd/conf.d/sites.conf
sed -i "s/{AdminEmail}/$ADMIN_EMAIL/g; s/{AdminDomain}/$ADMIN_DOMAIN/g; s/{MailDomain}/$MAIL_DOMAIN/g" \
  /etc/httpd/conf.d/sites.conf
# The admin site's start page (behind the site password): links to the admin tools, Rspamd only with Antispam.
# Without it, the bare address shows Apache's test page.
aws s3 cp s3://$BUCKET_CONFIG/admin-index.html /var/www/admin/index.html
sed -i "s/{MailDomain}/$MAIL_DOMAIN/g; s/{Version}/$(/usr/local/sbin/upgrade-data release)/g" /var/www/admin/index.html
[ "$ANTISPAM" = 'ENABLED' ] || sed -i '/<!-- rspamd -->/,/<!-- \/rspamd -->/d' /var/www/admin/index.html
chmod 644 /var/www/admin/index.html
# the admin site's icon in the browser tab (also served for /favicon.ico, sites.conf)
aws s3 cp s3://$BUCKET_CONFIG/favicon.svg /var/www/admin/favicon.svg
chmod 644 /var/www/admin/favicon.svg
# the "Mail storage statistics" page (reads the flashlight database that storage-stats fills every night)
mkdir -p /var/www/admin/storage_stats
aws s3 cp s3://$BUCKET_CONFIG/storage-stats.php /var/www/admin/storage_stats/index.php
sed -i "s/{MailDomain}/$MAIL_DOMAIN/g; s/{Version}/$(/usr/local/sbin/upgrade-data release)/g" \
  /var/www/admin/storage_stats/index.php
chmod 644 /var/www/admin/storage_stats/index.php
# the admin's thresholds for the page's amber marks: created once, read by the page (apache), written by root only
custom_file /mnt/mailserver/etc/storage-stats/custom.ini \
  "; Your thresholds for the amber marks of the Mail storage statistics page (admin site, /storage_stats/)." \
  "; The page reads this file at every visit; Flashlight upgrades never change it." \
  "; Remove the \";\" in front of a line to change its value (whole numbers above 0)." "" \
  "; more unread messages in the Inbox than this" ";unread_max = 400" \
  "; unread messages in the Inbox grown by more than this in 30 days" ";unread_growth = 200" \
  "; more of the quota used than this, in percent" ";quota_full = 90"
chown root:apache /mnt/mailserver/etc/storage-stats/custom.ini
chmod 640 /mnt/mailserver/etc/storage-stats/custom.ini
# a self-signed certificate for "localhost", for the catch-all HTTPS site of sites.conf that refuses requests to
# other names (with our real certificate, Apache warns that it doesn't match "localhost")
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=localhost -addext subjectAltName=DNS:localhost \
  -addext basicConstraints=critical,CA:FALSE \
  -keyout /etc/pki/tls/private/flashlight-localhost.key -out /etc/pki/tls/certs/flashlight-localhost.crt
chmod 600 /etc/pki/tls/private/flashlight-localhost.key
custom_file /mnt/mailserver/etc/httpd/custom.conf \
  "# Your Apache settings: global ones, or your own sites. Apache reads this file after Flashlight's" \
  "# /etc/httpd/conf.d/sites.conf (as zz-custom.conf); Flashlight upgrades never change this file." \
  "# Settings for the webmail or the administration site go to custom-mail.conf / custom-admin.conf." \
  "# Reload Apache after editing (apachectl configtest && systemctl reload httpd). Example:" \
  "#   Timeout 120"
custom_file /mnt/mailserver/etc/httpd/custom-mail.conf \
  "# Your settings inside the webmail site (https://$MAIL_DOMAIN), included at the end of it." \
  "# Flashlight upgrades never change this file. Reload Apache after editing. Example:" \
  "#   Header always set Referrer-Policy \"same-origin\""
custom_file /mnt/mailserver/etc/httpd/custom-admin.conf \
  "# Your settings inside the administration site (https://$ADMIN_DOMAIN), included at the end of it." \
  "# Flashlight upgrades never change this file. Reload Apache after editing." \
  "# Example, the site password and your own addresses only:" \
  "#   <Location \"/\">" "#     <RequireAll>" "#       Require valid-user" "#       Require ip 203.0.113.0/24" \
  "#     </RequireAll>" "#   </Location>"
ln -sf /mnt/mailserver/etc/httpd/custom.conf /etc/httpd/conf.d/zz-custom.conf
# v1.0 kept our sites.conf on EFS; it is rewritten on the instance now
rm -f /mnt/mailserver/etc/httpd/sites.conf
# the package's httpd.conf needs its DocumentRoot to exist (/var/www is on EFS); nothing is served from it
mkdir -p /var/www/html
# the package loads every load balancer method (00-proxy.conf), but no balancer is used here (only proxy_fcgi to
# PHP-FPM and proxy_http to the Rspamd web interface); without mod_heartmonitor, the heartbeat method logs
# "AH02282: No slotmem from mod_heartmonitor" at every start
sed -i 's/^LoadModule lbmethod_heartbeat_module/#&/' /etc/httpd/conf.modules.d/00-proxy.conf
#
# PHP-FPM pool sized by memory (local file, rewritten at every boot): about 10 PHP processes per 2 GB
# (the package default of up to 50 could run a small server out of memory); processes are started
# on demand and exit when idle instead of being kept running
php_children=$(awk '/^MemTotal/ {n = int($2 / 1024 / 200); print (n < 5 ? 5 : n)}' /proc/meminfo)
sed -i "s/^pm = .*/pm = ondemand/; s/^pm.max_children = .*/pm.max_children = $php_children/" /etc/php-fpm.d/www.conf
efs_unit httpd
efs_unit php-fpm
restart_unit httpd
restart_unit php-fpm
unit_env httpd "OPTIONS="
# the web applications use the database; Apache passes their requests to PHP-FPM
start_after php-fpm mariadb.service
start_after httpd php-fpm.service
systemctl enable httpd
#
# DKIM, SPF and DMARC. Run at every boot, so the server follows the stack's domain list:
# keys of removed domains are deleted, new domains get a key, and the DNS records are brought up to date.
dkim=/mnt/mailserver/etc/postfix/dkim
mkdir -p $dkim
# our OpenDKIM config, rewritten at every boot from the release (it stays next to the keys)
aws s3 cp s3://$BUCKET_CONFIG/opendkim.conf $dkim
# sign and verify; sign only when Rspamd verifies incoming mail (see opendkim.conf)
dkim_mode=sv
[ "$ANTISPAM" = 'ENABLED' ] && dkim_mode=s
sed -i "s/{Mode}/$dkim_mode/" $dkim/opendkim.conf
IFS=',' read -ra domains <<< "$DOMAIN_NAMES"
# without a domain list every key would look unused: keep them all and stop
[ ${#domains[@]} -gt 0 ] || { echo "base.sh: no mail domains, DKIM keys left as they are"; exit 1; }
for dir in $(find $dkim -mindepth 1 -maxdepth 1 -type d -printf '%f\n'); do
  [[ " ${domains[*]} " == *" $dir "* ]] || rm -r "$dkim/$dir"
done
: > $dkim/keytable
: > $dkim/signingtable
for domain in "${domains[@]}"; do
  if [ ! -d $dkim/$domain ]; then
    mkdir $dkim/$domain
    opendkim-genkey -b 2048 -D $dkim/$domain -d $domain -s mail
  fi
  echo "mail._domainkey.$domain $domain:mail:$dkim/$domain/mail.private" >> $dkim/keytable
  echo "*@$domain mail._domainkey.$domain" >> $dkim/signingtable
done
# the private keys are readable by OpenDKIM only
chown -R root:opendkim $dkim
find $dkim -type d -exec chmod 750 {} +
find $dkim -type f -exec chmod 640 {} +
aws s3 cp s3://$BUCKET_CONFIG/dnsupd.py /usr/local/sbin/dnsupd.py --quiet
chmod 700 /usr/local/sbin/dnsupd.py
/usr/local/sbin/dnsupd.py "$DOMAIN_NAMES" "$DOMAIN_ZONE_IDS" "$EIP" "$MAIL_DOMAIN"
# OpenDKIM reads our config on EFS (local file, rewritten at every boot)
echo "OPTIONS=\"-x $dkim/opendkim.conf\"" > /etc/sysconfig/opendkim
efs_unit opendkim
systemctl enable opendkim
#
# The virus scanner's signature database (see Antivirus below) is downloaded data only: without the scanner it
# doesn't stay on EFS (enabling it again downloads it again, about a minute). Antivirus needs Antispam (the template
# checks), so this runs outside the spam filter part, also when the spam filter is off.
[ "$ANTIVIRUS" = 'ENABLED' ] || rm -rf /mnt/mailserver/clamav
#
# Spam filtering (stack parameter Antispam): Rspamd checks incoming mail as the first Postfix milter (main.cf);
# spam gets an "X-Spam: Yes" header and goes to Junk (Dovecot's sieve_before), obvious spam is rejected. Valkey
# (Redis) keeps what Rspamd learns, on EFS; Unbound is Rspamd's own DNS resolver (blocklists refuse queries that
# come through the big shared resolvers, AWS's included). Our settings in /etc/rspamd/local.d are rewritten at
# every boot; the admin's own live on EFS in /mnt/mailserver/etc/rspamd/override.d.
if [ "$ANTISPAM" = 'ENABLED' ]; then
  # Rspamd (it isn't in AlmaLinux or EPEL): the exact package that comes with this Flashlight release, installed
  # after a check of its signature with the Rspamd signing key of the release; its dependencies come from AlmaLinux
  # and EPEL. Rspamd's own repository isn't used: it keeps only its newest package, its bug-fix releases have
  # changed what Flashlight relies on (the 4.3.0 package didn't create Rspamd's user, 4.3.1 moved the settings of
  # the web interface), and it is a single slow server. A newer Rspamd comes with a Flashlight release, after testing.
  rspamd_rpm=rspamd-4.3.1-1.el10.x86_64.rpm
  aws s3 cp s3://$BUCKET_CONFIG/rspamd.asc /etc/pki/rpm-gpg/RPM-GPG-KEY-rspamd
  rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-rspamd
  dnf install -y valkey unbound
  aws s3 cp s3://$BUCKET_CONFIG/$rspamd_rpm /root/
  rpm -K /root/$rspamd_rpm | grep -q 'digests signatures OK'
  dnf install -y /root/$rspamd_rpm
  rm /root/$rspamd_rpm
  #
  # Valkey: data on EFS, so learned spam survives instance replacements. The valkey user's ID may differ on each
  # new instance, hence the chown at every boot.
  install -d -m 750 /mnt/mailserver/valkey
  chown -R valkey:valkey /mnt/mailserver/valkey
  sed -i 's|^dir .*|dir /mnt/mailserver/valkey|' /etc/valkey/valkey.conf
  # IPv4 only: IPv6 is off, and the package's optional ::1 logs a bind warning at every start
  sed -i 's|^bind .*|bind 127.0.0.1|' /etc/valkey/valkey.conf
  # Memory cap. At the cap Valkey drops first the keys that expire soonest (volatile-ttl); keys without an expiry
  # are never dropped. Expiring: rate limit counters, caches, and Bayes words that are rare or common
  # to spam and ham (bayes_expiry, see classifier-bayes.conf below); without an expiry: the Bayes words that
  # clearly mark spam or ham, and the Bayes counters. valkey-check warns at 85% of the cap.
  printf '%s\n' "# Flashlight: memory cap; at the cap the keys that expire soonest go first" "maxmemory 256mb" \
    "maxmemory-policy volatile-ttl" "# written to disk at most 5 minutes after a change, and when it stops" \
    "save 300 1 60 10000" >> /etc/valkey/valkey.conf
  #
  # Our Rspamd settings (local.d is merged into Rspamd's defaults)
  rspamd_conf() {
    local file=/etc/rspamd/local.d/$1
    shift
    printf '%s\n' "# Flashlight's Rspamd settings. DON'T EDIT: rewritten at every boot from the Flashlight release." \
      "# Your own settings go to /mnt/mailserver/etc/rspamd/override.d (see the README there)." "$@" > $file
  }
  # (task_timeout: the most one message's checks may take, so a slow answer, of a virus scanner on a big attachment
  # say, isn't cut off; a usual message takes milliseconds. The settings changed in the web interface, the
  # statistics and the graphs live on EFS, so they survive instance replacements.)
  rspamd_conf options.inc 'dns { nameserver = ["127.0.0.1:53"]; }' "task_timeout = 60s;" \
    'dynamic_conf = "/mnt/mailserver/rspamd/rspamd_dynamic";' 'rrd = "/mnt/mailserver/rspamd/rspamd.rrd";' \
    'stats_file = "/mnt/mailserver/rspamd/stats.ucl";'
  # The settings changed in the web interface (dynconf, from Rspamd 4.3.1; its default file is on the instance's
  # disk). The older file above (dynamic_conf) is imported into it once and renamed to rspamd_dynamic.imported.
  rspamd_conf dynconf.conf 'path = "/mnt/mailserver/rspamd/rspamd_dynconf.json";'
  rspamd_conf redis.conf 'servers = "127.0.0.1:6379";'
  # no greylisting: it delays legitimate mail by minutes or hours (the sender retries later)
  rspamd_conf actions.conf "reject = 15;" "add_header = 6;" "greylist = null;"
  rspamd_conf greylist.conf "enabled = false;"
  # Mail sent by logged-in users: 30 messages an hour and 300 a day per user. Each is a bucket: 30 (300) messages
  # can go in a row, then it refills at that rate, so the first hour allows about 60 and the first day 600 (a spam bot on a stolen mailbox
  # hits this within minutes; outbound-alert tells the admin); over it, a temporary refusal. skip_recipients: count
  # messages, not recipients (those are limited per message in Postfix). The admin can change the numbers in
  # override.d/ratelimit.conf. Their mail gets no spam header: it is sent as it is, or refused from 15 points.
  rspamd_conf ratelimit.conf "rates {" "  user_hour {" '    selector = "user.lower";' \
    '    bucket = { burst = 30; rate = "30 / 1h"; skip_recipients = true; }' "  }" "  user_day {" \
    '    selector = "user.lower";' '    bucket = { burst = 300; rate = "300 / 1d"; skip_recipients = true; }' "  }" "}"
  rspamd_conf settings.conf "outbound {" "  authenticated = true;" '  apply { actions { "add header" = null; } }' "}"
  # the Bayes filter also learns by itself from mail that scores very high or very low. expire turns on
  # bayes_expiry (without it the learned words never expire). Its cycle gives a rare word 180 days; if by then the
  # word clearly marks spam or ham (seen more often than average, over 3/4 in one of them), a later cycle keeps it
  # for good, otherwise it is deleted. Words common to spam and ham go after 10 days. A shorter expire
  # takes effect by itself; a longer one needs "expire = -1" for one full expiry cycle first (Rspamd docs).
  rspamd_conf classifier-bayes.conf "autolearn = true;" "expire = 15552000;"
  rspamd_conf milter_headers.conf 'use = ["authentication-results", "x-spamd-bar"];'
  # OpenDKIM signs our mail
  rspamd_conf dkim_signing.conf "enabled = false;"
  # its workers take messages only as data over the network (Postfix sends them so), not as paths to files or
  # shared memory, which Rspamd warns is unsafe on a TCP listener
  # (the controller, with the web interface's password, is set up further down)
  rspamd_conf worker-normal.inc "allow_file_and_shm_inputs = false;"
  # (the proxy waits for a message's checks longer than task_timeout)
  rspamd_conf worker-proxy.inc "allow_file_and_shm_inputs = false;" "timeout = 120s;"
  rspamd_conf arc.conf "enabled = false;"
  # Attachments of risky file types (stack parameter AttachmentPolicy). Score: Rspamd's own rules only add points
  # (mime_types). Gmail: mail with an attachment of a type Gmail blocks is rejected, also when the file is inside an
  # archive (multimap finds it, force_actions rejects with a message to the sender), and encrypted archives or
  # archives inside archives go at least to Junk. Strict: Gmail plus more Windows code types from Outlook's list.
  # The lists come with the release (attachments-*.map, sources in their headers).
  rm -f /etc/rspamd/local.d/multimap.conf /etc/rspamd/local.d/force_actions.conf /etc/rspamd/local.d/maps.d/attachments-*.map
  if [ "$ATTACHMENT_POLICY" != 'Score' ]; then
    mkdir -p /etc/rspamd/local.d/maps.d
    lists="gmail"
    [ "$ATTACHMENT_POLICY" = 'Strict' ] && lists="gmail strict"
    maps=""
    for list in $lists; do
      aws s3 cp s3://$BUCKET_CONFIG/attachments-$list.map /etc/rspamd/local.d/maps.d/
      maps="$maps${maps:+, }\"/etc/rspamd/local.d/maps.d/attachments-$list.map\""
    done
    rspamd_conf multimap.conf "BLOCKED_ATTACHMENT {" '  type = "filename";' '  filter = "extension";' \
      "  map = [$maps];" "  skip_archives = false;" "  score = 10.0;" \
      '  description = "Attachment of a blocked file type (stack parameter AttachmentPolicy)";' "}"
    rspamd_conf force_actions.conf "rules {" "  BLOCKED_ATTACHMENT_REJECT {" '    action = "reject";' \
      '    expression = "BLOCKED_ATTACHMENT";' \
      '    message = "Attachments of this file type are not accepted here; share the file as a link instead";' \
      "  }" "  RISKY_ARCHIVE_JUNK {" '    action = "add header";' \
      '    expression = "MIME_ENCRYPTED_ARCHIVE | MIME_ARCHIVE_IN_ARCHIVE";' "    least = true;" "  }" "}"
  fi
  #
  # Macros in Office documents: oletools (not a virus scanner: it looks at what a document's macros do) through the
  # olefy service (Heinlein Support; olefy.py comes with the release). A macro that runs by itself when the document
  # is opened and does suspicious things (starts programs, writes files, Excel 4.0 macros) adds 7 points: the mail
  # goes to Junk. oletools isn't packaged for AlmaLinux: pip installs exactly the versions and files (hashes) of
  # olefy-requirements.txt into its own environment. If that fails, the server works without the macro check.
  rm -f /etc/rspamd/local.d/external_services.conf /etc/rspamd/local.d/groups.conf
  rspamd_after=""
  aws s3 cp s3://$BUCKET_CONFIG/olefy-requirements.txt /root/olefy-requirements.txt
  if python3 -m venv /opt/olefy && /opt/olefy/bin/pip install --quiet --disable-pip-version-check --require-hashes \
       --only-binary=:all: -r /root/olefy-requirements.txt; then
    aws s3 cp s3://$BUCKET_CONFIG/olefy.py /opt/olefy/olefy.py
    id olefy > /dev/null 2>&1 || useradd -r -M -d /nonexistent -s /sbin/nologin olefy
    printf '%s\n' "# Flashlight's olefy settings (written at every install)" "OLEFY_BINDADDRESS=127.0.0.1" \
      "OLEFY_BINDPORT=10050" "OLEFY_TMPDIR=/tmp" "OLEFY_PYTHON_PATH=/opt/olefy/bin/python" \
      "OLEFY_OLEVBA_PATH=/opt/olefy/bin/olevba" "OLEFY_LOGLVL=30" "OLEFY_MINLENGTH=500" "OLEFY_DEL_TMP=1" \
      "OLEFY_DEL_TMP_FAILED=1" > /etc/olefy.conf
    cat > /etc/systemd/system/olefy.service <<'EOF'
[Unit]
Description=olefy: macros in Office documents (oletools) for Rspamd
After=network.target

[Service]
Type=simple
User=olefy
Group=olefy
EnvironmentFile=/etc/olefy.conf
# (-W: a regular expression in olefy.py makes Python 3.12 warn at every start)
ExecStart=/opt/olefy/bin/python -W ignore::SyntaxWarning /opt/olefy/olefy.py
Restart=always
RestartSec=3
MemoryMax=512M
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable olefy
    rspamd_conf external_services.conf "oletools {" '  type = "oletools";' '  servers = "127.0.0.1:10050";' \
      "  extended = false;" "  timeout = 20.0;" "  max_size = 26214400;" "}"
    rspamd_conf groups.conf 'group "flashlight" {' "  symbols {" \
      '    "OLETOOLS" { weight = 7.0; description = "Office document with a macro that runs by itself and does suspicious things"; }' \
      "  }" "}"
    rspamd_after=" olefy.service"
  else
    /usr/local/sbin/instance-log WARN "oletools could not be installed (pip): mail is checked without the macro check"
  fi
  rm -f /root/olefy-requirements.txt
  #
  # Virus scanner (stack parameter Antivirus): ClamAV (EPEL) through Rspamd; a message with a virus is rejected.
  # It needs about 1 GB of memory, twice that for some seconds while it loads new signatures (a few times a day), so
  # the template allows it on medium instance types and larger. The signature database lives on EFS: a new instance
  # finds it there and only updates it, instead of downloading 100+ MB again. clamd reloads it by itself after an
  # update (SelfCheck).
  rm -f /etc/rspamd/local.d/antivirus.conf
  if [ "$ANTIVIRUS" = 'ENABLED' ]; then
    dnf install -y clamav clamd
    # (the clamupdate user's ID may differ on each new instance)
    install -d -m 755 /mnt/mailserver/clamav
    chown -R clamupdate:clamupdate /mnt/mailserver/clamav
    sed -i 's|^#\?DatabaseDirectory .*|DatabaseDirectory /mnt/mailserver/clamav|' /etc/freshclam.conf
    sed -i 's|^#\?DatabaseDirectory .*|DatabaseDirectory /mnt/mailserver/clamav|; s|^#\?TCPSocket .*|TCPSocket 3310|;
      s|^#\?TCPAddr .*|TCPAddr 127.0.0.1|' /etc/clamd.d/scan.conf
    # the database must be in place before clamd starts: up to 3 tries (freshclam exits 1 when it is up to date)
    for try in 1 2 3; do
      rc=0
      freshclam --quiet || rc=$?
      if [ $rc -le 1 ]; then break; fi
      if [ $try -eq 3 ]; then echo "base.sh: freshclam failed (exit $rc)"; exit 1; fi
      sleep 30
    done
    rspamd_conf antivirus.conf "clamav {" '  type = "clamav";' '  servers = "127.0.0.1:3310";' \
      "  scan_mime_parts = true;" '  symbol = "CLAM_VIRUS";' '  action = "reject";' \
      "  message = '\${SCANNER}: virus found: \"\${VIRUS}\"';" "  timeout = 20.0;" "  max_size = 26214400;" "}"
    efs_unit clamd@scan
    efs_unit clamav-freshclam
    # clamd needs some time to load its database. It counts as started once it answers (up to 2 minutes; the "-"
    # means a slow load doesn't fail or stop it: after 2 minutes it counts as started anyway and goes on loading),
    # so Rspamd, and Postfix after it, don't take mail it can't scan yet. Rspamd connects for every message, so it
    # uses clamd as soon as it answers, also after a slow start or a restart. A crash restarts it, at most 5 times
    # in 10 minutes (then it stays down and mail goes on without the virus scan).
    printf '%s\n' '[Unit]' 'StartLimitIntervalSec=600' 'StartLimitBurst=5' '[Service]' \
      'ExecStartPost=-/usr/bin/clamdscan --config-file=/etc/clamd.d/scan.conf --ping=120:1' 'TimeoutStartSec=420' \
      'Restart=on-failure' 'RestartSec=30' > /etc/systemd/system/clamd@scan.service.d/ready.conf
    systemctl daemon-reload
    rspamd_after="$rspamd_after clamd@scan.service"
    systemctl enable clamd@scan clamav-freshclam
  fi
  #
  # Spamhaus through DQS with the stack's key (Spamhaus refuses queries from AWS without one)
  rm -f /etc/rspamd/local.d/rbl.conf /etc/rspamd/local.d/rbl_group.conf
  if [ -n "${DQS_KEY:+set}" ]; then
    for f in rbl rbl_group; do
      aws s3 cp s3://$BUCKET_CONFIG/spamhaus-dqs-$f.conf /etc/rspamd/local.d/$f.conf
    done
    secret_step write the Spamhaus DQS key into the Rspamd config
    dqs_key=$(printf '%s' "$DQS_KEY" | sed 's/[&|\\]/\\&/g')
    sed -i "s|your_DQS_key|$dqs_key|g" /etc/rspamd/local.d/rbl.conf /etc/rspamd/local.d/rbl_group.conf
    set -x
    # the key: readable by Rspamd only
    chown root:_rspamd /etc/rspamd/local.d/rbl.conf /etc/rspamd/local.d/rbl_group.conf
    chmod 640 /etc/rspamd/local.d/rbl.conf /etc/rspamd/local.d/rbl_group.conf
  fi
  #
  # Rspamd's own data on EFS: the settings changed in its web interface, its statistics and graphs, and the
  # whitelist of partner domains the admin keeps there (the _rspamd user's ID may differ on each new instance)
  install -d -m 755 /mnt/mailserver/rspamd
  if [ ! -f /mnt/mailserver/rspamd/whitelist-domains.map ]; then
    printf '%s\n' "# Partner domains whose mail is never sent to Junk by its spam score. Mail with a virus or a blocked" \
      "# attachment is still rejected. The mail must really come from the domain: its SPF lets the sending server" \
      "# send for it, or it carries the domain's DKIM signature. One domain per line; edit it in the Rspamd web" \
      "# interface (Configuration, Lists) or here. Flashlight upgrades never change this file." \
      > /mnt/mailserver/rspamd/whitelist-domains.map
  fi
  chown -R _rspamd:_rspamd /mnt/mailserver/rspamd
  rspamd_conf whitelist.conf "rules {" "  FLASHLIGHT_WHITELIST_SPF {" "    valid_spf = true;" \
    '    domains = ["/mnt/mailserver/rspamd/whitelist-domains.map"];' "    score = -6.0;" \
    '    description = "Sender domain on the whitelist, confirmed by SPF";' "  }" "  FLASHLIGHT_WHITELIST_DKIM {" \
    "    valid_dkim = true;" '    domains = ["/mnt/mailserver/rspamd/whitelist-domains.map"];' "    score = -6.0;" \
    '    description = "Sender domain on the whitelist, confirmed by DKIM";' "  }" "}"
  #
  # The web interface: https://<admin domain>/rspamd/, behind the admin site's password and Rspamd's own (in the
  # secrets file and /root/credentials). Apache passes the browser's address on (its own copy: a browser can't
  # forge it), so Rspamd asks for the password; only requests from the server itself (Dovecot's learning) don't.
  secret_step set the password of the Rspamd web interface
  if ! rspamd_password=$(/usr/local/sbin/secrets get rspamd_password 2> /dev/null); then
    rspamd_password=$(pwgen 16 1)
    /usr/local/sbin/secrets set rspamd_password "$rspamd_password"
    printf "Rspamd web interface (spam filter)\n   Link: https://$ADMIN_DOMAIN/rspamd/\n   password: $rspamd_password\n\n" \
      >> /root/credentials
  fi
  rspamd_hash=$(rspamadm pw -p "$rspamd_password")
  rspamd_conf worker-controller.inc "allow_file_and_shm_inputs = false;" "password = \"$rspamd_hash\";" \
    "enable_password = \"$rspamd_hash\";"
  set -x
  chown root:_rspamd /etc/rspamd/local.d/worker-controller.inc
  chmod 640 /etc/rspamd/local.d/worker-controller.inc
  cat > /etc/httpd/flashlight-rspamd.conf <<'EOF'
# Flashlight: the Rspamd web interface in the admin site (included by sites.conf). DON'T EDIT: rewritten at every
# boot from the Flashlight release.
<Location "/rspamd/">
    AuthType Basic
    AuthName "Restricted Content"
    AuthUserFile /var/www/admin/.htpasswd
    Require valid-user
    # the browser's own address headers are dropped; Apache adds the real one
    RequestHeader unset X-Forwarded-For
    RequestHeader unset X-Real-IP
    ProxyPass "http://127.0.0.1:11334/"
    ProxyPassReverse "http://127.0.0.1:11334/"
</Location>
EOF
  #
  # Learning from the users: moving a message into a spam folder teaches Rspamd it is spam, moving it out of one
  # (not to a trash folder) that it isn't, from any mail program (Dovecot's imapsieve; dovecot.conf includes the
  # file below). The folders go by name, also the names other programs use (Outlook: Junk Email, Deleted Items).
  cat > /etc/dovecot/flashlight-antispam.conf <<'EOF'
# Flashlight: learning of the spam filter (included by dovecot.conf). DON'T EDIT: rewritten at every boot.
plugin {
  sieve_plugins = sieve_imapsieve sieve_extprograms
  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment
  sieve_pipe_bin_dir = /etc/dovecot/sieve/bin
  # into a spam folder (Junk, or the name another mail program uses: Spam, Junk E-mail, Outlook's Junk Email): spam
  imapsieve_mailbox1_name = Junk
  imapsieve_mailbox1_causes = COPY APPEND
  imapsieve_mailbox1_before = file:/etc/dovecot/sieve/learn-spam.sieve
  imapsieve_mailbox2_name = Spam
  imapsieve_mailbox2_causes = COPY APPEND
  imapsieve_mailbox2_before = file:/etc/dovecot/sieve/learn-spam.sieve
  imapsieve_mailbox3_name = Junk E-mail
  imapsieve_mailbox3_causes = COPY APPEND
  imapsieve_mailbox3_before = file:/etc/dovecot/sieve/learn-spam.sieve
  imapsieve_mailbox4_name = Junk Email
  imapsieve_mailbox4_causes = COPY APPEND
  imapsieve_mailbox4_before = file:/etc/dovecot/sieve/learn-spam.sieve
  # out of a spam folder: not spam (the script skips the trash and spam folders)
  imapsieve_mailbox5_name = *
  imapsieve_mailbox5_from = Junk
  imapsieve_mailbox5_causes = COPY
  imapsieve_mailbox5_before = file:/etc/dovecot/sieve/learn-ham.sieve
  imapsieve_mailbox6_name = *
  imapsieve_mailbox6_from = Spam
  imapsieve_mailbox6_causes = COPY
  imapsieve_mailbox6_before = file:/etc/dovecot/sieve/learn-ham.sieve
  imapsieve_mailbox7_name = *
  imapsieve_mailbox7_from = Junk E-mail
  imapsieve_mailbox7_causes = COPY
  imapsieve_mailbox7_before = file:/etc/dovecot/sieve/learn-ham.sieve
  imapsieve_mailbox8_name = *
  imapsieve_mailbox8_from = Junk Email
  imapsieve_mailbox8_causes = COPY
  imapsieve_mailbox8_before = file:/etc/dovecot/sieve/learn-ham.sieve
}
EOF
  mkdir -p /etc/dovecot/sieve/bin
  cat > /etc/dovecot/sieve/learn-spam.sieve <<'EOF'
require ["vnd.dovecot.pipe", "copy", "imapsieve"];
pipe :copy "rspamd-learn" ["spam"];
EOF
  cat > /etc/dovecot/sieve/learn-ham.sieve <<'EOF'
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];
if environment :matches "imap.mailbox" "*" { set "mailbox" "${1}"; }
if string :is "${mailbox}" ["Trash", "Deleted Messages", "Deleted Items", "Junk", "Spam", "Junk E-mail", "Junk Email"] { stop; }
pipe :copy "rspamd-learn" ["ham"];
EOF
  printf '%s\n' '#!/bin/sh' '# Flashlight: passes a message moved into or out of Junk to Rspamd ($1: spam or ham)' \
    'exec /usr/bin/rspamc -h 127.0.0.1:11334 "learn_$1"' > /etc/dovecot/sieve/bin/rspamd-learn
  chmod 755 /etc/dovecot/sieve/bin/rspamd-learn
  # compiled now, with just the plugins the scripts need (Dovecot can't write next to them)
  printf '%s\n' 'plugin {' '  sieve_plugins = sieve_imapsieve sieve_extprograms' \
    '  sieve_global_extensions = +vnd.dovecot.pipe +vnd.dovecot.environment' '}' > /root/sievec.conf
  for script in learn-spam learn-ham; do
    sievec -c /root/sievec.conf /etc/dovecot/sieve/$script.sieve
  done
  rm /root/sievec.conf
  #
  # The admin's own settings, on EFS
  mkdir -p /mnt/mailserver/etc/rspamd/override.d
  custom_file /mnt/mailserver/etc/rspamd/override.d/README \
    "Your Rspamd settings. Put a file here with the name Rspamd uses for the settings it holds, e.g." \
    "actions.conf, rbl.conf or multimap.conf (see https://docs.rspamd.com/configuration/). A file here REPLACES" \
    "the whole section of that name, Flashlight's settings in /etc/rspamd/local.d included, so copy ours into it" \
    "and change what you need. Flashlight upgrades never change this folder. Apply a change now with" \
    "\"rspamadm configtest && systemctl reload rspamd\"."
  rm -rf /etc/rspamd/override.d
  ln -s /mnt/mailserver/etc/rspamd/override.d /etc/rspamd/override.d
  rspamadm configtest
  efs_unit valkey
  efs_unit rspamd
  restart_unit valkey
  # the package restarts Rspamd always, but after 100 ms, so 5 quick failures stopped it for good
  restart_unit rspamd always
  # Unbound and Rspamd need the network up (Rspamd loads its lists from the internet when it starts); Rspamd also
  # uses Valkey and Unbound. Its workers listen on 127.0.0.1 ("localhost" gave each socket twice here).
  start_after unbound network-online.target
  # IPv4 only: IPv6 is off, and Unbound would try it (a warning at every start, wasted queries to IPv6 servers)
  printf '%s\n' 'server:' '    do-ip6: no' > /etc/unbound/conf.d/flashlight.conf
  # Warm-up: with an empty cache, many queries at once (Rspamd when the mail queued during a replacement arrives)
  # race to build the DNSSEC chain of trust, and a share of them fail (SERVFAIL, "validation failure ... no DS").
  # The keys (DNSKEY) of the root and of net, com and org, where most blocklists live, are fetched one at a time
  # first: they check the answers of those zones, also the proofs that a zone under them is unsigned. Unbound
  # counts as started after that (well under a second), and Rspamd starts after Unbound. "-": without the
  # internet Unbound still starts.
  printf '%s\n' '[Service]' \
    "ExecStartPost=-/bin/sh -c 'for q in . net. com. org.; do dig +time=3 +tries=2 @127.0.0.1 \$\$q DNSKEY > /dev/null; done'" \
    > /etc/systemd/system/unbound.service.d/warmup.conf
  start_after rspamd valkey.service unbound.service network-online.target$rspamd_after
  # Rspamd counts as started once its controller answers (up to a minute, never a failure: see clamd above), and
  # Postfix starts after it (see Postfix), so no mail comes in before it is checked ("$$": systemd's own "$")
  printf '%s\n' '[Service]' \
    "ExecStartPost=-/bin/sh -c 'for i in \$\$(seq 60); do curl -sf http://127.0.0.1:11334/ping > /dev/null && exit 0; sleep 1; done; exit 1'" \
    > /etc/systemd/system/rspamd.service.d/ready.conf
  systemctl daemon-reload
  unit_env rspamd "RSPAMD_LOCAL_ADDR=127.0.0.1"
  systemctl enable unbound valkey rspamd
fi
#
# fail2ban (stack parameter Fail2ban): bans IP addresses after repeated failed logins (nftables).
# Our jails (jail.local) come from the release at every boot; the admin's own settings live on EFS in custom.local,
# which fail2ban reads after ours (so they win) and upgrades never touch.
if [ "$FAIL2BAN" = 'ENABLED' ]; then
  # fail2ban-server only: the fail2ban meta package would also pull in firewalld
  dnf install -y fail2ban-server
  # (a v1.0 install has a link to EFS here: replace it, don't write through it)
  rm -f /etc/fail2ban/jail.local
  aws s3 cp s3://$BUCKET_CONFIG/jail.local /etc/fail2ban/jail.local
  # the admin's file starts as our commented examples (the office address, milder limits, slow guessing)
  if [ ! -f /mnt/mailserver/etc/fail2ban/custom.local ]; then
    mkdir -p /mnt/mailserver/etc/fail2ban
    aws s3 cp s3://$BUCKET_CONFIG/custom.local /mnt/mailserver/etc/fail2ban/custom.local
  fi
  ln -sf /mnt/mailserver/etc/fail2ban/custom.local /etc/fail2ban/jail.d/custom.local
  # v1.0 kept our jail.local on EFS; it is rewritten on the instance now
  rm -f /mnt/mailserver/etc/fail2ban/jail.local
  # a reminder for the admin, next to the credentials
  printf 'To unban an IP address banned by fail2ban:\n   fail2ban-client unban <IP>\n' > /mnt/mailserver/root/unbanip
  # the webmail jail needs its log file to exist before Roundcube's first error
  [ -f /var/www/webmail/logs/errors.log ] || install -o apache -g apache -m 640 /dev/null /var/www/webmail/logs/errors.log
  efs_unit fail2ban
  # it reads the logs of these services and stops if a log file is missing: Apache's error_log appears only when
  # Apache first starts (on the first boot of an instance)
  start_after fail2ban httpd.service postfix.service dovecot.service
  systemctl enable fail2ban
fi
#
# The packages that work with the data on EFS and whose version isn't fixed by the data (information only, like
# image= and os=): which versions last used the data. MariaDB, Dovecot and Valkey follow AlmaLinux; Rspamd comes
# with the release, but a new one has changed its data before (4.3.1).
/usr/local/sbin/upgrade-data set mariadb "$(rpm -q mariadb-server)"
/usr/local/sbin/upgrade-data set dovecot "$(rpm -q dovecot)"
if [ "$ANTISPAM" = 'ENABLED' ]; then
  /usr/local/sbin/upgrade-data set rspamd "$(rpm -q rspamd)"
  /usr/local/sbin/upgrade-data set valkey "$(rpm -q valkey)"
else
  /usr/local/sbin/upgrade-data set rspamd off
  /usr/local/sbin/upgrade-data set valkey off
fi
#
# The services this instance runs, in one place for the helpers (they depend on the stack's parameters, and on
# what really got installed: olefy only if pip worked). running: must be up after the install (install-finish).
# efs: they write to the EFS, so they are stopped together when another instance takes over (services-shutdown)
# or this one is replaced (replace-instance); systemd orders the stops by the services' dependencies.
# (the helpers source the file, so its variable names must not clash with theirs: efs is the EFS path in
# install-finish)
running="mariadb postfix dovecot httpd php-fpm opendkim crond"
efs="mariadb postfix dovecot httpd php-fpm opendkim crond logrotate.timer certbot-renew.timer"
for unit in unbound valkey rspamd olefy clamd@scan clamav-freshclam fail2ban; do
  if systemctl is-enabled -q $unit 2> /dev/null; then running="$running $unit"; fi
done
for unit in valkey rspamd clamav-freshclam autoshutdown; do
  if systemctl is-enabled -q $unit 2> /dev/null; then efs="$efs $unit"; fi
done
printf '%s\n' "# Written by base.sh at the install: the services of this instance (they depend on the stack's parameters)" \
  "# services_running: must be up after the install (install-finish)" "services_running=\"$running\"" \
  "# services_efs: write to the EFS; stopped together when another instance takes over (services-shutdown) or" \
  "# this one is replaced (replace-instance)" "services_efs=\"$efs\"" > /usr/local/etc/flashlight-services
