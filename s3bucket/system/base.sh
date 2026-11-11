#!/bin/bash -xe
#
# The stack's variables come from UserData. Without them some steps would act on empty values (an empty
# domain list, for example, would delete every DKIM key), so stop before touching anything.
for var in EIP_ID EIP AWS_REGION STACK MAIL_STORAGE BUCKET_CONFIG TIMEZONE ADMIN_EMAIL CERT_MODE INSTANCE_LIFECYCLE \
    DOMAIN_NAMES DOMAIN_ZONE_IDS ADMIN_DOMAIN MAIL_DOMAIN REBUILD_AFTER_DAYS; do
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
# Setting up ElasticIP
instid=$(imds instance-id)
aws ec2 associate-address --instance-id $instid --allocation-id $EIP_ID --region $AWS_REGION
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
# Creating directories and the vmail user (owner of all mailboxes)
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
#
# Instance helpers (imds: IMDSv2 metadata; instance-log: event log on EFS) and the BOOT record
for tool in imds instance-log; do
  aws s3 cp s3://$BUCKET_CONFIG/$tool /usr/local/sbin/
  chmod 755 /usr/local/sbin/$tool
done
/usr/local/sbin/instance-log BOOT "new $INSTANCE_LIFECYCLE instance, installing"
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
#
# Starting MariaDB
if [ ! -f $flag ]; then
  mv /etc/my.cnf.d /mnt/mailserver/etc
  # all clients are local (unix socket), so don't listen on the network
  sed -i 's/^#bind-address=.*/bind-address=127.0.0.1/' /mnt/mailserver/etc/my.cnf.d/mariadb-server.cnf
  mv /var/lib/mysql /mnt/mailserver
fi
rm -rf /var/lib/mysql /etc/my.cnf.d
ln -s /mnt/mailserver/etc/my.cnf.d /etc/my.cnf.d
ln -s /mnt/mailserver/mysql /var/lib/mysql
efs_unit mariadb
systemctl enable --now mariadb
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
  rm $pfa_tar
  chown -R apache: /mnt/mailserver/www/admin/padmin/templates_c
  setuppassword="$(pwgen 16 1)"
  setuphash=$(php -r 'echo password_hash($argv[1], PASSWORD_DEFAULT);' "$setuppassword")
  printf "PostfixAdmin setup password\n   password: $setuppassword\n\n" >> /root/credentials
  db_postfix_password="$(pwgen 16 1)"
  printf "MariaDB\n   login: postfix\n   password: $db_postfix_password\n\n" >> /root/credentials
  aws s3 cp s3://$BUCKET_CONFIG/config.local.php /mnt/mailserver/www/admin/padmin
  # '|' as the sed delimiter: the bcrypt setup hash can contain '/'
  sed -i "s|{database_password}|$db_postfix_password|; s|{admin_email}|$ADMIN_EMAIL|g; \
    s|{admindomain}|$ADMIN_DOMAIN|g; s|{setup_password}|$setuphash|" /mnt/mailserver/www/admin/padmin/config.local.php
  #
  aws s3 cp s3://$BUCKET_CONFIG/$pma_tar .
  mkdir /mnt/mailserver/www/admin/phpmyadmin
  tar xzf $pma_tar -C /mnt/mailserver/www/admin/phpmyadmin --strip-components=1 --no-same-owner
  rm $pma_tar
  mkdir /mnt/mailserver/www/admin/phpmyadmin/tmp
  chown -R apache: /mnt/mailserver/www/admin/phpmyadmin/tmp
  pmapassword="$(pwgen 16 1)"
  roundcubepassword="$(pwgen 16 1)"
  blowfishsecret="$(pwgen 32 1)"
  aws s3 cp s3://$BUCKET_CONFIG/config.inc.php /mnt/mailserver/www/admin/phpmyadmin
  sed -i "s/{pmapassword}/$pmapassword/" /mnt/mailserver/www/admin/phpmyadmin/config.inc.php
  sed -i "s/{blowfish_secret}/$blowfishsecret/" /mnt/mailserver/www/admin/phpmyadmin/config.inc.php
  printf "MariaDB\n   login: pma\n   password: $pmapassword\n\n" >> /root/credentials
  printf "MariaDB\n   login: roundcube\n   password: $roundcubepassword\n\n" >> /root/credentials
  #
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
  # only when a new certificate was actually issued: services reload it, connections stay up
  printf '#!/bin/bash\nsystemctl try-reload-or-restart postfix dovecot httpd\n' > /etc/letsencrypt/renewal-hooks/deploy/srv-reload
  chmod 744 /etc/letsencrypt/renewal-hooks/*/srv-*
  mv /etc/letsencrypt /mnt/mailserver/etc
  # no cron mail: jobs write their own logs to /mnt/mailserver/log
  sed -i 's/^MAILTO=.*/MAILTO=""/' /etc/crontab
  printf '@reboot         root /usr/bin/cron-boot-runner\n' >> /etc/crontab
  # weekly spot price check, Saturday -> Sunday night (enabled below for spot instances only)
  printf '#15   1  *  *  0 root /mnt/mailserver/automation/spotprices.py\n' >> /etc/crontab
  mv /etc/crontab /mnt/mailserver/etc
