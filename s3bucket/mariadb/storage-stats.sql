-- Copyright 2020-2026 Samson (https://github.com/georgio-sd)
-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 (see LICENSE)
--
-- Flashlight: the database of the "Mail storage statistics" page of the admin site. base.sh runs this file at every
-- install; everything is created only if missing, so new installs and upgrades from older releases get the same.
-- storage-stats (nightly, as root through the unix socket) writes the snapshots; the page reads them as the apache
-- user, also through the socket, with SELECT only and no password.
--
-- Schema version 1. A later change of the tables comes with a migration and a new version in meta.
-- Sizes are bytes; NULL means not known (a source failed, or a folder too large to count).

CREATE DATABASE IF NOT EXISTS flashlight CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE flashlight;

CREATE TABLE IF NOT EXISTS meta (
  name  VARCHAR(64)  NOT NULL PRIMARY KEY,
  value VARCHAR(255) NOT NULL
) ENGINE=InnoDB;
INSERT IGNORE INTO meta (name, value) VALUES ('schema_version', '1');

-- one row per mailbox and night, kept 13 months
CREATE TABLE IF NOT EXISTS mailbox_day (
  snapshot      DATE         NOT NULL,
  address       VARCHAR(255) NOT NULL,
  domain        VARCHAR(255) NOT NULL,
  name          VARCHAR(255) NOT NULL DEFAULT '',
  created       DATETIME     NULL,
  active        TINYINT(1)   NOT NULL,
  quota_bytes   BIGINT       NOT NULL DEFAULT 0,   -- 0: no limit
  bytes         BIGINT       NULL,
  messages      INT          NULL,
  unread_inbox  INT          NULL,
  trash_bytes   BIGINT       NULL,
  junk_bytes    BIGINT       NULL,
  sent_bytes    BIGINT       NULL,
  PRIMARY KEY (snapshot, address),
  KEY by_address (address, snapshot),
  KEY by_domain (domain, snapshot)
) ENGINE=InnoDB;

-- one row per trash folder of a deleted mailbox and night, kept 13 months
CREATE TABLE IF NOT EXISTS deleted_day (
  snapshot       DATE         NOT NULL,
  folder         VARCHAR(255) NOT NULL,              -- its name in /mnt/mailserver/mail/.deleted
  address        VARCHAR(255) NOT NULL,
  domain         VARCHAR(255) NOT NULL,
  deleted_at     DATETIME     NOT NULL,              -- when the mail was moved there (folder date, as mailbox-cleanup uses)
  bytes          BIGINT       NULL,                  -- NULL: not counted yet, or too large to count
  size_attempts  TINYINT      NOT NULL DEFAULT 0,    -- failed nights of counting; 3 = too large, not tried again
  PRIMARY KEY (snapshot, folder)
) ENGINE=InnoDB;

-- one row per domain and night, kept 5 years
CREATE TABLE IF NOT EXISTS domain_day (
  snapshot            DATE         NOT NULL,
  domain              VARCHAR(255) NOT NULL,
  domain_active       TINYINT(1)   NULL,              -- NULL: no longer in PostfixAdmin (only its trash is left)
  mailboxes           INT          NOT NULL,
  mailboxes_active    INT          NOT NULL,
  mailboxes_inactive  INT          NOT NULL,
  bytes               BIGINT       NULL,
  messages            BIGINT       NULL,
  deleted_mailboxes   INT          NOT NULL,
  deleted_bytes       BIGINT       NULL,
  PRIMARY KEY (snapshot, domain)
) ENGINE=InnoDB;

-- one row per night: the whole storage and how the collection went, kept 5 years
CREATE TABLE IF NOT EXISTS storage_day (
  snapshot             DATE      NOT NULL PRIMARY KEY,
  efs_bytes            BIGINT    NULL,                -- from AWS (the billed size)
  efs_standard_bytes   BIGINT    NULL,
  efs_ia_bytes         BIGINT    NULL,
  efs_archive_bytes    BIGINT    NULL,
  mailbox_bytes        BIGINT    NULL,
  deleted_bytes        BIGINT    NULL,
  started              DATETIME  NOT NULL,
  duration_seconds     INT       NOT NULL,
  errors               TEXT      NULL                 -- NULL: no errors
) ENGINE=InnoDB;

-- the page: read only, as the apache user (PHP-FPM) through the unix socket
CREATE USER IF NOT EXISTS 'apache'@'localhost' IDENTIFIED VIA unix_socket;
GRANT SELECT ON flashlight.* TO 'apache'@'localhost';
