#!/usr/bin/env python3
"""
Writes the server's mail DNS records to Route 53 (run by base.sh at every boot).

usage: dnsupd.py DOMAINS ZONE_IDS EIP MAIL_HOST
  DOMAINS   comma-separated mail domains; ZONE_IDS their Route 53 zones in the same order
  MAIL_HOST the mail server's host name, in the zone of the first domain

The records belong to the server and are always brought to these values:
  mail._domainkey.<domain>  DKIM public key of /mnt/mailserver/etc/postfix/dkim/<domain>/mail.private
  <domain>                  SPF "v=spf1 ip4:<EIP> -all"; other TXT strings of the domain (site
                            verifications and the like) are kept, only the v=spf1 string is replaced
  _dmarc.<domain>           "v=DMARC1; p=reject; sp=reject; adkim=r; aspf=r"
  <MAIL_HOST>               SPF of the host name itself (checked for bounces, which have an empty sender)
"""
import base64
import subprocess
import sys

import boto3

TTL = 3600
route53 = boto3.client('route53')


def txt(*strings):
    """Route 53 TXT value: each string quoted, at most 255 characters per string"""
    return ' '.join('"%s"' % s for s in strings)


def dkim_value(domain):
    # public key straight from the private key (base64 of the DER SubjectPublicKeyInfo)
    der = subprocess.run(['openssl', 'pkey', '-in', '/mnt/mailserver/etc/postfix/dkim/%s/mail.private' % domain,
                          '-pubout', '-outform', 'DER'], check=True, capture_output=True).stdout
    record = 'v=DKIM1; k=rsa; p=' + base64.b64encode(der).decode()
    return txt(*[record[i:i + 255] for i in range(0, len(record), 255)])


def apex_txt_with_spf(zone_id, domain, spf):
    """the domain's TXT values with any v=spf1 string replaced by ours"""
    name = domain.rstrip('.') + '.'
    found = route53.list_resource_record_sets(HostedZoneId=zone_id, StartRecordName=name,
                                              StartRecordType='TXT', MaxItems='1')['ResourceRecordSets']
    values = []
    if found and found[0]['Name'] == name and found[0]['Type'] == 'TXT':
        values = [r['Value'] for r in found[0]['ResourceRecords']
                  if not r['Value'].strip('"').lower().startswith('v=spf1')]
    return values + [txt(spf)]


def upsert(name, values):
    return {'Action': 'UPSERT', 'ResourceRecordSet': {
        'Name': name, 'Type': 'TXT', 'TTL': TTL, 'ResourceRecords': [{'Value': v} for v in values]}}


def main():
    domains = sys.argv[1].split(',')
    zone_ids = sys.argv[2].split(',')
    eip, mail_host = sys.argv[3], sys.argv[4]
    spf = 'v=spf1 ip4:%s -all' % eip

    for i, (domain, zone_id) in enumerate(zip(domains, zone_ids)):
        changes = [
            upsert('mail._domainkey.' + domain, [dkim_value(domain)]),
            upsert(domain, apex_txt_with_spf(zone_id, domain, spf)),
            upsert('_dmarc.' + domain, [txt('v=DMARC1; p=reject; sp=reject; adkim=r; aspf=r')]),
        ]
        if i == 0:
            changes.append(upsert(mail_host, [txt(spf)]))
        route53.change_resource_record_sets(HostedZoneId=zone_id, ChangeBatch={'Changes': changes})
        print('dnsupd: %s: DKIM, SPF, DMARC%s updated' % (domain, ', SPF of ' + mail_host if i == 0 else ''))


if __name__ == '__main__':
    main()