fi
rm -f /etc/crontab
efs_unit crond
ln -s /mnt/mailserver/etc/crontab /etc/crontab
# the local cron files (hourly runner, anacron daily/weekly jobs) don't send mail either
sed -i 's/^MAILTO=.*/MAILTO=""/' /etc/cron.d/0hourly /etc/anacrontab
rm -rf /etc/letsencrypt
ln -s /mnt/mailserver/etc/letsencrypt /etc/letsencrypt
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
for tool in replace-instance rebuild-check mailbox-cleanup; do
  aws s3 cp s3://$BUCKET_CONFIG/$tool /mnt/mailserver/automation/
  chmod 700 /mnt/mailserver/automation/$tool
done
if [ "$INSTANCE_LIFECYCLE" = 'Spot' ]; then
  for tool in spot-instance-shutdown spotprices.py; do
    aws s3 cp s3://$BUCKET_CONFIG/$tool /mnt/mailserver/automation/
    chmod 700 /mnt/mailserver/automation/$tool
  done
  sed -i "s/\([^0-9]*\)\(.*\)spotprices\(.*\)/\2spotprices\3/" /mnt/mailserver/etc/crontab
  aws s3 cp s3://$BUCKET_CONFIG/autoshutdown.service /etc/systemd/system
  systemctl enable autoshutdown
else
  sed -i "s/\(^[0-9].*\)spotprices\(.*\)/\#\1spotprices\2/" /mnt/mailserver/etc/crontab
fi
# Scheduled rebuild (stack parameter RebuildAfterDays, 0 = off): Sunday 03:15, two hours after the price check.
# The line is rewritten at every boot, so a stack update changes or removes it.
sed -i '/rebuild-check/d' /mnt/mailserver/etc/crontab
if [ "$REBUILD_AFTER_DAYS" -gt 0 ]; then
  printf '15   3  *  *  0 root /mnt/mailserver/automation/rebuild-check %s\n' "$REBUILD_AFTER_DAYS" >> /mnt/mailserver/etc/crontab
