# Installing Flashlight

This guide is for the person who installs a Flashlight mail server and looks after it. It assumes you know your
way around the AWS console and CloudFormation, DNS, and a Linux server over SSH. How the server works inside is
described in [How the server works](ARCHITECTURE.md).

The whole installation takes about half an hour, most of it waiting for AWS.

## Before you start

1. **An AWS account and a region.** Any region with at least two Availability Zones works; three are
   recommended. Create both stacks in the same region: stage 2 reads the outputs of stage 1, and CloudFormation
   shares them only within a region. Route 53 is global, so your hosted zones work with any region; Flashlight
   copies its server image into the region you pick.
2. **Your mail domains in Route 53.** Each domain must be a public hosted zone in the same AWS account, and
   the domain's registrar must point to the Route 53 name servers. One of them is the **main domain**: the
   server's own names are made from it (`mail.<main domain>` and `admin.<main domain>` by default).
   Flashlight creates the MX, SPF, DKIM and DMARC records itself. If the domain already receives mail
   elsewhere, its MX record moves to Flashlight as soon as stage 1 is created (so create stage 2 right after
   it), and its SPF record is replaced by Flashlight's.
   If you have just created the hosted zone or changed the domain's name servers at the registrar, wait until
   the change is visible before installing (`dig NS <domain>` shows the Route 53 servers); it can take up to
   48 hours. Until then Let's Encrypt can't validate the domain and the certificate isn't issued.
