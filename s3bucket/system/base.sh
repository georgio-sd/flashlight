#!/bin/bash -xe
#
# The stack's variables come from UserData. Without them some steps would act on empty values (an empty
# domain list, for example, would delete every DKIM key), so stop before touching anything.
for var in EIP_ID EIP AWS_REGION STACK MAIL_STORAGE BUCKET_CONFIG TIMEZONE ADMIN_EMAIL CERT_MODE INSTANCE_LIFECYCLE \
    DOMAIN_NAMES DOMAIN_ZONE_IDS ADMIN_DOMAIN MAIL_DOMAIN REBUILD_AFTER_DAYS ANTISPAM; do
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
# Installing amazon-efs-utils (prebuilt RPM, see build/efs-utils.md) and mounting EFS
cd ~
efs_rpm=amazon-efs-utils-3.3.5-1.el10.x86_64.rpm
aws s3 cp s3://$BUCKET_CONFIG/$efs_rpm .
dnf install -y ./$efs_rpm
rm $efs_rpm
mkdir /mnt/mailserver
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
dnf install -y php php-cli php-fpm php-mysqlnd php-mbstring php-intl php-xml php-gd php-pecl-zip php-opcache \
  httpd httpd-tools mod_ssl mariadb mariadb-server \
  postfix postfix-mysql dovecot dovecot-mysql dovecot-pigeonhole \
  opendkim opendkim-tools certbot python3-certbot-dns-route53 pwgen python3-boto3 bind-utils mc
#
# One-time jobs after the final reboot: /etc/cron.once runs once from @reboot. install-finish puts the
# READY check there (services up -> READY and the CloudFormation signal), only after a good install.
cd ~
mkdir -p /etc/cron.once
printf '#!/bin/bash\n#\nfor script in `find /etc/cron.once -type f`; do $script; rm $script; done\n' \
  > /usr/bin/cron-boot-runner
chmod 744 /usr/bin/cron-boot-runner
#
# Credentials file creating (the install trace with passwords goes to the root-only flashlight-install.log)
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
# all clients are local (unix socket), so don't listen on the network
printf '%s\n' "# Flashlight's MariaDB settings. DON'T EDIT: rewritten at every boot from the Flashlight release." \
  "# Your own settings go to /mnt/mailserver/etc/mariadb/custom.cnf (zz-custom.cnf here, read last)." \
  "[mysqld]" "bind-address = 127.0.0.1" > /etc/my.cnf.d/flashlight.cnf
custom_file /mnt/mailserver/etc/mariadb/custom.cnf \
  "# Your MariaDB settings. MariaDB reads this file last (as /etc/my.cnf.d/zz-custom.cnf), so the values set" \
  "# here win; Flashlight upgrades never change this file. Restart MariaDB after editing it. Example:" \
  "#   [mysqld]" "#   max_connections = 200"
ln -sf /mnt/mailserver/etc/mariadb/custom.cnf /etc/my.cnf.d/zz-custom.cnf
# v1.0 kept the whole config folder on EFS; the package's own files are used now
rm -rf /mnt/mailserver/etc/my.cnf.d
efs_unit mariadb
systemctl enable --now mariadb
#
# Data from an older Flashlight release: back up, run the migrations up to this release, restore all on a failure
/usr/local/sbin/upgrade-data run
#
# Installing phpMyAdmin and postfixadmin (pinned releases from the config bucket)
if [ ! -f $flag ]; then
  cd ~
  pfa_tar=postfixadmin-v4.0.6-php74.tar.gz
  pma_tar=phpMyAdmin-5.2.3-all-languages.tar.gz
  mkdir /mnt/mailserver/www/admin
  webadmpass="$(pwgen 16 1)"
  htpasswd -bcB /mnt/mailserver/www/admin/.htpasswd admin $webadmpass
  printf "Admin web access\n   Link: https://$ADMIN_DOMAIN\n" >> /root/credentials
  printf "   login: admin\n   password: $webadmpass\n\n" >> /root/credentials
  postfixadminpassword="$(pwgen 16 1)"
  printf "PostfixAdmin superadmin\n   Link: https://$ADMIN_DOMAIN/padmin\n" >> /root/credentials
  printf "   login: $ADMIN_EMAIL\n   password: $postfixadminpassword\n\n" >> /root/credentials
  #
  # The release tarball already contains vendor/ (no composer needed); the php74 build runs on PHP 7.4+
  aws s3 cp s3://$BUCKET_CONFIG/$pfa_tar .
  mkdir /mnt/mailserver/www/admin/padmin
  tar xzf $pfa_tar -C /mnt/mailserver/www/admin/padmin --strip-components=1 --no-same-owner
  /usr/local/sbin/upgrade-data set postfixadmin $pfa_tar
  rm $pfa_tar
  chown -R apache: /mnt/mailserver/www/admin/padmin/templates_c
  setuppassword="$(pwgen 16 1)"
  setuphash=$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$setuppassword")
  /usr/local/sbin/secrets set padmin_setup_hash "$setuphash"
  printf "PostfixAdmin setup password\n   password: $setuppassword\n\n" >> /root/credentials
  db_postfix_password="$(pwgen 16 1)"
  /usr/local/sbin/secrets set postfix_db_password $db_postfix_password
  printf "MariaDB\n   login: postfix\n   password: $db_postfix_password\n\n" >> /root/credentials
  #
  aws s3 cp s3://$BUCKET_CONFIG/$pma_tar .
  mkdir /mnt/mailserver/www/admin/phpmyadmin
  tar xzf $pma_tar -C /mnt/mailserver/www/admin/phpmyadmin --strip-components=1 --no-same-owner
  /usr/local/sbin/upgrade-data set phpmyadmin $pma_tar
  rm $pma_tar
  mkdir /mnt/mailserver/www/admin/phpmyadmin/tmp
  chown -R apache: /mnt/mailserver/www/admin/phpmyadmin/tmp
  pmapassword="$(pwgen 16 1)"
  roundcubepassword="$(pwgen 16 1)"
  blowfishsecret="$(pwgen 32 1)"
  /usr/local/sbin/secrets set pma_db_password $pmapassword
  /usr/local/sbin/secrets set roundcube_db_password $roundcubepassword
  /usr/local/sbin/secrets set pma_blowfish_secret $blowfishsecret
  printf "MariaDB\n   login: pma\n   password: $pmapassword\n\n" >> /root/credentials
  printf "MariaDB\n   login: roundcube\n   password: $roundcubepassword\n\n" >> /root/credentials