fi
# Mailboxes deleted in PostfixAdmin: their mail goes to the trash, kept 30 days (every 10 minutes)
sed -i '/mailbox-cleanup/d' /mnt/mailserver/etc/crontab
printf '*/10 *  *  *  * root /mnt/mailserver/automation/mailbox-cleanup\n' >> /mnt/mailserver/etc/crontab
#
# Double instance service protection
aws s3 cp s3://$BUCKET_CONFIG/double-inst-prot.service /etc/systemd/system
aws s3 cp s3://$BUCKET_CONFIG/services-shutdown /usr/bin
chmod 700 /usr/bin/services-shutdown
systemctl enable double-inst-prot
#
# Configuring postfix
if [ ! -f $flag ]; then
  cd ~
  aws s3 cp s3://$BUCKET_CONFIG/main.cf /etc/postfix
  aws s3 cp s3://$BUCKET_CONFIG/master.cf /etc/postfix
  # lookups in the PostfixAdmin database
  mkdir /etc/postfix/mysql
  for map in virtual_mailbox_domains virtual_mailbox_maps virtual_alias_domain_mailbox_maps virtual_alias_maps \
      virtual_alias_domain_maps virtual_alias_domain_catchall_maps relay_domains; do
    aws s3 cp s3://$BUCKET_CONFIG/$map.cf /etc/postfix/mysql/
  done
  sed -i "s/{database_password}/$db_postfix_password/" /etc/postfix/mysql/*.cf
  # the files hold the database password: root and the postfix group only
  chown root:postfix /etc/postfix/mysql/*.cf
  chmod 640 /etc/postfix/mysql/*.cf
  sed -i "s/{MainDomain}/$(echo "$DOMAIN_NAMES" | cut -d',' -f 1)/" /etc/postfix/main.cf
  sed -i "s/{MailDomain}/$MAIL_DOMAIN/" /etc/postfix/main.cf
  mv /etc/postfix /mnt/mailserver/etc
  mv /var/spool/postfix /mnt/mailserver/spool
fi
rm -rf /etc/postfix
ln -s /mnt/mailserver/etc/postfix /etc/postfix
rm -rf /var/spool/postfix
ln -s /mnt/mailserver/spool/postfix /var/spool/postfix
efs_unit postfix
systemctl enable postfix
#
# Configuring dovecot
if [ ! -f $flag ]; then
  cd ~
  rm -r /etc/dovecot/*
  aws s3 cp s3://$BUCKET_CONFIG/dovecot.conf /etc/dovecot
  aws s3 cp s3://$BUCKET_CONFIG/dovecot-mysql.conf /etc/dovecot
  sed -i "s/{MainDomain}/$(echo "$DOMAIN_NAMES" | cut -d',' -f 1)/" /etc/dovecot/dovecot.conf
  sed -i "s/{MailDomain}/$MAIL_DOMAIN/" /etc/dovecot/dovecot.conf
  sed -i "s/{database_password}/$db_postfix_password/" /etc/dovecot/dovecot-mysql.conf
  mv /etc/dovecot /mnt/mailserver/etc
fi
rm -rf /etc/dovecot
ln -s /mnt/mailserver/etc/dovecot /etc/dovecot
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
  mkdir /var/www/webmail/skins/larry
  tar xzf $larry_tar -C /var/www/webmail/skins/larry --strip-components=1 --no-same-owner
  rm $rc_tar $larry_tar
  # the web installer isn't needed: the database and the config are prepared here
  rm -rf /var/www/webmail/installer /var/www/webmail/public_html/installer.php
  chown -R apache: /var/www/webmail/temp /var/www/webmail/logs
  aws s3 cp s3://$BUCKET_CONFIG/config.inc.php.rc /var/www/webmail/config/config.inc.php
  sed -i "s|{des_key}|$(pwgen 32 1)|; s|{RoundcubePassword}|$roundcubepassword|" /var/www/webmail/config/config.inc.php
  # the config holds the database password: readable by the web server only
  chown root:apache /var/www/webmail/config/config.inc.php
  chmod 640 /var/www/webmail/config/config.inc.php
  mysql roundcube < /var/www/webmail/SQL/mysql.initial.sql
fi
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
  aws s3 cp s3://$BUCKET_CONFIG/db-backup /mnt/mailserver/automation
  chmod 700 /mnt/mailserver/automation/db-backup
  printf '55  22  *  *  * root /mnt/mailserver/automation/db-backup\n' >> /mnt/mailserver/etc/crontab
fi
#
# Configuring Apache. The package's own config (httpd.conf, ssl.conf, modules) stays on the instance, so it
# always matches the installed Apache; only our sites file lives on EFS and survives instance replacement.
if [ ! -f $flag ]; then
  mkdir -p /mnt/mailserver/etc/httpd
  aws s3 cp s3://$BUCKET_CONFIG/sites.conf /mnt/mailserver/etc/httpd
  sed -i "s/{AdminEmail}/$ADMIN_EMAIL/g; s/{AdminDomain}/$ADMIN_DOMAIN/g; s/{MailDomain}/$MAIL_DOMAIN/g" \
    /mnt/mailserver/etc/httpd/sites.conf
fi
ln -sf /mnt/mailserver/etc/httpd/sites.conf /etc/httpd/conf.d/sites.conf
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
dkim=/etc/postfix/dkim
if [ ! -f $flag ]; then
  mkdir $dkim
  aws s3 cp s3://$BUCKET_CONFIG/opendkim.conf $dkim
fi
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
# fail2ban (stack parameter Fail2ban): bans IP addresses after repeated failed logins (nftables).
# The package's config stays on the instance; only our jail.local lives on EFS.
if [ "$FAIL2BAN" = 'ENABLED' ]; then
  # fail2ban-server only: the fail2ban meta package would also pull in firewalld
  dnf install -y fail2ban-server
  if [ ! -f /mnt/mailserver/etc/fail2ban/jail.local ]; then
    mkdir -p /mnt/mailserver/etc/fail2ban
    aws s3 cp s3://$BUCKET_CONFIG/jail.local /mnt/mailserver/etc/fail2ban
  fi
  ln -sf /mnt/mailserver/etc/fail2ban/jail.local /etc/fail2ban/jail.local
  # a reminder for the admin, next to the credentials
  printf 'To unban an IP address banned by fail2ban:\n   fail2ban-client unban <IP>\n' > /mnt/mailserver/root/unbanip
  # the webmail jail needs its log file to exist before Roundcube's first error
  [ -f /var/www/webmail/logs/errors.log ] || install -o apache -g apache -m 640 /dev/null /var/www/webmail/logs/errors.log
  efs_unit fail2ban
  systemctl enable fail2ban
fi
