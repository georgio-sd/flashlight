#!/bin/bash -xe
#
# Installing awscli and setting up ElasticIP
instid=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 associate-address --instance-id $instid --allocation-id $EIP_ID --region $AWS_REGION
#
# Setting up system settings
timedatectl set-timezone $TIMEZONE
hostnamectl set-hostname $MAIL_DOMAIN
flag=/mnt/mailserver/flag
systemctl stop crond
#
# CentOS repofix
#cd /etc/yum.repos.d/
#sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
#sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
#
# Installing amazon-efs-utils and mounting EFS
cd ~
yum install -y make rpm-build
git clone https://github.com/aws/efs-utils
cd efs-utils
make rpm
yum install -y ./build/amazon-efs-utils*rpm
cd ~ && rm -r /root/efs-utils
mkdir /mnt/mailserver
echo -e "$MAIL_STORAGE:/ /mnt/mailserver efs defaults,_netdev 0 0" >> /etc/fstab
mount -a
#
# Creating directories
rm -f /mnt/mailserver/flag-ec2id-*
printf "Do not delete this file" > /mnt/mailserver/flag-ec2id-$instid
if [ ! -f $flag ]; then
  mkdir /mnt/mailserver/root /mnt/mailserver/automation /mnt/mailserver/log /mnt/mailserver/backup
  mkdir /mnt/mailserver/www /mnt/mailserver/etc /mnt/mailserver/etc/sysconfig /mnt/mailserver/mail
  mkdir /mnt/mailserver/mail/shared-folders /mnt/mailserver/spool
  groupadd -g 5000 vmail
  useradd -d /mnt/mailserver/mail -g 5000 -u 5000 vmail -s /sbin/nologin
  chown -R vmail. /mnt/mailserver/mail
else
  groupadd -g 5000 vmail
  useradd -d /mnt/mailserver/mail -g 5000 -u 5000 vmail -s /sbin/nologin
fi
#
# Installing Remi and the base set of packages
yum install -y dnf-utils http://rpms.remirepo.net/enterprise/remi-release-8.7.rpm
# fix later
#cd /etc/yum.repos.d/
#sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
#sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
yum makecache -y
yum module enable -y php:remi-7.4
yum install -y httpd mod_ssl mariadb mariadb-server pwgen php php-imap php-mysqlnd php-mbstring bind-utils certbot \
  postfix postfix-mysql dovecot dovecot-mysql dovecot-pigeonhole php-pear php-mcrypt php-intl php-ldap \
  php-pear-Net-SMTP php-gd php-zip php-imagick opendkim jq python39
yum install -y --enablerepo=remi php-pear-Net-Sieve php-pear-Mail-Mime php-pear-Net-IDNA2
pip3.9 install boto3 requests urllib3==1.26.15 --upgrade
#
# installing cfn-tools
cd ~
wget https://s3.amazonaws.com/cloudformation-examples/aws-cfn-bootstrap-py3-latest.tar.gz
pip3.9 install aws-cfn-bootstrap-py3-latest.tar.gz
rm aws-cfn-bootstrap-py3-latest.tar.gz
mkdir /etc/cron.once
printf '#!/bin/bash'"\n#\n/usr/local/bin/cfn-signal -s true --stack $STACK --resource AutoScalingGroup --region $AWS_REGION\n" \
  > /etc/cron.once/cfn_signal.sh
printf '#!/bin/bash\n#\nfor script in `find /etc/cron.once -type f`; do $script; rm $script; done\n' \
  > /usr/bin/cron-boot-runner
chmod 744 /etc/cron.once/cfn_signal.sh /usr/bin/cron-boot-runner
#
# Setting up iptables
if [ ! -f $flag ]; then
  aws s3 cp s3://$BUCKET_CONFIG/iptables /mnt/mailserver/etc/sysconfig
fi
rm /etc/sysconfig/iptables
ln -s /mnt/mailserver/etc/sysconfig/iptables /etc/sysconfig/iptables
cp /usr/lib/systemd/system/iptables.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/iptables.service
systemctl daemon-reload
systemctl restart iptables
#
# Credentials file creating and init log protecting
if [ ! -f $flag ]; then
  touch /mnt/mailserver/root/credentials
  chmod 600 /mnt/mailserver/root/credentials
  chmod 600 /var/log/cloud-init-output.log