fi
#
# Our configs of PostfixAdmin and phpMyAdmin, rebuilt at every boot from the release with the values from the
# secrets file. Each ends by including the admin's own settings from EFS (custom.php), so those win.
# (the values are read in separate assignments, so a missing secret stops the install)
padmin_conf=/mnt/mailserver/www/admin/padmin/config.local.php
padmin_db_password=$(/usr/local/sbin/secrets get postfix_db_password)
padmin_setup_hash=$(/usr/local/sbin/secrets get padmin_setup_hash)
aws s3 cp s3://$BUCKET_CONFIG/config.local.php $padmin_conf
# '|' as the sed delimiter: the bcrypt setup hash can contain '/'
sed -i "s|{database_password}|$padmin_db_password|; s|{admin_email}|$ADMIN_EMAIL|g; \
  s|{admindomain}|$ADMIN_DOMAIN|g; s|{setup_password}|$padmin_setup_hash|" $padmin_conf
pma_conf=/mnt/mailserver/www/admin/phpmyadmin/config.inc.php
pma_db_password=$(/usr/local/sbin/secrets get pma_db_password)
pma_blowfish_secret=$(/usr/local/sbin/secrets get pma_blowfish_secret)
aws s3 cp s3://$BUCKET_CONFIG/config.inc.php $pma_conf
sed -i "s/{pmapassword}/$pma_db_password/; s/{blowfish_secret}/$pma_blowfish_secret/" $pma_conf
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
  mysql -u root -e "GRANT ALL PRIVILEGES ON postfix.* TO 'postfix'@'localhost' identified by '$db_postfix_password';"
  mysql -u root -e "GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'pma'@'localhost' identified by '$pmapassword';"
  mysql -u root -e "GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'localhost' identified by '$roundcubepassword';"
  mysql -u root -e "FLUSH PRIVILEGES;"
  #
  # creating postfix db
  php /mnt/mailserver/www/admin/padmin/public/upgrade.php
  /mnt/mailserver/www/admin/padmin/scripts/postfixadmin-cli admin add $ADMIN_EMAIL --superadmin 1 --active 1 \
    --password $postfixadminpassword --password2 $postfixadminpassword
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
for tool in replace-instance rebuild-check mailbox-cleanup db-backup; do
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
postfix_db_password=$(/usr/local/sbin/secrets get postfix_db_password)
mkdir -p /etc/postfix/mysql
for map in virtual_mailbox_domains virtual_mailbox_maps virtual_alias_domain_mailbox_maps virtual_alias_maps \
    virtual_alias_domain_maps virtual_alias_domain_catchall_maps relay_domains; do
  aws s3 cp s3://$BUCKET_CONFIG/$map.cf /etc/postfix/mysql/
