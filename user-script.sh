#!/bin/bash -xe
#
# Squid install
yum install -y squid
sed -i "s/# should be allowed/# should be allowed\nacl sam_spectrum src 66\.25\.51\.4\/32/" /etc/squid/squid.conf
sed -i "s/# should be allowed/# should be allowed\nacl rem src 37\.19\.73\.162\/32/" /etc/squid/squid.conf
sed -i "s/# should be allowed/# should be allowed\nacl rem src 83\.237\.9\.26\/32/" /etc/squid/squid.conf
sed -i "s/# should be allowed/# should be allowed\nacl rem src 213\.108\.220\.120\/32/" /etc/squid/squid.conf
sed -i "s/# should be allowed/# should be allowed\nacl rem src 91\.188\.0\.0\/16/" /etc/squid/squid.conf
sed -i "s/# from where browsing should be allowed/# from where browsing should be allowed\nhttp_access allow sam_spectrum/" /etc/squid/squid.conf
sed -i "s/# from where browsing should be allowed/# from where browsing should be allowed\nhttp_access allow rem/" /etc/squid/squid.conf
sed -i -e '$a\\n# Hide proxy\nforwarded_for delete\nvia off' /etc/squid/squid.conf
systemctl enable squid
