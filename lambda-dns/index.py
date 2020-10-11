import json
import logging
import cfnresponse
import boto3
import requests
import time
logger = logging.getLogger()
logger.setLevel(logging.INFO)
client = boto3.client('route53')
from botocore.config import Config
img_config = Config(region_name = 'us-west-2')
client_src_img = boto3.client('ec2', config = img_config)
client_dest_img = boto3.client('ec2')

def lambda_handler(event, context):
  if (event['RequestType'] == 'Create') or (event['RequestType'] == 'Update'):
    logger.info('Event Received by Handler : ' + json.dumps(event))

    try:
      images = client_src_img.describe_images(
        ExecutableUsers=[ 'all' ],
        Filters=[
          {
            'Name': 'description',
            'Values': [ 'Mailserver:img_a' ]
          }
        ],
        Owners=['112904279782']
      )
      if len(images['Images']) == 0:
        logger.info('Error: Source image not found')

      dt = "2000-01-01T00:00:00.000Z"
      for image in images['Images']:
        if dt < image['CreationDate']:
          dt = image['CreationDate']
          ImageId = image['ImageId']
          ImageName = image['Name']
          logger.info('Image name: ' + ImageName)
          logger.info('Image date: ' + dt)

      images = client_dest_img.describe_images(
        Filters=[
          {
            'Name': 'name',
            'Values': [ ImageName ]
          }
        ],
        Owners=['self']
      )

      if len(images['Images']) == 0:
        response = client_dest_img.copy_image(
           Name = ImageName,
           Description = 'Mailserver:img_a',
           SourceImageId = ImageId,
           SourceRegion = 'us-west-2'
        )
        LocalImageId = response['ImageId']
      else:
        for image in images['Images']:
          LocalImageId = image['ImageId']

      hostZoneIDs = event['ResourceProperties']['ZoneIDs'].split(',')
      DomainNames = []
      DomainZoneIDs = []
      DomainNames.append(client.get_hosted_zone(Id=event['ResourceProperties']['MainZoneID'])['HostedZone']['Name'])
      DomainZoneIDs.append(event['ResourceProperties']['MainZoneID'])

      try:
        hostZoneIDs.remove(event['ResourceProperties']['MainZoneID'])
      except ValueError:
        pass

      while hostZoneIDs:
        hostZoneID = hostZoneIDs.pop(0)
        DomainNames.append(client.get_hosted_zone(Id=hostZoneID)['HostedZone']['Name'])
        DomainZoneIDs.append(hostZoneID)

      AdminDNSRecord = 'admin' + '.' + DomainNames[0]
      MailDNSRecord = 'mail' + '.' + DomainNames[0]
      MXDNSRecord = '10 ' +  MailDNSRecord
      MailServerIP = event['ResourceProperties']['ElasticIP']

      response = client.change_resource_record_sets(
          HostedZoneId=DomainZoneIDs[0],
          ChangeBatch={
              'Changes': [
                  {
                      'Action': 'UPSERT',
                      'ResourceRecordSet': {
                          'Name': AdminDNSRecord,
                          'ResourceRecords': [
                              {
                                  'Value': MailServerIP
                              }
                          ],
                          'Type': 'A',
                          'TTL': 10800
                      }
                  },
                  {
                      'Action': 'UPSERT',
                      'ResourceRecordSet': {
                          'Name': MailDNSRecord,
                          'ResourceRecords': [
                              {
                                  'Value': MailServerIP
                              }
                          ],
                          'Type': 'A',
                          'TTL': 10800
                      }
                  },
                  {
                      'Action': 'UPSERT',
                      'ResourceRecordSet': {
                          'Name': DomainNames[0],
                          'ResourceRecords': [
                              {
                                  'Value': MXDNSRecord
                              }
                          ],
                          'Type': 'MX',
                          'TTL': 10800
                      }
                  }
              ]
          }
      )
      time.sleep(0.21)

      NumberOfDomains = len(DomainZoneIDs)
      i = 1
      while i < NumberOfDomains:
        response = client.change_resource_record_sets(
            HostedZoneId=DomainZoneIDs[i],
            ChangeBatch={
                'Changes': [
                    {
                        'Action': 'UPSERT',
                        'ResourceRecordSet': {
                            'Name': DomainNames[i],
                            'ResourceRecords': [
                                {
                                    'Value': MXDNSRecord
                                }
                            ],
                            'Type': 'MX',
                            'TTL': 10800
                        }
                    }
                ]
            }
        )
        time.sleep(0.21)
        i += 1

      responseData = { 'DomainNames' : ','.join(DomainNames).rstrip('.').replace('.,', ','),
                       'DomainZoneIDs' : ','.join(DomainZoneIDs), 'NumberOfDomains' : NumberOfDomains,
                       'DNSRecAdmin' : AdminDNSRecord.rstrip('.'), 'DNSRecMail' : MailDNSRecord.rstrip('.'),
                       'ImageId' : LocalImageId }
    except:
      responseData = { 'DomainNames' : 'Something went wrong', 'DomainZoneIDs' : 'Something went wrong',
                       'NumberOfDomains' : 0, 'DNSRecAdmin' : 'Something went wrong',
                       'DNSRecMail' : 'Something went wrong', 'ImageId' : 'Something went wrong' }

    logger.info('CFN Event Type: (Create)')
    cfnresponse.send(event, context, cfnresponse.SUCCESS, responseData)
  else:
    logger.info('CFN Event Type: (Other)')
    responseData = {}
    cfnresponse.send(event, context, cfnresponse.SUCCESS, responseData)
