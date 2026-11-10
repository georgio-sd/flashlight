<?php
/**
 * Flashlight overrides for PostfixAdmin 4.
 * Only settings that differ from PostfixAdmin's own config.inc.php are listed here;
 * everything else keeps the upstream default. For example, encrypt = php_crypt stores
 * mailbox passwords as bcrypt ($2y$) hashes, which Dovecot reads through
 * default_pass_scheme = CRYPT (old md5crypt $1$ hashes keep working too).
 * Values in curly braces are filled in by base.sh.
 */
$CONF['configured'] = true;
$CONF['setup_password'] = '{setup_password}';

$CONF['database_type'] = 'mysqli';
$CONF['database_host'] = 'localhost';
$CONF['database_user'] = 'postfix';
$CONF['database_password'] = '{database_password}';
$CONF['database_name'] = 'postfix';

$CONF['admin_email'] = '{admin_email}';

// Aliases created with every new domain: postmaster@ is required for any mail domain (RFC 5321),
// abuse@ receives spam complaints about this server. Others (hostmaster@, webmaster@...) are added by hand if needed.
$CONF['default_aliases'] = array(
    'abuse' => '{admin_email}',
    'postmaster' => '{admin_email}',
);

// Mail lives in /mnt/mailserver/mail/<domain>/<user@domain>/ (matches Dovecot's mail_location)
$CONF['domain_path'] = 'YES';
$CONF['domain_in_mailbox'] = 'YES';

// No default limits for new domains; quotas are on and counted in MB
$CONF['aliases'] = '0';
$CONF['mailboxes'] = '0';
$CONF['maxquota'] = '0';
$CONF['domain_quota_default'] = '0';
$CONF['quota'] = 'YES';
$CONF['quota_multiplier'] = '1048576';

$CONF['footer_text'] = 'Return to https://{admindomain}/padmin/';
$CONF['footer_link'] = 'https://{admindomain}/padmin/';