done
sed -i "s/{database_password}/$postfix_db_password/" /etc/postfix/mysql/*.cf
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
systemctl enable postfix
#
# Configuring dovecot. Our dovecot.conf and dovecot-mysql.conf come from the release at every boot (the package's
# own config isn't used); the admin's own settings live on EFS in custom.conf, included at the end of ours.
# (/etc/dovecot is the package's folder, or a link to EFS on a v1.0 install: replace it, don't write through it)
rm -rf /etc/dovecot
mkdir /etc/dovecot
aws s3 cp s3://$BUCKET_CONFIG/dovecot.conf /etc/dovecot
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
# compiled now: Dovecot delivers as vmail, which can't write the compiled script next to it
sievec /etc/dovecot/sieve/spam-to-junk.sieve
aws s3 cp s3://$BUCKET_CONFIG/dovecot-mysql.conf /etc/dovecot
sed -i "s/{MainDomain}/$(echo "$DOMAIN_NAMES" | cut -d',' -f 1)/; s/{MailDomain}/$MAIL_DOMAIN/" /etc/dovecot/dovecot.conf
# (a separate assignment, so a missing secret stops the install instead of leaving an empty password)
postfix_db_password=$(/usr/local/sbin/secrets get postfix_db_password)
sed -i "s/{database_password}/$postfix_db_password/" /etc/dovecot/dovecot-mysql.conf
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
systemctl enable dovecot
#
# Installing Roundcube (webmail) with the optional Larry skin (users pick it in their settings)
if [ ! -f $flag ]; then
  cd ~
  rc_tar=roundcubemail-1.7.6-complete.tar.gz
  larry_tar=roundcube-larry-03ccd35.tar.gz
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
  /usr/local/sbin/secrets set roundcube_des_key "$(pwgen 32 1)"
  mysql roundcube < /var/www/webmail/SQL/mysql.initial.sql
fi
# Our Roundcube config, rebuilt at every boot from the release with the values from the secrets file; it ends by
# including the admin's own settings from EFS (custom.inc.php), so those win
rc_conf=/var/www/webmail/config/config.inc.php
rc_db_password=$(/usr/local/sbin/secrets get roundcube_db_password)
rc_des_key=$(/usr/local/sbin/secrets get roundcube_des_key)
aws s3 cp s3://$BUCKET_CONFIG/config.inc.php.rc $rc_conf
sed -i "s|{des_key}|$rc_des_key|; s|{RoundcubePassword}|$rc_db_password|" $rc_conf
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
# time zone, and attachments up to the 20 MB message limit of Postfix
cat > /etc/php.d/99-flashlight.ini <<EOF
date.timezone = $TIMEZONE
upload_max_filesize = 15M
post_max_size = 20M
EOF
#
# MariaDB root password and daily database backups.
# A fresh MariaDB 10.11 has no anonymous users or test database, so only root needs a password (for phpMyAdmin);
# root on the server itself (shell, db-backup) keeps logging in through the unix socket without one.
if [ ! -f $flag ]; then
  db_root_password="$(pwgen 16 1)"
  printf "MariaDB\n   Link: https://$ADMIN_DOMAIN/myadmin\n" >> /root/credentials
  printf "   login: root\n   password: $db_root_password\n\n" >> /root/credentials
  mysql -u root -e "ALTER USER root@localhost IDENTIFIED VIA unix_socket OR mysql_native_password USING PASSWORD('$db_root_password');"
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
#
# PHP-FPM pool sized by memory (local file, rewritten at every boot): about 10 PHP processes per 2 GB
# (the package default of up to 50 could run a small server out of memory); processes are started
# on demand and exit when idle instead of being kept running
php_children=$(awk '/^MemTotal/ {n = int($2 / 1024 / 200); print (n < 5 ? 5 : n)}' /proc/meminfo)
sed -i "s/^pm = .*/pm = ondemand/; s/^pm.max_children = .*/pm.max_children = $php_children/" /etc/php-fpm.d/www.conf
efs_unit httpd
efs_unit php-fpm
systemctl enable httpd
#
# DKIM, SPF and DMARC. Run at every boot, so the server follows the stack's domain list:
# keys of removed domains are deleted, new domains get a key, and the DNS records are brought up to date.
dkim=/mnt/mailserver/etc/postfix/dkim
mkdir -p $dkim
# our OpenDKIM config, rewritten at every boot from the release (it stays next to the keys)
aws s3 cp s3://$BUCKET_CONFIG/opendkim.conf $dkim
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
# Spam filtering (stack parameter Antispam): Rspamd checks incoming mail as the first Postfix milter (main.cf);
# spam gets an "X-Spam: Yes" header and goes to Junk (Dovecot's sieve_before), obvious spam is rejected. Valkey
# (Redis) keeps what Rspamd learns, on EFS; Unbound is Rspamd's own DNS resolver (blocklists refuse queries that
# come through the big shared resolvers, AWS's included). Our settings in /etc/rspamd/local.d are rewritten at
# every boot; the admin's own live on EFS in /mnt/mailserver/etc/rspamd/override.d.
if [ "$ANTISPAM" = 'ENABLED' ]; then
  # Rspamd's own repository (it isn't in AlmaLinux or EPEL), major version 4 only: a new major version comes
  # with a Flashlight release, after testing
  os_major=$(. /etc/os-release && echo "${VERSION_ID%%.*}")
  cat > /etc/yum.repos.d/rspamd.repo <<EOF
