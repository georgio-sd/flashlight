#!/bin/bash -xe
#
# EC2 instance metadata (IMDSv2: get a token, then ask with it)
imds() {
  local token
  token=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/$1
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
  mkdir /mnt/mailserver/www /mnt/mailserver/etc /mnt/mailserver/etc/sysconfig /mnt/mailserver/mail
  mkdir /mnt/mailserver/mail/shared-folders /mnt/mailserver/spool
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
dnf install -y php php-cli php-fpm php-mysqlnd php-mbstring php-intl php-xml php-gd php-pecl-zip php-opcache \
  httpd httpd-tools mod_ssl mariadb mariadb-server \
  postfix postfix-mysql dovecot dovecot-mysql dovecot-pigeonhole \
  opendkim opendkim-tools certbot pwgen python3-boto3 bind-utils mc
#
# Signaling CloudFormation after the final reboot (the same API call cfn-signal makes, through the AWS CLI)
cd ~
mkdir /etc/cron.once
# (outside stack create/update, e.g. after an ASG replacement, CloudFormation just rejects the signal)
printf '#!/bin/bash'"\n#\n/usr/local/sbin/instance-log READY 'installed and rebooted, services up'\n\
/usr/bin/aws cloudformation signal-resource --stack-name $STACK --logical-resource-id AutoScalingGroup \
  --unique-id $instid --status SUCCESS --region $AWS_REGION\n" > /etc/cron.once/cfn_signal.sh
printf '#!/bin/bash\n#\nfor script in `find /etc/cron.once -type f`; do $script; rm $script; done\n' \
  > /usr/bin/cron-boot-runner
chmod 744 /etc/cron.once/cfn_signal.sh /usr/bin/cron-boot-runner
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
cp /usr/lib/systemd/system/mariadb.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/mariadb.service
systemctl daemon-reload
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
  tar xzf $pfa_tar -C /mnt/mailserver/www/admin/padmin --strip-components=1
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
  tar xzf $pma_tar -C /mnt/mailserver/www/admin/phpmyadmin --strip-components=1
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
# Getting SSL certificates (certbot) and preparing crontab
# Renewal runs from certbot-renew.timer (EPEL package, twice a day); the hooks below apply to it.
if [ ! -f $flag ]; then
  # CERT_MODE=staging (stack parameter) uses the Let's Encrypt test CA: untrusted certs, no production rate limits
  certbot_test=""
  [ "$CERT_MODE" = 'staging' ] && certbot_test="--test-cert"
  # RSA: understood by every mail server and client, including old ones
  certbot certonly --standalone $certbot_test --key-type rsa -d $MAIL_DOMAIN,$ADMIN_DOMAIN -m $ADMIN_EMAIL \
    --agree-tos --non-interactive
  # standalone renewal needs port 80, so Apache stops for the few seconds of a renewal
  printf '#!/bin/bash\nsystemctl stop httpd\n' > /etc/letsencrypt/renewal-hooks/pre/srv-stop
  printf '#!/bin/bash\nsystemctl start httpd\n' > /etc/letsencrypt/renewal-hooks/post/srv-start
  # only when a new certificate was actually issued: reload mail services, connections stay up
  printf '#!/bin/bash\nsystemctl try-reload-or-restart postfix dovecot\n' > /etc/letsencrypt/renewal-hooks/deploy/srv-reload
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
cp /usr/lib/systemd/system/crond.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/crond.service
ln -s /mnt/mailserver/etc/crontab /etc/crontab
# the local cron files (hourly runner, anacron daily/weekly jobs) don't send mail either
sed -i 's/^MAILTO=.*/MAILTO=""/' /etc/cron.d/0hourly /etc/anacrontab
rm -rf /etc/letsencrypt
ln -s /mnt/mailserver/etc/letsencrypt /etc/letsencrypt
#
# Spot instances: on the interruption notice and on the weekly price check the instance stops its
# services and asks the ASG to replace it (replace-instance); events go to /mnt/mailserver/log/instance.log
if [ "$INSTANCE_LIFECYCLE" = 'Spot' ]; then
  for tool in replace-instance spot-instance-shutdown spotprices.py; do
    aws s3 cp s3://$BUCKET_CONFIG/$tool /mnt/mailserver/automation/
    chmod 700 /mnt/mailserver/automation/$tool
  done
  sed -i "s/\([^0-9]*\)\(.*\)spotprices\(.*\)/\2spotprices\3/" /mnt/mailserver/etc/crontab
  aws s3 cp s3://$BUCKET_CONFIG/autoshutdown.service /etc/systemd/system
  systemctl enable autoshutdown
else
  sed -i "s/\(^[0-9].*\)spotprices\(.*\)/\#\1spotprices\2/" /mnt/mailserver/etc/crontab
fi
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
cp /usr/lib/systemd/system/postfix.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/postfix.service
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
mkdir /var/log/dovecot
cd /var/log/dovecot && touch lda-errors.log lda-deliver.log lmtp.log
chown -R vmail:dovecot /var/log/dovecot
ln -s /mnt/mailserver/etc/dovecot /etc/dovecot
sed -i "s#/var##" /usr/lib/tmpfiles.d/dovecot.conf
cp /usr/lib/systemd/system/dovecot.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/dovecot.service
systemctl enable dovecot
#
# Installing roundcube
if [ ! -f $flag ]; then
  cd ~
  wget https://github.com/roundcube/roundcubemail/releases/download/1.4.13/roundcubemail-1.4.13-complete.tar.gz
  tar xzvf roundcubemail-1.4.13-complete.tar.gz > /dev/null
  mkdir /var/www/webmail
  cp -R /root/roundcubemail-1.4.13/* /var/www/webmail
  chown -R apache. /var/www/webmail/temp /var/www/webmail/logs
  aws s3 cp s3://$BUCKET_CONFIG/config.inc.php.rc /var/www/webmail/config/config.inc.php
  sed -i "s/{des_key}/$(pwgen 24 1)/" /var/www/webmail/config/config.inc.php
  sed -i "s/{RoundcubePassword}/$roundcubepassword/" /var/www/webmail/config/config.inc.php
  aws s3 cp s3://$BUCKET_CONFIG/roundcubemail.sql /root
  mysql roundcube < roundcubemail.sql
  cp /var/www/webmail/plugins/managesieve/config.inc.php.dist /var/www/webmail/plugins/managesieve/config.inc.php
  sed -i "s/config\['managesieve_port'\] = null/config\['managesieve_port'\] = 4190/" \
    /var/www/webmail/plugins/managesieve/config.inc.php
  sed -i "s/config\['managesieve_vacation'\] = 0/config\['managesieve_vacation'\] = 1/" \
    /var/www/webmail/plugins/managesieve/config.inc.php
  rm -r roundcubemail*
  TimeZoneFixed=$(echo $TIMEZONE|sed 's#/#\\/#g')
  sed -i "s/;date.timezone =/date.timezone = $TimeZoneFixed/" /etc/php.ini
  mv /etc/php.ini /mnt/mailserver/etc
fi
rm -f /etc/php.ini
ln -s /mnt/mailserver/etc/php.ini /etc/php.ini
#
# Securing MariaDB
if [ ! -f $flag ]; then
  cd ~
  aws s3 cp s3://$BUCKET_CONFIG/db-backup /mnt/mailserver/automation
  aws s3 cp s3://$BUCKET_CONFIG/mysql_secure_installation_auto ./
  chmod 700 mysql_secure_installation_auto
  ./mysql_secure_installation_auto
  rm mysql_secure_installation_auto
fi
#
# Configuring Apache
if [ ! -f $flag ]; then
  aws s3 cp s3://$BUCKET_CONFIG/httpd.conf /etc/httpd/conf
  sed -i "s/{AdminEmail}/$ADMIN_EMAIL/" /etc/httpd/conf/httpd.conf
  sed -i "s/{MailDomain}/$MAIL_DOMAIN/" /etc/httpd/conf/httpd.conf
  aws s3 cp s3://$BUCKET_CONFIG/ssl.conf /etc/httpd/conf.d
  aws s3 cp s3://$BUCKET_CONFIG/sites.conf /etc/httpd/conf.d
  sed -i "s/{AdminEmail}/$ADMIN_EMAIL/" /etc/httpd/conf.d/sites.conf
  sed -i "s/{AdminDomain}/$ADMIN_DOMAIN/" /etc/httpd/conf.d/sites.conf
  sed -i "s/{MailDomain}/$MAIL_DOMAIN/" /etc/httpd/conf.d/sites.conf
  rm /etc/httpd/logs /etc/httpd/modules /etc/httpd/state
  ln -s /var/log/httpd /etc/httpd/logs
  ln -s /usr/lib64/httpd/modules /etc/httpd/modules
  ln -s /var/lib/httpd /etc/httpd/state
  mv /etc/httpd /mnt/mailserver/etc
fi
rm -rf /etc/httpd
ln -s /mnt/mailserver/etc/httpd /etc/httpd
cp /usr/lib/systemd/system/httpd.service /etc/systemd/system
cp /usr/lib/systemd/system/httpd-init.service /etc/systemd/system
cp /usr/lib/systemd/system/php-fpm.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/httpd.service
sed -i "s/Documentation\(.*\)/Documentation\1\nAfter=mnt-mailserver.mount/" /etc/systemd/system/httpd-init.service
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/php-fpm.service
systemctl enable httpd
#
# Setting up DKIM, SPF and DMARK
if [ ! -f $flag ]; then
  cd ~
  mkdir /etc/postfix/dkim
  chown root:opendkim /etc/postfix/dkim && chmod 750 /etc/postfix/dkim
  cd /etc/postfix/dkim
  for (( i=1; i<=$NUMBER_OF_DOMAINS; i++ ))
  do
    domain=$(echo "$DOMAIN_NAMES" | cut -d',' -f $i)
    mkdir $domain
    opendkim-genkey -D /etc/postfix/dkim/$domain/ -d $domain -s mail
    echo "mail._domainkey.$domain $domain:mail:/etc/postfix/dkim/$domain/mail.private" >> keytable
    echo "*@$domain mail._domainkey.$domain" >> signingtable
  done
  aws s3 cp s3://$BUCKET_CONFIG/opendkim.conf /etc/postfix/dkim
  chown -R root:opendkim /etc/postfix/dkim && find . -type d -exec chmod 750 {} \; && find . -type f -exec chmod 640 {} \;
  aws s3 cp s3://$BUCKET_CONFIG/dnsupd.py /root
  chmod 700 /root/dnsupd.py
  /root/dnsupd.py $DOMAIN_NAMES $DOMAIN_ZONE_IDS $EIP
  rm /root/dnsupd.py
  sed -i "s#opendkim.conf -P /var#postfix/dkim/opendkim.conf -P #" /etc/sysconfig/opendkim
  mv /etc/sysconfig/opendkim /mnt/mailserver/etc/sysconfig
else
  cd /etc/postfix/dkim
  rm keytable signingtable
  for directory in `find . -maxdepth 1 -mindepth 1 -type d -printf '%f\n'`
  do
    directory_in_use=false
    for (( i=1; i<=$NUMBER_OF_DOMAINS; i++ ))
    do
      domain=$(echo "$DOMAIN_NAMES" | cut -d',' -f $i)
      if [ "$directory" = "$domain" ]; then
        directory_in_use=true
      fi
    done
    if [ "$directory_in_use" = "false" ]; then
      rm -r $directory
    fi
  done
  for (( i=1; i<=$NUMBER_OF_DOMAINS; i++ ))
  do
    domain=$(echo "$DOMAIN_NAMES" | cut -d',' -f $i)
    if [ ! -d $domain ]; then
      mkdir $domain
      opendkim-genkey -D /etc/postfix/dkim/$domain/ -d $domain -s mail
    fi
    echo "mail._domainkey.$domain $domain:mail:/etc/postfix/dkim/$domain/mail.private" >> keytable
    echo "*@$domain mail._domainkey.$domain" >> signingtable
  done
  chown -R root:opendkim /etc/postfix/dkim && find . -type d -exec chmod 750 {} \; && find . -type f -exec chmod 640 {} \;
  aws s3 cp s3://$BUCKET_CONFIG/dnsupd.py /root
  chmod 700 /root/dnsupd.py
  /root/dnsupd.py $DOMAIN_NAMES $DOMAIN_ZONE_IDS $EIP
  rm /root/dnsupd.py
fi
rm -f /etc/sysconfig/opendkim
ln -s /mnt/mailserver/etc/sysconfig/opendkim /etc/sysconfig/opendkim
#sed -i "s#/var##" /etc/tmpfiles.d/opendkim.conf
cp /usr/lib/systemd/system/opendkim.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/opendkim.service
#sed -i "s/PIDFile/#PIDFile/" /etc/systemd/system/opendkim.service
systemctl enable opendkim