fi
ln -s /mnt/mailserver/root/credentials /root/credentials
#
# Starting MariaDB
if [ ! -f $flag ]; then
  mv /etc/my.cnf.d /mnt/mailserver/etc
  sed -i 's/#bind-address/bind-address/' /mnt/mailserver/etc/my.cnf.d/mariadb-server.cnf
  sed -i 's/plugin-load-add/# plugin-load-add/' /mnt/mailserver/etc/my.cnf.d/auth_gssapi.cnf
  mv /var/lib/mysql /mnt/mailserver
fi
rm -rf /var/lib/mysql /etc/my.cnf.d
ln -s /mnt/mailserver/etc/my.cnf.d /etc/my.cnf.d
ln -s /mnt/mailserver/mysql /var/lib/mysql
cp /usr/lib/systemd/system/mariadb.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/mariadb.service
ln -sf /etc/systemd/system/mariadb.service /etc/systemd/system/mysql.service
ln -sf /etc/systemd/system/mariadb.service /etc/systemd/system/mysqld.service
systemctl daemon-reload
systemctl enable --now mariadb
#
# Installing phpMyAdmin and postfixadmin
if [ ! -f $flag ]; then
  cd ~
  mkdir /mnt/mailserver/www/admin
  webadmpass="$(pwgen 16 1)"
  htpasswd -bc /mnt/mailserver/www/admin/.htpasswd admin $webadmpass
  printf "Admin web access\n   Link: https://$ADMIN_DOMAIN\n" >> /root/credentials
  printf "   login: admin\n   password: $webadmpass\n\n" >> /root/credentials
  postfixadminpassword="$(pwgen 16 1)"
  printf "PostfixAdmin superadmin\n   Link: https://$ADMIN_DOMAIN/padmin\n" >> /root/credentials
  printf "   login: $ADMIN_EMAIL\n   password: $postfixadminpassword\n\n" >> /root/credentials
  #
  wget https://sourceforge.net/projects/postfixadmin/files/postfixadmin/postfixadmin-3.2/postfixadmin-3.2.4.tar.gz
  tar xzvf postfixadmin-3.2.4.tar.gz > /dev/null
  mkdir /mnt/mailserver/www/admin/padmin
  cp -R postfixadmin-3.2.4/* /mnt/mailserver/www/admin/padmin
  mkdir /mnt/mailserver/www/admin/padmin/templates_c
  chown -R apache. /mnt/mailserver/www/admin/padmin/templates_c
  setuppassword="$(pwgen 16 1)"
  echo '<?php $salt = md5(time() . mt_rand(0, 60000)); echo $salt . ":" . sha1($salt . ":" . $argv[1]); ?>' \
    > /root/hash.php
  setuphash=$(php /root/hash.php $setuppassword)
  printf "PostfixAdmin setup password\n   password: $setuppassword\n\n" >> /root/credentials
  db_postfix_password="$(pwgen 16 1)"
  printf "MariaDB\n   login: postfix\n   password: $db_postfix_password\n\n" >> /root/credentials
  aws s3 cp s3://$BUCKET_CONFIG/config.local.php /mnt/mailserver/www/admin/padmin
  sed -i "s/{database_password}/$db_postfix_password/" /mnt/mailserver/www/admin/padmin/config.local.php
  sed -i "s/{admin_email}/$ADMIN_EMAIL/" /mnt/mailserver/www/admin/padmin/config.local.php
  sed -i "s/{admindomain}/$ADMIN_DOMAIN/" /mnt/mailserver/www/admin/padmin/config.local.php
  sed -i "s/{setup_password}/$setuphash/" /mnt/mailserver/www/admin/padmin/config.local.php
  rm -r postfixadmin* hash.php
  #
  wget https://files.phpmyadmin.net/phpMyAdmin/5.0.2/phpMyAdmin-5.0.2-all-languages.tar.gz
  tar xzvf phpMyAdmin-5.0.2-all-languages.tar.gz > /dev/null
  mkdir /mnt/mailserver/www/admin/phpmyadmin
  cp -R phpMyAdmin-5.0.2-all-languages/* /mnt/mailserver/www/admin/phpmyadmin
  mkdir /mnt/mailserver/www/admin/phpmyadmin/tmp
  chown -R apache. /mnt/mailserver/www/admin/phpmyadmin/tmp
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
  mysql -u root -e "CREATE DATABASE postfix CHARACTER SET utf8 COLLATE utf8_general_ci;"
  mysql -u root -e "CREATE DATABASE roundcube CHARACTER SET utf8 COLLATE utf8_general_ci;"
  mysql -u root -e "GRANT ALL PRIVILEGES ON postfix.* TO 'postfix'@'localhost' identified by '$db_postfix_password';"
  mysql -u root -e "GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'pma'@'localhost' identified by '$pmapassword';"
  mysql -u root -e "GRANT ALL PRIVILEGES ON roundcube.* TO 'roundcube'@'localhost' identified by '$roundcubepassword';"
  mysql -u root -e "FLUSH PRIVILEGES;"
  #
  # creating postfix db
  php /mnt/mailserver/www/admin/padmin/public/upgrade.php
  /mnt/mailserver/www/admin/padmin/scripts/postfixadmin-cli admin add $ADMIN_EMAIL --superadmin 1 --active 1 \
    --password $postfixadminpassword --password2 $postfixadminpassword
  rm -r phpMyAdmin*
fi
rm -r /var/www
ln -s /mnt/mailserver/www /var/www
#
# Getting SSL certificates (certbot) and setting up DB backup
if [ ! -f $flag ]; then
  certbot certonly --standalone -d $MAIL_DOMAIN,$ADMIN_DOMAIN -m $ADMIN_EMAIL --agree-tos --non-interactive
  #certbot certonly --standalone -d $MAIL_DOMAIN,$ADMIN_DOMAIN --register-unsafely-without-email --agree-tos --non-interactive
  printf '#!/bin/bash\nsystemctl stop httpd\nsleep 5\n' > /etc/letsencrypt/renewal-hooks/pre/srv-stop
  printf '#!/bin/bash\nsystemctl restart httpd postfix dovecot\n' \
    > /etc/letsencrypt/renewal-hooks/post/srv-start
  chmod 744 /etc/letsencrypt/renewal-hooks/post/srv-start /etc/letsencrypt/renewal-hooks/pre/srv-stop
  mv /etc/letsencrypt /mnt/mailserver/etc
  printf '@reboot         root /usr/bin/cron-boot-runner\n' >> /etc/crontab
  printf '#15   1  *  *  * root /mnt/mailserver/automation/spotprices.py\n' >> /etc/crontab
  printf '15   3  *  *  6 root certbot renew -q\n' >> /etc/crontab
  mv /etc/crontab /mnt/mailserver/etc
fi
rm -f /etc/crontab
cp /usr/lib/systemd/system/crond.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/crond.service
ln -s /mnt/mailserver/etc/crontab /etc/crontab
rm -rf /etc/letsencrypt
ln -s /mnt/mailserver/etc/letsencrypt /etc/letsencrypt
#
# Spot instances instructions
if [ "$INSTANCE_LIFECYCLE" = 'Spot' ]; then
  AutoScalingGroup=$(aws autoscaling describe-auto-scaling-instances --instance-ids \
    `curl --silent http://169.254.169.254/latest/meta-data/instance-id 2>&1` \
    --region $AWS_REGION | jq -r '.AutoScalingInstances[].AutoScalingGroupName')
  printf "#%c/bin/bash\naws autoscaling set-desired-capacity --auto-scaling-group-name $AutoScalingGroup \
    --desired-capacity 1 --region $AWS_REGION\n" ! > /mnt/mailserver/automation/scale-in
  chmod 700 /mnt/mailserver/automation/scale-in
  aws s3 cp s3://$BUCKET_CONFIG/spot-instance-shutdown /mnt/mailserver/automation
  chmod 700 /mnt/mailserver/automation/spot-instance-shutdown
  sed -i "s/{AutoScalingGroup}/$AutoScalingGroup/" /mnt/mailserver/automation/spot-instance-shutdown
  sed -i "s/{region}/$AWS_REGION/" /mnt/mailserver/automation/spot-instance-shutdown
  aws s3 cp s3://$BUCKET_CONFIG/spotprices.py /mnt/mailserver/automation
  chmod 700 /mnt/mailserver/automation/spotprices.py
  sed -i "s/{region}/'$AWS_REGION'/" /mnt/mailserver/automation/spotprices.py
  sed -i "s/{chosenazs}/'$JOINED_AZS'/" /mnt/mailserver/automation/spotprices.py
  sed -i "s/{chosenec2types}/'$INSTANCE_TYPE1,$INSTANCE_TYPE2'/" /mnt/mailserver/automation/spotprices.py
  sed -i "s/{asg}/'$AutoScalingGroup'/" /mnt/mailserver/automation/spotprices.py
  sed -i "s/\([^0-9]*\)\(.*\)spotprices\(.*\)/\2spotprices\3/" /mnt/mailserver/etc/crontab
  aws s3 cp s3://$BUCKET_CONFIG/autoshutdown.service /etc/systemd/system
  aws s3 cp s3://$BUCKET_CONFIG/scale-in.service /etc/systemd/system
  systemctl enable autoshutdown scale-in
else
  sed -i "s/\(^[0-9].*\)spotprices\(.*\)/\#\1spotprices\2/" /mnt/mailserver/etc/crontab
fi
#
# Double instance service protection
aws s3 cp s3://$BUCKET_CONFIG/double-inst-prot.service /etc/systemd/system
aws s3 cp s3://$BUCKET_CONFIG/services-shutdown /usr/bin
sed -i "s/{instanceid}/$instid/" /usr/bin/services-shutdown
chmod 700 /usr/bin/services-shutdown
systemctl enable double-inst-prot
#
# Configuring postfix
if [ ! -f $flag ]; then
  cd ~
  aws s3 cp s3://$BUCKET_CONFIG/main.cf /etc/postfix
  aws s3 cp s3://$BUCKET_CONFIG/master.cf /etc/postfix
  aws s3 cp s3://$BUCKET_CONFIG/postfix-mysql.tar.gz /root
  tar -xzvf postfix-mysql.tar.gz -C /etc/postfix
  sed -i "s/{MainDomain}/$(echo "$DOMAIN_NAMES" | cut -d',' -f 1)/" /etc/postfix/main.cf
  sed -i "s/{MailDomain}/$MAIL_DOMAIN/" /etc/postfix/main.cf
  sed -i "s/{database_password}/$db_postfix_password/" /etc/postfix/mysql/*.cf
  mv /etc/postfix /mnt/mailserver/etc
  mv /var/spool/postfix /mnt/mailserver/spool
  rm postfix-mysql.tar.gz
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
  wget https://github.com/roundcube/roundcubemail/releases/download/1.4.7/roundcubemail-1.4.7-complete.tar.gz
  tar xzvf roundcubemail-1.4.7-complete.tar.gz > /dev/null
  mkdir /var/www/webmail
  cp -R /root/roundcubemail-1.4.7/* /var/www/webmail
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
  chown -R root:opendkim * && find . -type d -exec chmod 750 {} \; && find . -type f -exec chmod 640 {} \;
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
  chown -R root:opendkim * && find . -type d -exec chmod 750 {} \; && find . -type f -exec chmod 640 {} \;
  aws s3 cp s3://$BUCKET_CONFIG/dnsupd.py /root
  chmod 700 /root/dnsupd.py
  /root/dnsupd.py $DOMAIN_NAMES $DOMAIN_ZONE_IDS $EIP
  rm /root/dnsupd.py
fi
rm -f /etc/sysconfig/opendkim
ln -s /mnt/mailserver/etc/sysconfig/opendkim /etc/sysconfig/opendkim
sed -i "s#/var##" /etc/tmpfiles.d/opendkim.conf
cp /usr/lib/systemd/system/opendkim.service /etc/systemd/system
sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/opendkim.service
sed -i "s/PIDFile/#PIDFile/" /etc/systemd/system/opendkim.service
systemctl enable opendkim
