#!/usr/bin/env python3.9
# -*- coding: utf-8 -*-
################################################################################################
# dkim dns records updater
# Aug 8 2020
################################################################################################
import boto3
import sys
import re
import time
client = boto3.client('route53')

DomainNames = sys.argv[1].split(',')
DomainZoneIDs = sys.argv[2].split(',')
ElasticIP = sys.argv[3]

NumberOfDomains = len(DomainZoneIDs)

i = 0
while i < NumberOfDomains:
   dkimfile = open("/etc/postfix/dkim/" + DomainNames[i] + "/mail.txt","r")
   dkimval = re.search(r'"(.*?)"', dkimfile.readline()).group(1)
   dkimval = '"' + dkimval + re.search(r'"(.*?)"', dkimfile.readline()).group(1) + '"'
   dkimfile.close()
   response = client.change_resource_record_sets(
      HostedZoneId=DomainZoneIDs[i],
      ChangeBatch={
         'Changes': [
            {
               'Action': 'UPSERT',
               'ResourceRecordSet': {
                  'Name': 'mail._domainkey.' + DomainNames[i],
                  'ResourceRecords': [
                     {
                        'Value': dkimval
                     }
                  ],
                  'Type': 'TXT',
                  'TTL': 10800
               }
            },
            {
               'Action': 'UPSERT',
               'ResourceRecordSet': {
                  'Name': DomainNames[i],
                  'ResourceRecords': [
                     {
                        'Value': '"v=spf1 ip4:' + ElasticIP + ' ~all"'
                     }
                  ],
                  'Type': 'TXT',
                  'TTL': 10800
               }
            },
            {
               'Action': 'UPSERT',
               'ResourceRecordSet': {
                  'Name': '_dmarc.' + DomainNames[i],
                  'ResourceRecords': [
                     {
                        'Value': '"v=DMARC1; p=quarantine; aspf=r; adkim=r; pct=100"'
                     }
                  ],
                  'Type': 'TXT',
                  'TTL': 10800
               }
            }
         ]
      }
   )
   time.sleep(0.21)
   i += 1
