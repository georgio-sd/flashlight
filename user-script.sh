#!/bin/bash -xe
#
# Squid install
yum install -y squid
sed -i "s/# should be allowed/# should be allowed\nacl sam_spectrum src 76\.187\.0\.201\/32/" /etc/squid/squid.conf
sed -i "s/# should be allowed/# should be allowed\nacl rem_work src 83\.237\.9\.26\/32/" /etc/squid/squid.conf
sed -i "s/# from where browsing should be allowed/# from where browsing should be allowed\nhttp_access allow sam_spectrum/" /etc/squid/squid.conf
sed -i "s/# from where browsing should be allowed/# from where browsing should be allowed\nhttp_access allow rem_work/" /etc/squid/squid.conf
systemctl enable squid
