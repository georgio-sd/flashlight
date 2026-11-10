#!/usr/bin/env python3
# -*- coding: utf-8 -*-
################################################################################################
# Weekly spot price check (cron, Saturday->Sunday night).
# Compares the 7-day average price of this instance's pool (instance type + zone) with every pool
# the Auto Scaling group may use. If this pool is THRESHOLD% or more above the cheapest one,
# the instance asks the ASG to replace it (replace-instance). The ASG then picks the new pool
# by its own allocation strategy.
#
# usage: spotprices.py                     normal run (from cron)
#        spotprices.py --dry-run           log the decision, don't replace
#        spotprices.py --dry-run --types t3a.small,t3.small --zones us-west-2a,us-west-2b
#                                          test on an instance that isn't in an ASG
################################################################################################
import argparse
import datetime
import subprocess
import urllib.request

import boto3

THRESHOLD = 30   # percent above the cheapest pool that triggers a replacement
DAYS = 7         # averaging window
LOG = '/mnt/mailserver/log/instance.log'
REPLACE = '/mnt/mailserver/automation/replace-instance'


def imds(path):
    req = urllib.request.Request('http://169.254.169.254/latest/api/token', method='PUT',
                                 headers={'X-aws-ec2-metadata-token-ttl-seconds': '60'})
    token = urllib.request.urlopen(req, timeout=5).read().decode()
    req = urllib.request.Request('http://169.254.169.254/latest/meta-data/' + path,
                                 headers={'X-aws-ec2-metadata-token': token})
    return urllib.request.urlopen(req, timeout=5).read().decode()


args = argparse.ArgumentParser()
args.add_argument('--dry-run', action='store_true')
args.add_argument('--types')
args.add_argument('--zones')
args = args.parse_args()

instance_id = imds('instance-id')
region = imds('placement/region')
current = imds('instance-type') + '/' + imds('placement/availability-zone')


def log(event, message):
    line = f'{datetime.datetime.now():%Y-%m-%d %H:%M:%S} {instance_id} {current:<22} {event:<7} {message}'
    print(line)
    with open(LOG, 'a') as f:
        f.write(line + '\n')


# Instance types and zones the ASG can use
if args.types and args.zones:
    types, zones = args.types.split(','), args.zones.split(',')
else:
    asg = boto3.client('autoscaling', region_name=region)
    found = asg.describe_auto_scaling_instances(InstanceIds=[instance_id])['AutoScalingInstances']
    if not found:
        log('ERROR', 'this instance is not in an Auto Scaling group, nothing to compare')
        raise SystemExit(1)
    group = asg.describe_auto_scaling_groups(
        AutoScalingGroupNames=[found[0]['AutoScalingGroupName']])['AutoScalingGroups'][0]
    zones = group['AvailabilityZones']
    overrides = group.get('MixedInstancesPolicy', {}).get('LaunchTemplate', {}).get('Overrides', [])
    types = [o['InstanceType'] for o in overrides if 'InstanceType' in o]

# Time-weighted average price of every pool over the last DAYS days
ec2 = boto3.client('ec2', region_name=region)
now = datetime.datetime.now(datetime.timezone.utc)
start = now - datetime.timedelta(days=DAYS)
averages = {}
for zone in zones:
    history = []
    for page in ec2.get_paginator('describe_spot_price_history').paginate(
            InstanceTypes=types, ProductDescriptions=['Linux/UNIX'], AvailabilityZone=zone,
            StartTime=start, EndTime=now):
        history += page['SpotPriceHistory']
    for itype in types:
        points = sorted((p['Timestamp'], float(p['SpotPrice'])) for p in history if p['InstanceType'] == itype)
        total = weighted = 0.0
        for i, (since, price) in enumerate(points):
            until = points[i + 1][0] if i + 1 < len(points) else now
            seconds = (until - max(since, start)).total_seconds()
            if seconds > 0:
                total += seconds
                weighted += price * seconds
        if total:
            averages[f'{itype}/{zone}'] = weighted / total

if current not in averages:
    log('ERROR', f'no {DAYS}-day spot price for the current pool; pools found: {", ".join(averages) or "none"}')
    raise SystemExit(1)

best = min(averages, key=averages.get)
difference = (averages[current] / averages[best] - 1) * 100
table = '\n'.join(f'{"":>30}{pool:<24}{price:.4f}{"  <- current" if pool == current else ""}'
                  for pool, price in sorted(averages.items(), key=lambda item: item[1]))

if difference >= THRESHOLD:
    reason = (f'price: current pool {averages[current]:.4f} is {difference:.0f}% above '
              f'{best} {averages[best]:.4f} ({DAYS}-day average, threshold {THRESHOLD}%)')
    log('CHECK', f'{DAYS}-day average USD/hour, replacing:\n{table}')
    if args.dry_run:
        log('CHECK', 'dry run: would replace this instance, reason=' + reason)
    else:
        subprocess.run([REPLACE, reason])
else:
    log('CHECK', f'no action: current pool is {difference:.0f}% above the cheapest '
                 f'(threshold {THRESHOLD}%), {DAYS}-day average USD/hour:\n{table}')
