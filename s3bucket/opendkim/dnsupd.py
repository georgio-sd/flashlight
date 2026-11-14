#!/usr/bin/env python3
"""
Writes the server's mail DNS records to Route 53 (run by base.sh at every boot).

usage: dnsupd.py DOMAINS ZONE_IDS EIP MAIL_HOST
  DOMAINS   comma-separated mail domains; ZONE_IDS their Route 53 zones in the same order
  MAIL_HOST the mail server's host name, in the zone of the first domain

The records:
  mail._domainkey.<domain>  DKIM public key of /mnt/mailserver/etc/postfix/dkim/<domain>/mail.private,
                            always brought to this value
  <domain>                  SPF "v=spf1 ip4:<EIP> -all". An SPF record that already allows our address
                            (ip4:<EIP>) is the admin's own, e.g. with an include: of another mail service, and
                            stays as it is; any other one is replaced. Other TXT strings of the domain (site
                            verifications and the like) are always kept
  _dmarc.<domain>           "v=DMARC1; p=reject; sp=reject; adkim=r; aspf=r", only if the domain has no DMARC
                            record yet (the admin may have changed the policy or added a report address)
  <MAIL_HOST>               SPF of the host name itself (checked for bounces, which have an empty sender),
                            by the same rule as the domain's
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


def txt_values(zone_id, name):
    """the TXT values of a name as Route 53 holds them (quoted strings), or an empty list"""
    name = name.rstrip('.').lower() + '.'
    found = route53.list_resource_record_sets(HostedZoneId=zone_id, StartRecordName=name,
                                              StartRecordType='TXT', MaxItems='1')['ResourceRecordSets']
    if found and found[0]['Name'].lower() == name and found[0]['Type'] == 'TXT':
        return [r['Value'] for r in found[0].get('ResourceRecords', [])]
    return []


def plain(value):
    """a TXT value without its quotes (a long value is several quoted strings)"""
    return value.replace('" "', '').strip('"')


def txt_with_spf(zone_id, name, eip):
    """the name's TXT values with our SPF, and what happened to the SPF (for the log); an SPF that already allows
    our address stays as it is"""
    values = txt_values(zone_id, name)
    ours = 'v=spf1 ip4:%s -all' % eip
    for value in values:
        words = plain(value).lower().split()
        if words[:1] == ['v=spf1'] and ('ip4:' + eip in words or 'ip4:' + eip + '/32' in words):
            return values, 'unchanged' if plain(value) == ours else 'kept (the admin\'s own, allows our address)'
    others = [v for v in values if not plain(v).lower().startswith('v=spf1')]
    replaced = len(others) < len(values)
    return others + [txt(ours)], 'replaced (did not allow our address)' if replaced else 'created'


def upsert(name, values):
    return {'Action': 'UPSERT', 'ResourceRecordSet': {
        'Name': name, 'Type': 'TXT', 'TTL': TTL, 'ResourceRecords': [{'Value': v} for v in values]}}


def main():
    domains = sys.argv[1].split(',')
    zone_ids = sys.argv[2].split(',')
    eip, mail_host = sys.argv[3], sys.argv[4]

    for i, (domain, zone_id) in enumerate(zip(domains, zone_ids)):
        dkim_name = 'mail._domainkey.' + domain
        dkim = dkim_value(domain)
        dkim_now = txt_values(zone_id, dkim_name)
        spf, spf_status = txt_with_spf(zone_id, domain, eip)
        changes = [upsert(dkim_name, [dkim]), upsert(domain, spf)]
        status = ['DKIM ' + ('unchanged' if [plain(v) for v in dkim_now] == [plain(dkim)]
                             else 'replaced' if dkim_now else 'created'),
                  'SPF ' + spf_status]
        dmarc = [v for v in txt_values(zone_id, '_dmarc.' + domain) if plain(v).lower().startswith('v=dmarc1')]
        if dmarc:
            status.append('DMARC kept (' + plain(dmarc[0]) + ')')
        else:
            changes.append(upsert('_dmarc.' + domain, [txt('v=DMARC1; p=reject; sp=reject; adkim=r; aspf=r')]))
            status.append('DMARC created (p=reject)')
        if i == 0:
            host_spf, host_status = txt_with_spf(zone_id, mail_host, eip)
            changes.append(upsert(mail_host, host_spf))
            status.append('SPF of ' + mail_host + ' ' + host_status)
        route53.change_resource_record_sets(HostedZoneId=zone_id, ChangeBatch={'Changes': changes})
        print('dnsupd: %s: %s' % (domain, '; '.join(status)))


if __name__ == '__main__':
    main()
