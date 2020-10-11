#!/bin/bash -xe
#
# Installing fail2ban
if [ "$FAIL2BAN" = 'ENABLED' ]; then
  flag=/mnt/mailserver/flag-f2b
  yum -y install fail2ban
  systemctl disable firewalld
  systemctl mask firewalld
  cp /usr/lib/systemd/system/fail2ban.service /etc/systemd/system
  sed -i "s/After=\(.*\)/After=\1 mnt-mailserver.mount/" /etc/systemd/system/fail2ban.service
  systemctl enable fail2ban
  if [ ! -f $flag ]; then
    mv /etc/fail2ban /mnt/mailserver/etc
    aws s3 cp s3://$BUCKET_CONFIG/jail.local /mnt/mailserver/etc/fail2ban
    aws s3 cp s3://$BUCKET_CONFIG/postfix-sasl.conf /mnt/mailserver/etc/fail2ban/filter.d
    sed -i "s/pop3,pop3s,imap,imaps,submission,465,sieve/smtp,465,submission,imap,imaps,pop3,pop3s/" \
      /mnt/mailserver/etc/fail2ban/jail.conf
  fi
  rm -rf /etc/fail2ban
  ln -s /mnt/mailserver/etc/fail2ban /etc/fail2ban
  printf "Fail2ban (re)deployed at $(date)\nDo not delete this file" > /mnt/mailserver/flag-f2b
else
  rm -rf /mnt/mailserver/etc/fail2ban
  rm -f /mnt/mailserver/flag-f2b
fi