[rspamd]
name=Rspamd stable repository
baseurl=https://rspamd.com/rpm-stable/centos-$os_major/\$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://rspamd.com/rpm/rspamd.asc
includepkgs=rspamd-4.*
EOF
  dnf install -y rspamd valkey unbound
  #
  # Valkey: data on EFS, so learned spam survives instance replacements. The valkey user's ID may differ on each
  # new instance, hence the chown at every boot.
  install -d -m 750 /mnt/mailserver/valkey
  chown -R valkey:valkey /mnt/mailserver/valkey
  sed -i 's|^dir .*|dir /mnt/mailserver/valkey|' /etc/valkey/valkey.conf
  printf '%s\n' "# Flashlight: memory cap; Rspamd's learned data expire by themselves" "maxmemory 256mb" \
    "maxmemory-policy volatile-ttl" >> /etc/valkey/valkey.conf
  #
  # Our Rspamd settings (local.d is merged into Rspamd's defaults)
  rspamd_conf() {
    local file=/etc/rspamd/local.d/$1
    shift
    printf '%s\n' "# Flashlight's Rspamd settings. DON'T EDIT: rewritten at every boot from the Flashlight release." \
      "# Your own settings go to /mnt/mailserver/etc/rspamd/override.d (see the README there)." "$@" > $file
  }
  rspamd_conf options.inc 'dns { nameserver = ["127.0.0.1:53"]; }'
  rspamd_conf redis.conf 'servers = "127.0.0.1:6379";'
  # no greylisting: it delays legitimate mail by minutes or hours (the sender retries later)
  rspamd_conf actions.conf "reject = 15;" "add_header = 6;" "greylist = null;"
  rspamd_conf greylist.conf "enabled = false;"
  # the Bayes filter also learns by itself from mail that scores very high or very low
  rspamd_conf classifier-bayes.conf "autolearn = true;"
  rspamd_conf milter_headers.conf 'use = ["authentication-results", "x-spamd-bar"];'
  # OpenDKIM signs our mail
  rspamd_conf dkim_signing.conf "enabled = false;"
  rspamd_conf arc.conf "enabled = false;"
  # Spamhaus through DQS with the stack's key (Spamhaus refuses queries from AWS without one)
  rm -f /etc/rspamd/local.d/rbl.conf /etc/rspamd/local.d/rbl_group.conf
  if [ -n "$DQS_KEY" ]; then
    dqs_key=$(printf '%s' "$DQS_KEY" | sed 's/[&|\\]/\\&/g')
    for f in rbl rbl_group; do
      aws s3 cp s3://$BUCKET_CONFIG/spamhaus-dqs-$f.conf /etc/rspamd/local.d/$f.conf
      sed -i "s|your_DQS_key|$dqs_key|g" /etc/rspamd/local.d/$f.conf
    done
    # the key: readable by Rspamd only
    chown root:_rspamd /etc/rspamd/local.d/rbl.conf /etc/rspamd/local.d/rbl_group.conf
    chmod 640 /etc/rspamd/local.d/rbl.conf /etc/rspamd/local.d/rbl_group.conf
  fi
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
  custom_file /mnt/mailserver/etc/fail2ban/custom.local \
    "# Your fail2ban settings. fail2ban reads this file after Flashlight's /etc/fail2ban/jail.local, so the values" \
    "# set here win; Flashlight upgrades never change this file. Restart fail2ban after editing it." \
    "# Example:" "#   [sshd]" "#   maxretry = 10" "#   [DEFAULT]" "#   ignoreip = 203.0.113.5"
  ln -sf /mnt/mailserver/etc/fail2ban/custom.local /etc/fail2ban/jail.d/custom.local
  # v1.0 kept our jail.local on EFS; it is rewritten on the instance now
  rm -f /mnt/mailserver/etc/fail2ban/jail.local
  # a reminder for the admin, next to the credentials
  printf 'To unban an IP address banned by fail2ban:\n   fail2ban-client unban <IP>\n' > /mnt/mailserver/root/unbanip
  # the webmail jail needs its log file to exist before Roundcube's first error
  [ -f /var/www/webmail/logs/errors.log ] || install -o apache -g apache -m 640 /dev/null /var/www/webmail/logs/errors.log
  efs_unit fail2ban
  systemctl enable fail2ban
fi
