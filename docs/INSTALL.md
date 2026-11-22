<!-- Copyright 2020-2026 Samson (https://github.com/georgio-sd). SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 (see LICENSE) -->
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
   remove email sending limitations", see [Asking AWS to allow outgoing mail](#asking-aws-to-allow-outgoing-mail))
   and wait for the answer: without it the server receives mail but can't send any to other servers. Reverse
   DNS of the server's address is set up by Flashlight.
4. **An EC2 key pair** in the region, for SSH access to the server (EC2 console, Key Pairs).
5. **Recommended: a Spamhaus key.** Spamhaus Blocklists via DNS Query are free for small businesses
   ([sign up](https://www.spamhaus.com/data-access/free-data-query-service/)). Spamhaus answers queries from
   AWS only with a key. The spam filter works without it, but noticeably better with it.
6. **The templates** of the Flashlight release: `1-dns-preset.yaml`, `2-deployment.yaml` and
   `x-maintenance.yaml`.

### Asking AWS to allow outgoing mail

AWS lets a server send mail on port 25 only after a request, and it lifts the limit for one region at a time:
a server in another region of the same account needs a request of its own. The request costs nothing and works
with the free Basic support plan. Send it before you install: AWS usually comes back with questions, and the
exchange takes two or three days.

1. Sign in to the AWS account where the server will run and open the form **Request to remove email sending
   limitations**: <https://console.aws.amazon.com/support/contacts#/rdns-limits>.
2. **Email address**: where AWS should answer.
3. **Use case description**: copy the text below, written for a Flashlight server; replace the parts in angle
   brackets and remove what isn't true for you. Keep the region in it: the form has no field for the region, and
   AWS lifts the limit only where you ask.
4. **Elastic IPs information** is optional: leave it empty. Before stage 1 the address doesn't exist yet, and
   Flashlight sets its reverse DNS itself.
5. Submit the form.

```text
Please remove the email sending limitations for our account <account ID> in the region <region>.

We plan to run our self-hosted mail server for our organization on Amazon EC2: Postfix and Dovecot with
Roundcube webmail on AlmaLinux 10, installed with CloudFormation. We prefer it to a hosted mail service
because we want to keep our mail data and the mail server's logs under our own control, and by our estimate
it costs us less. The server will send and receive the everyday email of our users at <domain, other
domains>: person-to-person correspondence with customers, partners and suppliers. We will send no
newsletters, marketing or other bulk mail, and will use no purchased or collected address lists.

The server will not be an open relay. Mail from other servers will be accepted only for our own domains, and
mail to other domains will be relayed only for our own users after they log in; the server will not forward
mail it receives from one outside server to another.

Sending will be limited and protected: users will have to log in (ports 587 and 465, TLS only) and will be
able to send only as their own addresses, at most 30 messages an hour, 300 a day and 20 recipients per
message; a mailbox over the limits will be reported to the administrator as possibly compromised. All
outgoing mail will be signed with DKIM, our domains will publish SPF (-all) and DMARC (p=reject) records, and
a spam filter (Rspamd) will check incoming and outgoing mail. We will set the reverse DNS of the server's
Elastic IP ourselves, to mail.<main domain>, the name the server uses in SMTP and which resolves back to the
same address.

Undeliverable mail will return to its sender. Complaints and abuse reports will reach the administrator at
<admin email>.
```

AWS answers by email, at the address you gave in the form. Keep an eye on that mailbox, its spam folder
included, until the request is approved: AWS may ask for more details about how you will use mail, and the
request waits until you answer. Be aware that AWS may turn the request down for an account that was created
only recently.

## Stage 1: address and DNS

In the CloudFormation console, **Create stack** with `1-dns-preset.yaml`. We recommend naming the stack after
your main domain, with dashes for the dots (a stack name can't have dots): `example-com`. Such a name tells at
once which server the resources belong to, and it is also the name the billing shows for the whole server
(see [What the server costs](#what-the-server-costs)). Stage 2 refers to it in its DnsPreset parameter.
CloudFormation can't rename a stack later.

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

**Create stack** with `2-deployment.yaml`. We recommend naming it like the stage 1 stack, with the suffix
`-server`: if stage 1 is `example-com`, stage 2 is `example-com-server`.

The first parameter below, DnsPreset, is the name of the stage 1 stack: `example-com`.

If you have several Flashlight servers in one account, name all of them this way. Then each server's
resources and costs are easy to tell apart:

| Server | Stage 1 | Stage 2 |
|---|---|---|
| A | `example-com` | `example-com-server` |
| B | `example-org` | `example-org-server` |

### Basic settings

| Parameter | Default | What it does |
|---|---|---|
| DnsPreset | MailServerDnsPreset | The name of your stage 1 stack (`example-com` in the example above) |
| AdminEmail | | Your e-mail address. It becomes the PostfixAdmin login and receives the mail to `postmaster@` and `abuse@` of your domains, and, with Antispam, a warning about a mailbox that may have been taken over (one that hits the sending limits or sends spam). It is also the contact address of the Let's Encrypt certificate, though Let's Encrypt rarely writes any more. Use an address outside the new server, so this mail reaches you when the server has problems |
| AlertEmail | empty | Optional, but recommended if you want to react quickly when the server breaks. Up to 3 addresses, separated by commas without spaces (`me@example.org,team@example.net`). They get an email when the server is down and can't recover by itself: the install on a new instance failed, or AWS can't start an instance at all. Each address is confirmed once, with the link in an email from AWS Notifications. Use addresses on another mail service, never on this server. See [Alert emails](#alert-emails) |
| TimeZone | America/Chicago | The server's time zone ([list](https://www.php.net/manual/en/timezones.php)) |
| CertificateMode | production | `production`: a trusted Let's Encrypt certificate. `staging`: an untrusted test certificate, for test installs; Let's Encrypt allows only a few production certificates for the same names per week. A test install can be switched to production later with a stack update |
| KeyName | | Your EC2 key pair |

### Mail protection

| Parameter | Default | What it does |
|---|---|---|
| Fail2ban | ENABLED | Bans IP addresses for a while after repeated failed logins (SSH, mail, webmail) |
| Antispam | ENABLED | The spam filter (Rspamd). Spam goes to the Junk folder, obvious spam is refused. Also turns on the limits for outgoing mail and the warnings about compromised mailboxes |
| SpamhausDQSKey | empty | Your Spamhaus DQS key (hidden in the console). With it, the spam filter checks each message's sending server, domains and links against the Spamhaus blocklists, the most widely used lists of known spam sources. Spamhaus answers servers in AWS only with a key; without one these checks are skipped. Needs Antispam |
| AttachmentPolicy | Score | Attachments of risky file types. `Score`: they only add to the spam score. `Gmail`: mail with a file type Gmail blocks (exe, js, bat, iso, lnk...) is refused, also inside archives; encrypted archives go to Junk. `Strict`: Gmail plus more Windows file types from Outlook's blocked list (reg, url, inf, vhdx, PowerShell...) |
| Antivirus | DISABLED | Virus scanning (ClamAV): mail with a virus is refused. Needs Antispam and a medium or larger instance type: the virus scanner needs about 1 GB of memory on top of what the other services use, and about 2 GB for a few seconds while it loads new signatures (several times a day) |

### Network

| Parameter | Default | What it does |
|---|---|---|
| VpcCidr | 10.0.0.0/16 | Address range of the server's VPC: `10.0.0.0/16`, `172.16.0.0/16` or `192.168.0.0/16`. Change it only if you plan to connect this VPC to another one (VPC peering or a VPN) that already uses the same range: connected VPCs must not overlap |
| SubnetMask | 8 | Size of each subnet: `8` = /24 (256 addresses), `10` = /22, `12` = /20, `14` = /18. The server needs only a few addresses, so the default is enough |
| AZoneNames | | Three Availability Zones of the region (two with TwoAZoneConf) |
| TwoAZoneConf | DISABLED | ENABLED only in regions with two zones |

Don't change the network settings after the install.

### Server

| Parameter | Default | What it does |
|---|---|---|
| InstanceType | t3.small | Main instance type: t3.small, t3.medium, t3.xlarge, c7i.large, c7i.xlarge, m7i.large or m7i.xlarge. t3.small (2 GB) is enough for a small company with the spam filter; t3.medium (4 GB) or larger for the antivirus. See [Choosing the instance type](#choosing-the-instance-type) |
| InstanceType2 | t3a.small | The pair of InstanceType, of the same size and memory: t3a for t3, c6a for c7i, m6a for m7i (t3.medium with t3a.medium; the template checks it). With Spot it gives the Auto Scaling group more capacity pools to choose from: a single type is sometimes unavailable on Spot for a while. With On-Demand the server runs on InstanceType, and on this one only when AWS has no capacity of the first. Keep it set also with a Reserved Instance: for that rare while you pay the On-Demand price of the second type, but the server stays up; with `None` it would wait without a server until capacity returns. A Compute Savings Plan covers both types. `None`: only InstanceType |
| InstanceLifecycle | Spot | `Spot` costs much less, but AWS may take the instance back when it needs the capacity, with a two-minute notice. The server watches for that notice: it stops its services cleanly and asks for a new instance, which installs itself and continues with the same mail storage (EFS). Mail is down for about 5 to 10 minutes; other mail servers deliver what they couldn't meanwhile, and no mail or data are lost. A weekly price check also moves the server to a cheaper Spot pool when its own has become expensive. `On-Demand` costs more and is never taken back |
| RebuildAfterDays | 30 | The server is rebuilt from scratch on current packages once it is this old, on the next Saturday-to-Sunday night at 03:15 (about 4 minutes without mail). This is how it gets security fixes and updates: the operating system, and the programs installed from its repositories (Postfix, Dovecot, Rspamd, ClamAV and others). The web applications (Roundcube, PostfixAdmin, phpMyAdmin) come with the Flashlight release and are updated by [upgrades](UPGRADING.md). 0 turns it off |
| DiskVolumeSize | 10 | The server's disk in GiB: the system plus a swap file for short memory peaks, sized automatically (half the memory, at most 4 GB). 10 for types with 2-4 GB of memory, at least 12 for 8 GB and more |

### Mail storage (EFS)

| Parameter | Default | What it does |
|---|---|---|
| MailStorageThroughputMode | bursting | `bursting` costs nothing extra and suits a mail server. `elastic` only if constant heavy traffic uses up the burst credits |
| MailStorageLifecyclePolicy | AFTER_30_DAYS | Files not opened for this long move to the cheaper Infrequent Access class, and come back on first access |
| MailStorageBackupPolicy | DISABLED | ENABLED: daily backups of the whole storage with AWS Backup (billed by AWS) |

The template checks the combinations before it creates anything: a Spamhaus key or the antivirus without the
spam filter, the antivirus on a small instance type, a second instance type that isn't the pair of the first,
or a disk too small for the swap file are refused with an explanation.

### What happens next

CloudFormation creates the network and the storage, then the server. The server updates its operating system,
installs and configures everything, gets its certificate, and reboots. When its services are up, it reports
to CloudFormation and the stack becomes **CREATE_COMPLETE**, usually 10 to 15 minutes after you started.

If the installation fails, the stack rolls back within a few minutes. The install log is then in the config
bucket, in `install-logs/` (see [Troubleshooting](#troubleshooting)).

With AlertEmail, each address gets an email from **AWS Notifications** ("Subscription Confirmation") a minute
after the stack starts. Click its link within 48 hours; look in the spam folder if it isn't there.

**Protect both stacks from deletion.** Once stage 2 is CREATE_COMPLETE, turn on termination protection for the
stage 1 and the stage 2 stack: CloudFormation console, the stack, **Stack actions**, **Edit termination
protection**, **Activated**. A stack can then be deleted only after the switch is turned off again, so a click on
**Delete** by mistake does nothing. It doesn't affect updates: upgrades, maintenance mode and settings changes
work as before. A template can't set it; it is a setting of the stack.

### Alert emails

The server runs unattended: AWS replaces its instance after a Spot interruption, for the scheduled rebuild or
after a failure, and the new instance installs itself. With AlertEmail you get an email when that doesn't work:

| Email | When |
|---|---|
| server install failed on a new instance, retrying | The install on a new instance failed; another one tries in 5 minutes |
| server is DOWN, install failed 3 times | Three installs in a row failed; no more attempts. The last instance stays up so you can look at it |
| server is up again | An install worked after failed ones |
| the install can't start on a new instance | The new instance can't even begin the install (the AWS CLI or the config bucket isn't available). It repeats about every 35 minutes until an install works. No "up again" email follows here: the instance can't record the failure anywhere, so when these emails stop, check that mail works |
| ALARM: "...-no-mail-server-instance" | For 15 minutes AWS couldn't start any instance: no free capacity of the instance types. AWS keeps trying; for a server sooner, update the stack with On-Demand or a second instance type |
| OK: "...-no-mail-server-instance" | An instance runs again (the install itself is reported by the emails above). One OK email also comes right after the alarm is made: when you first set AlertEmail on a running server and when you switch maintenance off. It only shows the emails arrive |

A failed stack create or update sends no email: the stack rolls back, and you see it in the console.

- **Use outside addresses.** When the server is down, it can't receive mail, so an address on one of its own
  domains would never get the alert. AdminEmail stays as it is; AlertEmail can be the same outside address or
  others.
- **Confirm each address.** Every address gets its own confirmation email; until its link is clicked, it gets
  no alerts. AWS drops an address that isn't confirmed within 48 hours. After each install the server checks
  the addresses and writes a `WARN` line to `instance.log` for every address that isn't confirmed or subscribed.
- **Changing the addresses.** Update the stack with the new AlertEmail; this doesn't touch the server. The
  subscriptions follow the order of the list: a changed address gets a new confirmation email, and so do the
  addresses after one you remove; click its link like the first time. Adding the first address or clearing
  the field replaces the server like any other change of its settings.
- **Getting an address back.** If an address was dropped (not confirmed in time) or someone clicked
  "Unsubscribe" in an alert, the stack doesn't know: update it once without that address and once with it
  again, and a new confirmation email comes.

The emails cost nothing in practice (AWS SNS: the first 1000 emails a month are free; the alarm is within
CloudWatch's 10 free alarms).

## What the server costs

AWS bills all the services of an account together. Flashlight tags its resources so that you can pick the mail
server's own costs out of that bill, and, with several servers, see each one apart.

Every resource of the server that AWS can tag has two tags:

| Tag | Value | Use |
|---|---|---|
| `Name` | `<stack name>-Flashlight` | Which stack made it, in the AWS consoles |
| `flashlight:installation` | The stage 1 stack name, on the resources of both stacks | The whole server, in the billing |

The mail storage backups (MailStorageBackupPolicy) get the tags of the file system, so their cost counts for the
server too.

The server image copy is the exception: one copy serves every Flashlight server in the region, so its
`flashlight:installation` is `shared` (its `Name` is `Flashlight <image name>`).

**Turn the tag on for the billing, once per account.** AWS shows costs by a tag only after it is activated. Do it
as the root user or an IAM user with access to the billing; in an AWS Organization, in its management account.

1. Billing and Cost Management console, **Cost allocation tags** (under Cost Organization). One table lists all
   tags of the account, AWS's own (`aws:...`) and yours.
2. Type `flashlight:installation` in **Find cost allocation tags**. The tag shows up in the table only up to a
   day after the first install; until then it isn't there, come back later.
3. Tick it and click **Activate**. Its status turns from Inactive to Active.

Costs are split by the tag from then on; it takes up to a day before Cost Explorer shows them. **Backfill tags**
(top right) applies it to the costs of earlier months too.

**See the costs.** Billing and Cost Management console, **Cost Explorer**: **Group by** Tag
`flashlight:installation` shows each server and `shared` side by side. To see one server with its share of
the image, **Filter** Tag `flashlight:installation` with both values, the server's and `shared`.

**Several servers in one region** share one image copy. To split its cost between them automatically: Billing
and Cost Management console, **Cost Categories**, **Create cost category**:

1. A rule of the type **Inherited value**, dimension **Cost allocation tag**, tag key `flashlight:installation`:
   every server's costs get its stack name as their value, the image copy gets `shared`.
2. **Split charges**: source `shared`, targets the servers' values, allocation **Proportional** (by each
   server's own costs) or **Even**.

Cost Explorer then shows each server with its part of the image under that cost category.

Not in the server's costs: the Route 53 hosted zones (they belong to your domains, and Flashlight doesn't tag
them) and the AWS Support plan.

## Choosing the instance type

The server's load comes from three things, and each needs something different:

| What people do | What it uses | Measured cost |
|---|---|---|
| **Webmail** (Roundcube in a browser) | CPU | about 0.3% of a t3 server per active user |
| **Mail programs and phones** (Outlook, Thunderbird, Apple Mail, phone mail apps) | Memory | about 1.5 MB per open connection; a desktop program keeps 1-3 connections, a phone 1-2 |
| **Incoming mail, spam and virus checks** | Little CPU; the antivirus takes about 1 GB of memory | about 1000 messages an hour add 3% CPU |

**Mailboxes are not active users.** The numbers below are about what the server does **at the same moment**, not about
how many mailboxes it holds:

- **Active users** are the people working in webmail at the same time, each with an action every 15-45 seconds
  all day long. Real users are much less busy: they read a message, then write a document or go to a meeting.
- **Connections** are the mail programs and phones connected right now.

A mailbox that nobody is using at the moment costs the server nothing but its space on the mail storage. So one
server holds **many more mailboxes than the numbers below**. An office with 500 mailboxes may have 50 people in
webmail at the same moment and a few hundred programs and phones connected: a t3.medium or a c7i.large handles
that easily. Size the server by your **busiest hour**, not by the number of mailboxes.

| Instance type (pair) | vCPU / memory | Active webmail users | Mail program connections | Antivirus |
|---|---|---|---|---|
| t3.small (t3a.small) | 2 / 2 GB | 150 (workday) | about 300 | no |
| t3.medium (t3a.medium) | 2 / 4 GB | 150 (workday) | about 600 | yes |
| c7i.large (c6a.large) | 2 / 4 GB | 300 (any time) | about 600 | yes |
| m7i.large (m6a.large) | 2 / 8 GB | 300 (any time) | about 2000 | yes |
| t3.xlarge (t3a.xlarge) | 4 / 16 GB | 450 (workday) | several thousand | yes |
| c7i.xlarge (c6a.xlarge) | 4 / 8 GB | about 600 (any time) | about 2000 | yes |
| m7i.xlarge (m6a.xlarge) | 4 / 16 GB | about 600 (any time) | several thousand | yes |

- **Workday (t3):** the number holds for a 10-hour workday within the t3 CPU credits (see below). Around the
  clock, a t3 carries about 60 (small, medium) or 230 (xlarge) active users at no extra cost. More users still
  get fast answers, but the extra CPU is billed. If you are often above the number, move to a bigger type. For
  t3.xlarge the limit is response time, not credits.
- **Any time (c, m):** these types have no credits. The number keeps the CPU near 75% at any hour, with the same
  response times as a t3 at its workday number: half of the answers in about 0.2 s, 95% within 0.8 s. The two
  types of a pair (c7i and c6a, m7i and m6a) carry the same load.
- **Connections:** the server sizes its limit by memory. Above it, a new connection is refused politely and the
  connected ones keep working. To estimate your office, count each person's devices: a desktop program plus a
  phone is usually 2-4 connections.

**Which one to pick:**

- **t3.small:** a small office without antivirus, the cheapest option.
- **t3.medium:** a small or medium office with antivirus. It has the same CPU as t3.small; the extra memory is for
  the antivirus and for mail programs.
- **c7i.large:** many people in webmail for most of the day. The whole CPU is always yours at a fixed price.
- **m7i.large:** many mail programs and phones, or large mailboxes. Same CPU as c7i.large, twice the memory.
- **xlarge types:** for larger offices. Choose t3, c or m by the same rules.

**The second type** (InstanceType2) should normally be the pair. With Spot, AWS sometimes has no capacity of one
type for a while, and the Auto Scaling group then starts the other one.

**After a server replacement** (a Spot interruption, the scheduled rebuild, a type change), all mail programs
reconnect within a minute or two. With a couple of thousand connections, logins are slow for those first
minutes, then back to normal.

### t3 CPU credits

A t3 server is guaranteed only part of its CPU (the **baseline**). It earns credits while it runs below the
baseline and spends them above it. Flashlight runs t3 in **Unlimited** mode (the AWS default): the server
**never slows down**, and CPU used beyond the earned credits is **billed** at $0.05 per vCPU-hour (on Spot too).

| Type | Baseline | Active webmail users within the baseline: around the clock / 10-hour workday |
|---|---|---|
| t3.small, t3.medium | 20% | about 60 / about 150 |
| t3.xlarge | 40% | about 230 / about 450 (limited by response time) |

- **A quiet night pays for a busy day:** the credits earned overnight cover the workday. A shorter workday allows
  a little more, an evening load a little less.
- **Credits belong to the running instance.** A new one (after a Spot interruption, a scheduled rebuild or a type
  change) starts with none, so the first busy day may be billed.
- **Going over is cheap:** a t3.small kept at about 150 active users around the clock adds roughly $18 a month. If
  that happens every day, a c or m type is the better deal.

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

Add the account in the mail program as an **IMAP** account. Most programs ask for the e-mail address and the
password first; if they then show server settings, or offer "manual setup", "advanced" or "other", enter the
server name yourself:

| | Server | Port | Security | Login |
|---|---|---|---|---|
| Incoming (IMAP) | `mail.<main domain>` | 993 | SSL/TLS | the full e-mail address and its password |
| Outgoing (SMTP) | `mail.<main domain>` | 587 | STARTTLS | the same; authentication "normal password" |

| Program | Where to add the account |
|---|---|
| Outlook | File → Add Account; then Advanced options → Let me set up my account manually → IMAP |
| Thunderbird | Account Settings → Account Actions → Add Mail Account; then Configure manually |
| Apple Mail (Mac) | Mail → Add Account → Other Mail Account |
| iPhone, iPad | Settings → Apps → Mail → Mail Accounts → Add Account → Other → Add Mail Account |
| Android (Gmail app) | Settings → Add account → Other → Personal (IMAP) |

**One server, several domains.** One Flashlight server can hold mailboxes of several domains, for example
`john@example.com` and `sam@domain.net`. The first domain of the server is its **main domain**, and the server
has one name for all of them: `mail.<main domain>`. If `example.com` is the main domain here, both John and Sam
enter `mail.example.com` as the server, never `mail.domain.net`:

- the server's certificate is issued for `mail.<main domain>` only, so any other name gives a certificate warning;
- a program that tries to find the settings itself guesses the server from the address: for `john@example.com` it
  may find `mail.example.com` (Thunderbird does), for `sam@domain.net` it can't. Even when the automatic setup
  works, check that the server name is `mail.<main domain>`.

**Also supported:**

- incoming on port 143 with STARTTLS;
- outgoing on port 465 with SSL/TLS.

If a network blocks one port, try the other.

**Not supported:**

- POP3 (use IMAP: mail stays on the server and every device sees the same folders);
- sending through port 25 (it receives mail from other servers and accepts no logins);
- connections without encryption (TLS 1.2 or newer is required).

**If sending fails** while receiving works, check the outgoing settings first: an outgoing server on port 25, or
with the automatic setup still on, is the usual cause. In Apple Mail, turn off "Automatically manage connection
settings" and enter port 587 with TLS.

Webmail is at `https://mail.<main domain>/`. Messages can be up to 20 MB. One mailbox may have up to 30 connections
from one address, so a computer and a phone behind the same office router both fit.

### Checking that it works

1. Send a message from a new mailbox to an outside address (Gmail, for example) and back. Gmail often puts the
   first messages from a newly installed server into Spam, short test messages especially, even when the
   server is set up correctly: its address has no reputation with Gmail yet. That is normal: mark them **Not
   spam**, and after a while Gmail stops doing it.
2. In Gmail, **Show original** of the received message should show SPF, DKIM and DMARC as PASS.
3. Check the server's setup at [mail-tester.com](https://www.mail-tester.com/): send a message from one of the
   server's mailboxes to the address the page shows, then open the result. It rates the message out of 10 and
   explains each point: DNS records, signatures, blocklists, content. Write a few real sentences: an empty or
   one-word message costs points by itself.
4. `sudo tail /mnt/mailserver/log/instance.log` shows the server's events; the last one after the install is
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
delete it there if you no longer need them. Deleting the domain in PostfixAdmin deletes its mailboxes and aliases
too; their mail goes to `/mnt/mailserver/mail/.deleted/` within 10 minutes and is kept there for 30 days. A domain
deleted in PostfixAdmin but still in the stack's list comes back, empty, at the next instance install.

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
the AWS console, lowers the On-Demand price close to the Spot level. Set InstanceLifecycle to On-Demand and keep
InstanceType2: the server runs on the reserved type and moves to the second one only when AWS has no capacity
of the first, at the On-Demand price for that while.

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

1. **Delete the stage 2 stack.** Turn off its termination protection first (**Stack actions**, **Edit termination
   protection**, **Deactivated**), and the same for stage 1 before step 3. The server and its network are deleted;
   the mail storage stays (below).
2. **Empty the config bucket** of stage 1: S3 console, the bucket from stage 1's output `S3Bucket`, **Empty**.
   CloudFormation can't delete a bucket that has files in it, so without this the deletion of stage 1 fails.
   Empty it only after step 1: the server writes its logs and backups there while it runs.
3. **Delete the stage 1 stack.** It removes Flashlight's DNS records, resets the reverse DNS and releases the
   Elastic IP address. (Stage 1 can't be deleted while stage 2 exists: stage 2 uses its outputs.)
   If AWS Support once lifted the email sending limit or set the reverse DNS for this address, AWS may keep the
   address locked to your account: the deletion then fails on `IPAddressMS` with "locked to your account". Open a
   case in the AWS Support Center (Account and billing, free) asking to unlock the address so you can release it.
   Meanwhile you can delete the stack without it: delete again and tick `IPAddressMS` under the resources to keep;
   after the unlock, release the address in the EC2 console (**Elastic IPs**). Until then it is billed like any
   unused Elastic IP.

**The mail storage is not deleted with the stack.** The EFS file system with all mail and databases stays in
your account, so a stack deleted by mistake doesn't take the mail with it. It has no deletion protection
switch to turn off: the stack simply leaves it behind. It keeps costing its storage price until you delete it
yourself: EFS console, the file system named `<stage 2 stack name>-Flashlight`, **Delete**. Do that only when
you are sure you no longer need the data, or have copied them; there is no way back. With
MailStorageBackupPolicy, its daily AWS Backup copies stay after that until they expire (35 days).

A file system created before Flashlight 1.1 gets its name only when its stack is updated to 1.1. Otherwise note
its ID before deleting stage 2: the stack's **Resources** tab, `MailStorage`. (If the very first creation of the
stack fails, its empty file system is cleaned up automatically.)

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