3. **Outgoing mail allowed.** AWS blocks port 25 on new accounts. Ask AWS Support to lift it ("Request to
   remove email sending limitations") and wait for the answer: without it the server receives mail but can't
   send any to other servers. Reverse DNS of the server's address is set up by Flashlight.
4. **An EC2 key pair** in the region, for SSH access to the server (EC2 console, Key Pairs).
5. **Recommended: a Spamhaus key.** Spamhaus Blocklists via DNS Query are free for small businesses
   ([sign up](https://www.spamhaus.com/data-access/free-data-query-service/)). Spamhaus answers queries from
   AWS only with a key. The spam filter works without it, but noticeably better with it.
6. **The templates** of the Flashlight release: `1-dns-preset.yaml`, `2-deployment.yaml` and
   `x-maintenance.yaml`.

## Stage 1: address and DNS

In the CloudFormation console, **Create stack** with `1-dns-preset.yaml`. The stack name is up to you;
stage 2 refers to it, and its default there is `MailServerDnsPreset`.

| Parameter | What to enter |
|---|---|
| MainZoneID | The hosted zone of your main domain |
| ZoneIDs | All your mail domains, the main one included |
| AdminSubDomain | Name of the admin site, `admin` by default: `admin.<main domain>` |
| MailSubDomain | Name of the mail server and webmail, `mail` by default: `mail.<main domain>` |
| Updater | Leave as it is. Switching it between Even and Odd re-runs the stack's setup without changing anything else |

The stack takes a few minutes; the first time in an account up to 15, while the server image is copied. It
creates:

- the Elastic IP, the server's permanent address, with reverse DNS pointing to `mail.<main domain>`;
- the A records of `mail.` and `admin.`, and an MX record in every mail domain;
- the config bucket with the installer files of the release, copied from the public Flashlight bucket;
- the server image (AMI) for your region.

If the output `ImageStatus` says the image is still being copied, wait until it is available (EC2 console,
AMIs) before you create stage 2.

Its **Outputs** tab shows what it did: the address (`Eip`), the config bucket (`S3Bucket`), the image
(`ImageId`), the DNS records, and links to the logs of its two Lambda functions.

## Stage 2: the server

**Create stack** with `2-deployment.yaml`. Name it as you like (`MailServer`, for example).

### Basic settings

| Parameter | Default | What it does |
|---|---|---|
| DnsPreset | MailServerDnsPreset | The name of your stage 1 stack |
| AdminEmail | | Your e-mail address. It becomes the PostfixAdmin login, receives the Let's Encrypt notices and Flashlight's warnings. Use an address outside the new server, so the warnings reach you when the server has problems |
| TimeZone | America/Chicago | The server's time zone ([list](https://www.php.net/manual/en/timezones.php)) |
| CertificateMode | production | `production`: a trusted Let's Encrypt certificate. `staging`: an untrusted test certificate, for test installs; Let's Encrypt allows only a few production certificates for the same names per week. A test install can be switched to production later with a stack update |
| KeyName | | Your EC2 key pair |

### Mail protection

| Parameter | Default | What it does |
|---|---|---|
| Fail2ban | ENABLED | Bans IP addresses for a while after repeated failed logins (SSH, mail, webmail) |
| Antispam | ENABLED | The spam filter (Rspamd). Spam goes to the Junk folder, obvious spam is refused. Also turns on the limits for outgoing mail and the warnings about compromised mailboxes |
| SpamhausDQSKey | empty | Your Spamhaus key (hidden in the console). Needs Antispam |
| AttachmentPolicy | Score | Attachments of risky file types. `Score`: they only add to the spam score. `Gmail`: mail with a file type Gmail blocks (exe, js, bat, iso, lnk...) is refused, also inside archives; encrypted archives go to Junk. `Strict`: Gmail plus more Windows file types from Outlook's blocked list (reg, url, inf, vhdx, PowerShell...) |
| Antivirus | DISABLED | Virus scanning (ClamAV): mail with a virus is refused. Needs Antispam and a medium or larger instance type (about 1 GB of memory, 2 GB for a few seconds while new signatures load) |

### Network

| Parameter | Default | What it does |
|---|---|---|
| VpcCidr | 10.0.0.0/16 | Address range of the server's network. Change it only if you plan to connect it to another network with the same range |
| SubnetMask | 8 | Subnet size: 8 = /24 |
| AZoneNames | | Three Availability Zones of the region (two with TwoAZoneConf) |
| TwoAZoneConf | DISABLED | ENABLED only in regions with two zones |

Don't change the network settings after the install.

### Server

| Parameter | Default | What it does |
|---|---|---|
| InstanceType | t3.small | Main instance type. t3.small (2 GB) is enough for a small company with the spam filter; t3.medium (4 GB) or larger for the antivirus or for many users |
| InstanceType2 | t3a.small | A second, interchangeable type of the same size as InstanceType (t3.medium with t3a.medium; the template checks it). With Spot it gives the Auto Scaling group more capacity pools to choose from. With On-Demand the server runs on InstanceType, and on this one only when AWS has no capacity of the first. `None`: only InstanceType. Use it with a Reserved Instance (which applies to On-Demand only), so the server never runs on a type the reservation doesn't cover |
| InstanceLifecycle | Spot | `Spot` costs much less; AWS may take the instance back, and a new one takes over within about ten minutes. `On-Demand` is never taken back |
| RebuildAfterDays | 30 | The server is rebuilt from scratch on current packages once it is this old, on the next Saturday-to-Sunday night at 03:15 (about 4 minutes without mail). This is how it gets security fixes and updates: the operating system, and the programs installed from its repositories (Postfix, Dovecot, Rspamd, ClamAV and others). The web applications (Roundcube, PostfixAdmin, phpMyAdmin) come with the Flashlight release and are updated by [upgrades](UPGRADING.md). 0 turns it off |
| DiskVolumeSize | 10 | The server's disk in GiB. 8 is enough without swap; with swap at least 10 for small and medium types, 12 for large and xlarge |
| Swap | ENABLED | A swap file for short memory peaks, sized automatically (half the memory, at most 4 GB) |

### Mail storage (EFS)

| Parameter | Default | What it does |
|---|---|---|
| MailStorageThroughputMode | bursting | `bursting` costs nothing extra and suits a mail server. `elastic` only if constant heavy traffic uses up the burst credits |
| MailStorageLifecyclePolicy | AFTER_30_DAYS | Files not opened for this long move to the cheaper Infrequent Access class, and come back on first access |
| MailStorageBackupPolicy | DISABLED | ENABLED: daily backups of the whole storage with AWS Backup (billed by AWS) |

The template checks the combinations before it creates anything: a Spamhaus key or the antivirus without the
spam filter, the antivirus on a small instance type, or swap on a disk that is too small are refused with an
explanation.

### What happens next

CloudFormation creates the network and the storage, then the server. The server updates its operating system,
installs and configures everything, gets its certificate, and reboots. When its services are up, it reports
to CloudFormation and the stack becomes **CREATE_COMPLETE**, usually 10 to 15 minutes after you started.

If the installation fails, the stack rolls back within a few minutes. The install log is then in the config
bucket, in `install-logs/` (see [Troubleshooting](#troubleshooting)).

## First login

Log in to the server over SSH with your key:

```
ssh -i your-key.pem ec2-user@mail.<main domain>
```

The generated passwords are in `/root/credentials`:

```
sudo cat /root/credentials
```

| Entry | Where it is used |
|---|---|
| Admin web access | The admin site `https://admin.<main domain>/`: user `admin` and its password. The browser asks for it before any of the admin tools |
| PostfixAdmin superadmin | `https://admin.<main domain>/padmin`: login is your AdminEmail |
| PostfixAdmin setup password | PostfixAdmin's setup page, rarely needed |
| MariaDB | phpMyAdmin, `https://admin.<main domain>/myadmin` |
| Rspamd web interface | The spam filter, `https://admin.<main domain>/rspamd/` (with the spam filter) |

The file lives on the mail storage, so it stays the same when the server is replaced. Keep a copy of it in
your password manager.

### Mailboxes

All your mail domains are already in PostfixAdmin, each with the `abuse@` and `postmaster@` aliases. Create
the mailboxes in PostfixAdmin (**Virtual List**, **Add Mailbox**), and set their quotas there.

### Mail programs

| | Server | Port | Security |
|---|---|---|---|
| Incoming (IMAP) | `mail.<main domain>` | 993 | SSL/TLS |
| | | 143 | STARTTLS |
| Outgoing (SMTP) | `mail.<main domain>` | 587 | STARTTLS |
| | | 465 | SSL/TLS |

The login is the full e-mail address, with its password. Use `mail.<main domain>` for mailboxes of every
domain: the certificate is issued for that name. Webmail is at `https://mail.<main domain>/`. Messages can be
up to 20 MB.

### Checking that it works

1. Send a message from a new mailbox to an outside address (Gmail, for example) and back.
2. In Gmail, **Show original** of the received message should show SPF, DKIM and DMARC as PASS.
3. `sudo tail /mnt/mailserver/log/instance.log` shows the server's events; the last one after the install is
   `READY`.

## Everyday tasks

### Adding or removing a mail domain

The domain list belongs to stage 1, and stage 1 can't change it while stage 2 uses it. So the server goes into
maintenance mode for a moment (about 15 minutes without mail service; other servers retry their deliveries):

1. Create the new domain's hosted zone in Route 53, if it isn't there yet.
2. Update the stage 2 stack with `x-maintenance.yaml` (**Replace current template**), keeping the parameters.
   The server is shut down; all data stay.
3. Update the stage 1 stack with the same `1-dns-preset.yaml`, adding the zone to **ZoneIDs** (or removing it).
4. Update the stage 2 stack with `2-deployment.yaml`, keeping the parameters.

The new server adds the domain to PostfixAdmin, creates its DKIM key and its MX, SPF, DKIM and DMARC records.
A removed domain loses Flashlight's DNS records and its DKIM key, but stays in PostfixAdmin with its mailboxes:
delete it there if you no longer need them.

### What can't be changed after the install

- **The main domain** (MainZoneID). The server's names, its certificate and its reverse DNS are made from it. Other
  mail domains can be added and removed at any time (above), the main one stays.
- **The names of the server** (MailSubDomain, AdminSubDomain). The certificate is issued once for these names, and
  mail programs and DNS records point to them.
- **The network settings** of stage 2 (VpcCidr, SubnetMask, AZoneNames, TwoAZoneConf).

To change any of these, install a new server and move the data to it.

### Changing the server's settings

Most stage 2 parameters can be changed with a stack update (**Use current template**): the instance type,
Spot or On-Demand, the spam filter, the antivirus and the others. The update replaces the server with a new
one that has the same data; mail is down for a few minutes. If the new server fails to install, the stack rolls
back and the old one goes on working.

**Lower prices without Spot.** A 1- or 3-year Reserved Instance or Savings Plan for your instance type, bought in
the AWS console, lowers the On-Demand price close to the Spot level. Set InstanceLifecycle to On-Demand and
InstanceType2 to None, so the server always runs on the reserved type.

### fail2ban

An address that failed to log in too often is banned for a while. To unban one:

```
sudo fail2ban-client unban 203.0.113.5
```

To never ban your office address, put it into `/mnt/mailserver/etc/fail2ban/custom.local`:

```
[DEFAULT]
ignoreip = 127.0.0.1/8 203.0.113.5
```

and run `sudo systemctl restart fail2ban`.

### The spam filter

- **Users teach it.** Moving a message into Junk teaches the filter that it is spam; moving it out of Junk
  teaches it that it isn't. In webmail, the **Spam** and **Not spam** buttons do the same. This works from any
  mail program.
- **Why did a message get its verdict?** The **History** tab of the Rspamd web interface
  (`https://admin.<main domain>/rspamd/`) shows each message with the checks that fired and their points.
  A message with 6 points or more goes to Junk; from 15 points it is refused.
- **Partner whitelist.** Mail of a partner domain that keeps landing in Junk: add the domain, one per line,
  on the **Configuration** tab of the web interface, list **whitelist-domains.map**. The mail must really come
  from that domain (its SPF or DKIM must pass), so a forged sender doesn't get through. Mail with a virus or a
  blocked attachment is still refused.

### Limits on outgoing mail

With the spam filter on, Flashlight limits what each user may send, so a stolen password can't be used to send
spam in bulk before you notice:

| Limit | Default | Over the limit |
|---|---|---|
| Messages per user, hourly | 30 in a row, then 30 an hour | The message is refused for now ("try again later") |
| Messages per user, daily | 300 in a row, then 300 a day | The same |
| Recipients of one message | 20 | The extra recipients are refused |

Each limit is an allowance that refills at a steady pace: a user who hasn't sent anything for a while can send
30 messages in a row, and after that one more every two minutes (30 an hour). So the most a mailbox can send is
about 60 messages in its first hour and 600 in its first day, then 30 an hour and 300 a day.

A user also can send only as their own address or as an alias that delivers to their mailbox.

When a user runs into these limits, or their mail is refused as spam or for a virus, you get an e-mail at the
AdminEmail address, at most every 6 hours per user, and an `ALERT` line appears in
`/mnt/mailserver/log/instance.log`. If the user didn't send that much mail, change their password in
PostfixAdmin right away.

**Changing the number of messages.** Your own Rspamd settings go to `/mnt/mailserver/etc/rspamd/override.d/`.
A file there replaces the whole section of the same name, so start from a copy of Flashlight's:

```
sudo cp /etc/rspamd/local.d/ratelimit.conf /mnt/mailserver/etc/rspamd/override.d/ratelimit.conf
sudo nano /mnt/mailserver/etc/rspamd/override.d/ratelimit.conf
```

Change the numbers in both places of a line: `burst` is how many messages can go at once, `rate` how fast
the allowance comes back. For 60 an hour and 600 a day:

```
rates {
  user_hour {
    selector = "user.lower";
    bucket = { burst = 60; rate = "60 / 1h"; skip_recipients = true; }
  }
  user_day {
    selector = "user.lower";
    bucket = { burst = 600; rate = "600 / 1d"; skip_recipients = true; }
  }
}
```

Then check and apply it:

```
sudo rspamadm configtest && sudo systemctl reload rspamd
```

**Changing the number of recipients.** Your own Postfix settings go to
`/mnt/mailserver/etc/postfix/main.local.cf`. Add the line

```
flashlight_submission_recipient_limit = 50
```

and apply it now (the file itself is applied at every server start):

```
sudo postconf -e flashlight_submission_recipient_limit=50 && sudo systemctl reload postfix
```

Both files survive server replacements and Flashlight upgrades. If you raise the limits a lot, check
that your users really need it: these limits are what stops a stolen mailbox from getting your server's
address onto blocklists.

### Your own SPF and DMARC records

Flashlight writes `v=spf1 ip4:<server address> -all` and a DMARC record with `p=reject` for every mail domain.
If your company also sends mail through another service, or you want DMARC reports, edit the records in
Route 53:

- **SPF:** keep `ip4:<server address>` in the record and add what you need, for example
  `v=spf1 ip4:203.0.113.10 include:_spf.example.net -all`. A record that allows the server's address is left
  alone; one that doesn't is replaced at the next server start.
- **DMARC:** an existing `_dmarc` record is never changed. Flashlight creates it only when the domain has none.

The DKIM record is always Flashlight's.

### Your own settings

Flashlight rebuilds its configuration files at every server start, so a change made directly in them is lost
at the next replacement. Each program has a settings file of yours on the mail storage that Flashlight creates
once and never changes; the list is in [Upgrading](UPGRADING.md#what-an-upgrade-changes). For changes that
aren't settings (extra packages, for example), upload your own `user-script.sh` to the config bucket: every new
server runs it once after the install. The template with instructions is `s3bucket/system/user-script.sh` in
the repository.

### Files to keep

`upload/` in the config bucket is your folder: the server can write there, for example to keep a file outside
the server:

```
sudo aws s3 cp /mnt/mailserver/backup/some-file s3://<config bucket>/upload/
```

### Upgrades

See [Upgrading Flashlight](UPGRADING.md).

### Deleting the server

Delete stage 2, then stage 1. Stage 1 removes Flashlight's DNS records; its config bucket can only be deleted
once you empty it.

**The mail storage is not deleted with the stack.** The EFS file system with all mail and databases stays in
your account, so a stack deleted by mistake doesn't take the mail with it. It keeps costing its storage price
until you delete it yourself: EFS console, the file system named in the stack's resources (`MailStorage`),
**Delete**. Do that only when you are sure you no longer need the data, or have copied them; there is no way
back. (If the very first creation of the stack fails, its empty file system is cleaned up automatically.)

## Troubleshooting

| Where | What is there |
|---|---|
| `/mnt/mailserver/log/instance.log` | The server's events, one line each: `BOOT`, `READY`, `REPLACE`, `SHUTDOWN`, `ALERT`, `WARN`, `FAILED` and others. Kept across replacements |
| `/mnt/mailserver/log/install/` | The install log of every server, kept 90 days (root only: it contains passwords) |
| `install-logs/` in the config bucket | The install log of a failed install, also when the stack rolled back and the storage is gone |
| `/var/log/flashlight-install.log` | The install log of the running server |
| `/var/log/maillog` | Postfix and Dovecot |
| `/var/log/rspamd/rspamd.log` | The spam filter |
| The stage 1 Outputs | Links to the logs of its Lambda functions (DNS records, file copy) |

**The stack failed.** Open the install log from `install-logs/`; the last commands before the end show where
it stopped. The `FAILED` line in `instance.log` also names the command.

**Mail doesn't go out.** Check that AWS lifted the port 25 block for the account. Then
`sudo tail -50 /var/log/maillog` shows what the receiving servers answered.

**The server was replaced unexpectedly.** `instance.log` says why: a Spot interruption, the weekly Spot price
check, the scheduled rebuild, or a failed health check.
