#!/bin/bash -xe
#
# Flashlight user script (optional): your own additions to the server, e.g. extra packages or settings.
#
# How it is used:
# - Write your commands below and upload this file as "user-script.sh" to the root of the config bucket
#   (the S3Bucket output of the stage 1 stack): aws s3 cp user-script.sh s3://<config bucket>/
#   It is not in the stage 1 Files list on purpose, so a stage 1 update never overwrites your script.
# - Every new instance runs it once, as root, right after base.sh (before the final reboot): after each
#   install, spot replacement, scheduled rebuild and stack update. Write it so it can run again safely.
# - The stack's variables are available ($MAIL_DOMAIN, $ADMIN_DOMAIN, $DOMAIN_NAMES, $ADMIN_EMAIL,
#   $BUCKET_CONFIG, $TIMEZONE ...); /mnt/mailserver (EFS) is mounted.
# - Its output goes to the install log: /mnt/mailserver/log/install/<date>-<instance id>.log
# - With -e above, the script stops at the first failing command; the server install itself is not affected.
#
# Your commands:

