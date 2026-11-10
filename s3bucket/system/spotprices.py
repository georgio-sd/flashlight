#!/usr/bin/env python3
# -*- coding: utf-8 -*-
################################################################################################
# Spot instance deployment planner
# Aug 8 2020
################################################################################################
import boto3
import urllib.request
import sys
import os
import time
from datetime import datetime

def write_log(data):
  log_file = open(r"/mnt/mailserver/log/spotprices.log","a")
  log_file.write(data + '\n')
  log_file.close()

InstanceType = urllib.request.urlopen('http://169.254.169.254/latest/meta-data/instance-type').read().decode()
InstanceAZ = urllib.request.urlopen('http://169.254.169.254/latest/meta-data/placement/availability-zone').read().decode()

Region = {region}
ChosenAZs = {chosenazs}.split(',')
ChosenEC2Types = {chosenec2types}.split(',')
ASG = {asg}
client = boto3.client('ec2', region_name=Region)

started_time = datetime.now()
write_log(started_time.strftime("\n[%Y-%m-%d] [%H:%M:%S] Checking spot prices..."))

results = []
for EC2Type in ChosenEC2Types:
  if EC2Type != 'None':
    for AZ in ChosenAZs:
      prices = client.describe_spot_price_history(InstanceTypes=[EC2Type],
                                                  ProductDescriptions=['Linux/UNIX', 'Linux/UNIX (Amazon VPC)'],
                                                  AvailabilityZone=AZ,
                                                  MaxResults=1)
      for price in prices["SpotPriceHistory"]:
        results.append((price["InstanceType"], price["AvailabilityZone"], float(price["SpotPrice"]), price["Timestamp"].strftime("%Y-%m-%d")))

i = 0
while i < len(results):
  if (results[i][0] == InstanceType) and (results[i][1] == InstanceAZ):
    InstancePrice = results[i][2]
  i += 1

shutdown = 0
write_log('You are paying for ' + InstanceType + ' in ' + InstanceAZ + ': $' + str(round(InstancePrice, 4)))
for result in results:
  if ((InstancePrice * 100 /result[2]) - 100) >= 15:
    shutdown = 1
  write_log('    ' + result[0] + ' in ' + result[1] + ': $' + str(round(result[2], 4)) + ' ' + str(round((InstancePrice * 100 /result[2]) - 100)) + '% better offer')

if (shutdown == 1):
  if not (os.path.isfile('/tmp/shutdown-in-progress')):
    os.system('touch /tmp/shutdown-in-progress')
    write_log('[!] Relaunching Mail Server for better price...')
    os.system('aws autoscaling set-desired-capacity --auto-scaling-group-name ' + ASG + ' --desired-capacity 2 --region ' + Region)
    time.sleep(120)
    os.system('systemctl stop mysql postfix dovecot')
    os.system('aws autoscaling set-desired-capacity --auto-scaling-group-name ' + ASG + ' --desired-capacity 1 --region ' + Region)
    os.system('systemctl stop httpd opendkim php-fpm')
  else:
    write_log('Mail server is about to shutdown, no action taken...')
