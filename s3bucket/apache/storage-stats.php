<?php
// Copyright 2020-2026 Samson (https://github.com/georgio-sd)
// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 (see LICENSE)
//
// Flashlight: the "Mail storage statistics" page of the administration site (/var/www/admin/storage_stats/index.php).
// DON'T EDIT THIS FILE: base.sh rewrites it at every boot from the Flashlight release.
// It only reads the flashlight database (storage-stats.sql), filled every night by storage-stats, as the apache user
// through the unix socket (SELECT only, no password). Nothing is loaded from outside; the strict Content-Security-Policy
// allows only this page's own style and script (no inline style attributes: sizes go into SVG attributes).
// ?csv=mailboxes and ?csv=domains give the tables as CSV files.

declare(strict_types=1);

const TRASH_DAYS = 30;       // mailbox-cleanup deletes trash folders after this many days
const STALE_DAYS = 2;        // warning: the latest snapshot is older than this

// The amber marks: Flashlight's thresholds, or the admin's from their settings file (created once by base.sh,
// never changed by upgrades). A value that isn't a whole number above 0 keeps the default.
$limits = [
    'unread_max' => 400,      // more unread in the Inbox than this
    'unread_growth' => 200,   // unread in the Inbox grew by more than this in 30 days
    'quota_full' => 90,       // more of the quota used than this (%)
];
$custom = @parse_ini_file('/mnt/mailserver/etc/storage-stats/custom.ini', false, INI_SCANNER_RAW);
foreach (is_array($custom) ? $custom : [] as $key => $value) {
    if (isset($limits[$key]) && ctype_digit(trim((string)$value)) && (int)$value > 0) {
        $limits[$key] = (int)$value;
    }
}

$nonce = base64_encode(random_bytes(16));
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: no-referrer');
header("Content-Security-Policy: default-src 'none'; style-src 'nonce-$nonce'; script-src 'nonce-$nonce'; "
    . "img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'");

function h($s): string
{
    return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

function bytes($b): string
{
    if ($b === null) {
        return '—';
    }
    $b = (float)$b;
    $units = ['B', 'KB', 'MB', 'GB', 'TB'];
    $i = 0;
    // the next unit already from 1000 (1,016 MB reads as 1.0 GB): never four digits before the point
    while (abs($b) >= 1000 && $i < 4) {
        $b /= 1024;
        $i++;
    }
    return number_format($b, $i >= 2 ? 1 : 0) . ' ' . $units[$i];
}

function change($b): string
{
    if ($b === null) {
        return '—';
    }
    return ($b > 0 ? '+' : ($b < 0 ? '−' : '')) . bytes(abs((float)$b));
}

function num($n): string
{
    return $n === null ? '—' : number_format((float)$n);
}

function pct(?float $part, ?float $whole, int $dec = 1): ?string
{
    if ($part === null || !$whole) {
        return null;
    }
    return number_format(100 * $part / $whole, $dec) . '%';
}

// a CSV cell that a spreadsheet won't read as a formula
function csv_cell($v)
{
    if (is_string($v) && $v !== '' && strpos('=+-@', $v[0]) !== false) {
        return "'" . $v;
    }
    return $v;
}

// a line chart as inline SVG: $series = [[name, css class, [date => bytes|null, ...]], ...]
function chart(array $series, string $label): string
{
    $dates = [];
    foreach ($series as $s) {
        $dates += array_fill_keys(array_keys($s[2]), true);
    }
    ksort($dates);
    $dates = array_keys($dates);
    $n = count($dates);
    if ($n < 2) {
        return '<p class="muted">The chart builds up over the coming days.</p>';
    }
    $max = 1;
    foreach ($series as $s) {
        foreach ($s[2] as $v) {
            if ($v !== null && $v > $max) {
                $max = (float)$v;
            }
        }
    }
    [$unit, $div] = $max >= 1073741824 ? ['GB', 1073741824] : ($max >= 1048576 ? ['MB', 1048576] : ['KB', 1024]);
    $raw = $max / $div / 4;
    $mag = 10 ** floor(log10(max($raw, 1e-9)));
    $step = 10 * $mag;
    foreach ([1, 2, 5, 10] as $m) {
        if ($raw <= $m * $mag) {
            $step = $m * $mag;
            break;
        }
    }
    $top = max($step, ceil($max / $div / $step) * $step);
    $x = fn($i) => round(70 + 1020 * $i / ($n - 1));
    $y = fn($v) => round(200 - 180 * ($v / $div) / $top);
    $svg = '<svg class="chart" viewBox="0 0 1120 232" role="img" aria-label="' . h($label) . '">';
    for ($g = 0; $g <= $top + 1e-9; $g += $step) {
        $gy = round(200 - 180 * $g / $top);
        $svg .= '<line class="grid" x1="60" y1="' . $gy . '" x2="1100" y2="' . $gy . '"/>'
            . '<text class="axis" x="52" y="' . ($gy + 4) . '" text-anchor="end">'
            . h(($g == 0 ? '0' : rtrim(rtrim(number_format($g, 2, '.', ''), '0'), '.') . ' ' . $unit)) . '</text>';
    }
    $month = '';
    foreach ($dates as $i => $d) {
        $m = substr($d, 0, 7);
        if ($m !== $month) {
            $month = $m;
            if ($i < $n - 3 || $n < 40) {
                $svg .= '<text class="axis" x="' . $x($i) . '" y="224" text-anchor="middle">'
                    . h(date('M', strtotime($d))) . '</text>';
            }
        }
    }
    $index = array_flip($dates);
    foreach ($series as [$name, $class, $points]) {
        $pts = [];
        foreach ($points as $d => $v) {
            if ($v !== null) {
                $pts[] = $x($index[$d]) . ',' . $y((float)$v);
            }
        }
        if (count($pts) > 1) {
            $svg .= '<polyline class="line ' . h($class) . '" points="' . implode(' ', $pts) . '"/>';
        }
    }
    $svg .= '</svg><div class="legend">';
    foreach ($series as [$name, $class]) {
        $svg .= '<span><svg class="key" viewBox="0 0 16 4" aria-hidden="true"><rect class="' . h($class)
            . '" width="16" height="4"/></svg>' . h($name) . '</span>';
    }
    return $svg . '</div>';
}

// a horizontal bar of shares: $parts = [[name, css class, bytes], ...]
function bar(array $parts, string $label): string
{
    $total = 0;
    foreach ($parts as $p) {
        $total += max(0, (float)$p[2]);
    }
    if ($total <= 0) {
        return '';
    }
    $svg = '<svg class="bar" viewBox="0 0 100 10" preserveAspectRatio="none" role="img" aria-label="' . h($label) . '">';
    $at = 0.0;
    foreach ($parts as [$name, $class, $v]) {
        $w = 100 * max(0, (float)$v) / $total;
        $svg .= '<rect class="' . h($class) . '" x="' . round($at, 3) . '" width="' . round($w, 3) . '" height="10"/>';
        $at += $w;
    }
    $svg .= '</svg><div class="legend">';
    foreach ($parts as [$name, $class, $v]) {
        $svg .= '<span><svg class="key" viewBox="0 0 10 10" aria-hidden="true"><rect class="' . h($class)
            . '" width="10" height="10" rx="2"/></svg>' . h($name) . ' ' . bytes($v) . ' · '
            . h(pct((float)$v, $total)) . '</span>';
    }
    return $svg . '</div>';
}

// ---------------------------------------------------------------------------------------------------------------- data

$error = null;
$csv = $_GET['csv'] ?? '';
$csv = in_array($csv, ['mailboxes', 'domains'], true) ? $csv : '';
try {
    $db = new PDO('mysql:unix_socket=/var/lib/mysql/mysql.sock;dbname=flashlight;charset=utf8mb4', 'apache', '', [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES => false]);
    $one = function (string $sql, array $args = []) use ($db) {
        $q = $db->prepare($sql);
        $q->execute($args);
        return $q->fetch() ?: null;
    };
    $all = function (string $sql, array $args = []) use ($db) {
        $q = $db->prepare($sql);
        $q->execute($args);
        return $q->fetchAll();
    };
    $last = $one('SELECT *, DATEDIFF(CURDATE(), snapshot) AS age FROM storage_day ORDER BY snapshot DESC LIMIT 1');
} catch (PDOException $e) {
    $error = $e->getMessage();
    $last = null;
}

if ($last) {
    $snap = $last['snapshot'];
    // the snapshot nearest to (at most a week before) a day N days earlier; null while history is shorter
    $earlier = function (int $days) use ($one, $snap) {
        $r = $one('SELECT snapshot FROM storage_day WHERE snapshot <= ? - INTERVAL ? DAY AND snapshot >= ? - INTERVAL ? DAY
                   ORDER BY snapshot DESC LIMIT 1', [$snap, $days, $snap, $days + 7]);
        return $r ? $r['snapshot'] : null;
    };
    $snap30 = $earlier(30);
    // the storage figures: growth over these periods, each shown once that much history exists
    $periods = [];
    foreach (['Last 30 days' => 30, 'Last 3 months' => 91, 'Last 6 months' => 182, 'Last 12 months' => 365] as $name => $days) {
        $was = $earlier($days);
        $periods[$name] = $was ? $one('SELECT efs_bytes FROM storage_day WHERE snapshot = ?', [$was]) : null;
    }
    $history = $all('SELECT snapshot, efs_bytes, efs_standard_bytes, efs_ia_bytes FROM storage_day
                     WHERE snapshot > ? - INTERVAL 12 MONTH ORDER BY snapshot', [$snap]);

    $domains = $all('SELECT * FROM domain_day WHERE snapshot = ? ORDER BY bytes DESC, domain', [$snap]);
    // a turned-off domain turns off all its mailboxes too (Dovecot checks both Active flags)
    $domainOn = [];
    foreach ($domains as $d) {
        $domainOn[$d['domain']] = $d['domain_active'] === null ? null : (bool)$d['domain_active'];
    }
    $domains30 = [];
    foreach ($snap30 ? $all('SELECT domain, bytes FROM domain_day WHERE snapshot = ?', [$snap30]) : [] as $r) {
        $domains30[$r['domain']] = $r['bytes'];
    }
    $mailTotal = 0;
    foreach ($domains as $d) {
        $mailTotal += (float)$d['bytes'];
    }
    $domainHistory = [];
    foreach ($all('SELECT snapshot, domain, bytes FROM domain_day WHERE snapshot > ? - INTERVAL 12 MONTH
                   ORDER BY snapshot', [$snap]) as $r) {
        $domainHistory[$r['domain']][$r['snapshot']] = $r['bytes'];
    }

    $boxes = $all('SELECT * FROM mailbox_day WHERE snapshot = ? ORDER BY bytes DESC, address', [$snap]);
    $unread30 = [];
    foreach ($snap30 ? $all('SELECT address, unread_inbox FROM mailbox_day WHERE snapshot = ?', [$snap30]) : [] as $r) {
        $unread30[$r['address']] = $r['unread_inbox'];
    }
    foreach ($boxes as &$b) {
        $b['state'] = !$b['active'] ? 'no' : (($domainOn[$b['domain']] ?? true) === false ? 'domain off' : 'yes');
        $b['unread_change'] = ($snap30 && $b['unread_inbox'] !== null && isset($unread30[$b['address']]))
            ? (int)$b['unread_inbox'] - (int)$unread30[$b['address']] : null;
        $b['quota_used'] = ((int)$b['quota_bytes'] > 0 && $b['bytes'] !== null)
            ? 100 * (float)$b['bytes'] / (float)$b['quota_bytes'] : null;
    }
    unset($b);

    $deleted = $all('SELECT *, TIMESTAMPDIFF(DAY, deleted_at, NOW()) AS age FROM deleted_day WHERE snapshot = ?
                     ORDER BY address, deleted_at', [$snap]);
} else {
    $snap = null;
}

// ----------------------------------------------------------------------------------------------------------------- CSV

if ($csv && $last) {
    header('Content-Type: text/csv; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . $csv . '-' . $snap . '.csv"');
    $out = fopen('php://output', 'w');
    if ($csv === 'mailboxes') {
        fputcsv($out, ['address', 'name', 'domain', 'active', 'bytes', 'messages', 'unread_inbox',
            'unread_inbox_change_30_days', 'trash_bytes', 'junk_bytes', 'sent_bytes', 'quota_bytes', 'quota_used_percent',
            'created']);
        foreach ($boxes as $b) {
            fputcsv($out, array_map('csv_cell', [$b['address'], $b['name'], $b['domain'], $b['state'],
                $b['bytes'], $b['messages'], $b['unread_inbox'], $b['unread_change'], $b['trash_bytes'], $b['junk_bytes'],
                $b['sent_bytes'], $b['quota_bytes'] ?: '', $b['quota_used'] === null ? '' : round($b['quota_used'], 1),
                $b['created']]));
        }
    } else {
        fputcsv($out, ['domain', 'active', 'mailboxes', 'mailboxes_active', 'mailboxes_inactive', 'bytes', 'messages',
            'share_percent', 'change_30_days_bytes', 'deleted_mailboxes', 'deleted_bytes']);
        foreach ($domains as $d) {
            $was = $domains30[$d['domain']] ?? null;
            fputcsv($out, array_map('csv_cell', [$d['domain'],
                $d['domain_active'] === null ? 'removed' : ($d['domain_active'] ? 'yes' : 'no'), $d['mailboxes'],
                $d['mailboxes_active'], $d['mailboxes_inactive'], $d['bytes'], $d['messages'],
                $mailTotal ? round(100 * (float)$d['bytes'] / $mailTotal, 1) : '',
                ($was !== null && $d['bytes'] !== null) ? (float)$d['bytes'] - (float)$was : '',
                $d['deleted_mailboxes'], $d['deleted_bytes']]));
        }
    }
    exit;
}
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Mail storage statistics · {MailDomain}</title>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style nonce="<?= h($nonce) ?>">
  :root {
    --bg: #eef1f5; --surface: #ffffff; --fg: #17202b; --muted: #5b6675; --line: #d6dce4;
    --accent: #b86f00; --accent-soft: #fff1d6; --row-off: #f6f8fa;
    --flag-bg: #fef3c7; --flag-fg: #8a3a00;
    --std: #1e40af; --ia: #93c5fd; --mail: #2563eb; --trash: #d97706; --other: #9ca3af;
    --d1: #2563eb; --d2: #ea580c; --d3: #059669; --d4: #7c3aed; --d5: #db2777; --d6: #6b7280;
    --font: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    --mono: ui-monospace, "SF Mono", "Cascadia Mono", Consolas, "Liberation Mono", monospace;
    color-scheme: light;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #10151c; --surface: #18202a; --fg: #e6ebf1; --muted: #93a0af; --line: #273240;
      --accent: #f0a73a; --accent-soft: #2b2316; --row-off: #1d2632;
      --flag-bg: #3a2a10; --flag-fg: #fbbf24;
      --std: #93c5fd; --ia: #1d4ed8; --mail: #60a5fa; --trash: #f59e0b; --other: #6b7280;
      --d1: #60a5fa; --d2: #fb923c; --d3: #34d399; --d4: #a78bfa; --d5: #f472b6; --d6: #9ca3af;
      color-scheme: dark;
    }
  }
  body { margin: 0; background: var(--bg); color: var(--fg); font-family: var(--font); font-size: 15px; line-height: 1.5;
         padding: 40px 16px; }
  .wrap { max-width: 1200px; margin: 0 auto; display: grid; gap: 24px; }
  header { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end; gap: 12px; }
  header .back { font-size: 13px; }
  h1 { margin: 4px 0 0; font-size: 28px; line-height: 1.15; font-weight: 650; }
  h2 { margin: 0; font-size: 18px; font-weight: 650; }
  a { color: var(--fg); text-decoration-color: var(--line); }
  a:hover { text-decoration-color: var(--accent); }
  code { font-family: var(--mono); font-size: 14px; }
  .muted { color: var(--muted); font-size: 13px; margin: 0; }
  .status { display: flex; align-items: center; gap: 8px; font-size: 13px; color: var(--muted); }
  .dot { width: 10px; height: 10px; border-radius: 50%; background: #15803d; flex: none; }
  .dot.bad { background: var(--accent); }
  .alert { padding: 12px 16px; border-radius: 10px; background: var(--flag-bg); color: var(--flag-fg); font-weight: 600; }
  section { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 24px;
            display: grid; gap: 18px; min-width: 0; }
  /* blocks side by side keep their content at the top, whatever the neighbour holds (full or partial data) */
  .figures { display: flex; flex-wrap: wrap; gap: 40px; align-items: flex-start; }
  .figure { display: grid; gap: 2px; align-content: start; }
  .figure .label { font-size: 13px; color: var(--muted); }
  .figure .big { font-size: 38px; font-weight: 700; line-height: 1.1; }
  .figure .mid { font-size: 22px; font-weight: 650; }
  .pair { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 32px; }
  .block { display: grid; gap: 8px; min-width: 0; align-content: start; }
  .block .title { font-size: 13px; font-weight: 650; }
  svg.bar { width: 100%; height: 26px; border-radius: 6px; display: block; }
  svg.chart { width: 100%; height: auto; display: block; }
  .legend { display: flex; flex-wrap: wrap; gap: 6px 20px; font-size: 13px; color: var(--muted); }
  .legend span { display: inline-flex; align-items: center; gap: 6px; }
  svg.key { width: 14px; height: 10px; }
  .grid { stroke: var(--line); stroke-width: 1; }
  .axis { fill: var(--muted); font-size: 11px; font-family: var(--font); }
  .line { fill: none; stroke-width: 2.5; stroke-linejoin: round; }
  .c-total { fill: var(--fg); stroke: var(--fg); } .c-std { fill: var(--std); stroke: var(--std); }
  .c-ia { fill: var(--ia); stroke: var(--ia); } .c-mail { fill: var(--mail); } .c-trash { fill: var(--trash); }
  .c-other { fill: var(--other); }
  .c-d1 { fill: var(--d1); stroke: var(--d1); } .c-d2 { fill: var(--d2); stroke: var(--d2); }
  .c-d3 { fill: var(--d3); stroke: var(--d3); } .c-d4 { fill: var(--d4); stroke: var(--d4); }
  .c-d5 { fill: var(--d5); stroke: var(--d5); } .c-d6 { fill: var(--d6); stroke: var(--d6); }
  polyline.c-total, polyline.c-std, polyline.c-ia, polyline[class*="c-d"] { fill: none; }
  .scroll { overflow-x: auto; }
  /* the long tables keep the page short: their own scroll, about 17 rows high, with the column titles fixed */
  .scroll.tall { max-height: 42rem; overflow: auto; border: 1px solid var(--line); border-radius: 8px; }
  .tall thead th { position: sticky; top: 0; z-index: 1; background: var(--surface); }
  .jump { display: flex; flex-wrap: wrap; gap: 6px 20px; font-size: 14px; }
  h2 { scroll-margin-top: 16px; }
  table { border-collapse: collapse; width: 100%; }
  th { font-weight: 600; font-size: 12px; color: var(--muted); text-align: right; padding: 8px 10px;
       border-bottom: 1px solid var(--line); white-space: nowrap; }
  td { font-size: 13px; text-align: right; padding: 8px 10px; border-bottom: 1px solid var(--line); white-space: nowrap; }
  th.l, td.l { text-align: left; }
  th button { all: unset; cursor: pointer; }
  th button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
  th[aria-sort="descending"] button::after { content: " ▼"; } th[aria-sort="ascending"] button::after { content: " ▲"; }
  tr.off td { background: var(--row-off); color: var(--muted); }
  tr.total td { font-weight: 650; border-bottom: none; border-top: 1px solid var(--muted); }
  td.big { font-weight: 650; }
  .flag { display: inline-block; padding: 0 6px; border-radius: 4px; background: var(--flag-bg); color: var(--flag-fg);
          font-weight: 650; }
  .tools { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between; }
  .controls { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; font-size: 13px; color: var(--muted); }
  .controls label { display: flex; align-items: center; gap: 6px; }
  select, input { font: inherit; font-size: 13px; padding: 5px 8px; border: 1px solid var(--line); border-radius: 6px;
                  background: var(--surface); color: var(--fg); }
  footer { display: flex; flex-wrap: wrap; gap: 8px 24px; justify-content: space-between; padding-top: 16px;
           border-top: 1px solid var(--line); color: var(--muted); font-size: 13px; }
  @media (max-width: 720px) { .pair { grid-template-columns: 1fr; } body { padding-top: 24px; } h1 { font-size: 24px; } }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <a class="back" href="/">← Administration</a>
      <h1>Mail storage statistics</h1>
      <p class="muted">Server <code>{MailDomain}</code></p>
    </div>
<?php if ($last): ?>
    <div class="status">
      <span class="dot<?= $last['errors'] ? ' bad' : '' ?>" aria-hidden="true"></span>
      <span>Snapshot of <?= h(substr($last['started'], 0, 16)) ?> · collected in
        <?= h(intdiv((int)$last['duration_seconds'], 60) . ' min ' . ((int)$last['duration_seconds'] % 60) . ' s') ?>
        · <?= $last['errors'] ? 'with errors' : 'no errors' ?></span>
    </div>
<?php endif ?>
  </header>

<?php if ($error !== null): ?>
  <p class="alert">The statistics database isn't available: <?= h($error) ?></p>
<?php elseif (!$last): ?>
  <section><h2>No snapshot yet</h2>
    <p class="muted">The server takes the first snapshot of its mail storage tonight at 04:15 (server time); this page
      shows it from then on.</p></section>
<?php else: ?>
<?php if ((int)$last['age'] > STALE_DAYS): ?>
  <p class="alert">The latest snapshot is <?= (int)$last['age'] ?> days old: the nightly collection isn't running
    (see <code>/mnt/mailserver/log/instance.log</code>).</p>
<?php endif ?>
<?php if ($last['errors']): ?>
  <p class="alert">Collected with errors: <?= h($last['errors']) ?></p>
<?php endif ?>
  <nav class="jump" aria-label="Sections">
    <a href="#storage">Storage</a><a href="#domains">Domains</a><a href="#mailboxes">Mailboxes</a>
    <a href="#deleted">Deleted mailboxes</a>
  </nav>

  <section aria-labelledby="storage">
    <h2 id="storage">Storage (EFS)</h2>
<?php $efs = $last['efs_bytes'] === null ? null : (float)$last['efs_bytes']; ?>
    <div class="figures">
      <div class="figure"><span class="label">Stored now</span><span class="big"><?= bytes($efs) ?></span></div>
<?php foreach ($periods as $name => $was): ?>
      <div class="figure"><span class="label"><?= h($name) ?></span>
        <span class="mid"><?= $was === null ? '<span class="muted">builds up</span>'
            : change(($efs === null || $was['efs_bytes'] === null) ? null : $efs - (float)$was['efs_bytes']) ?></span></div>
<?php endforeach ?>
    </div>
<?php if ($efs === null): ?>
    <p class="muted">The size AWS bills wasn't available in this snapshot (see the errors above).</p>
<?php else: ?>
    <div class="pair">
      <div class="block"><span class="title">By storage class</span>
        <?= bar([['Standard', 'c-std', $last['efs_standard_bytes']], ['Infrequent Access', 'c-ia', $last['efs_ia_bytes']]]
            + ((float)$last['efs_archive_bytes'] > 0 ? [2 => ['Archive', 'c-other', $last['efs_archive_bytes']]] : []),
            'Storage by class') ?>
      </div>
      <div class="block"><span class="title">By content</span>
<?php $other = max(0, $efs - (float)$last['mailbox_bytes'] - (float)$last['deleted_bytes']); ?>
        <?= bar([['Mailboxes', 'c-mail', $last['mailbox_bytes']], ['Deleted mailboxes', 'c-trash', $last['deleted_bytes']],
            ['Other', 'c-other', $other]], 'Storage by content') ?>
        <p class="muted">Other: Dovecot indexes, databases and their nightly dumps, logs, spam filter data.</p>
      </div>
    </div>
<?php endif ?>
    <div class="block"><span class="title">Last 12 months</span>
<?php
    $series = [['Total', 'c-total', []], ['Infrequent Access', 'c-ia', []], ['Standard', 'c-std', []]];
    foreach ($history as $r) {
        $series[0][2][$r['snapshot']] = $r['efs_bytes'];
        $series[1][2][$r['snapshot']] = $r['efs_ia_bytes'];
        $series[2][2][$r['snapshot']] = $r['efs_standard_bytes'];
    }
    echo chart($series, 'Storage over the last 12 months');
?>
    </div>
  </section>

  <section aria-labelledby="domains">
    <div class="tools"><h2 id="domains">Domains</h2><a href="?csv=domains">Download CSV</a></div>
    <div class="scroll">
      <table>
        <thead><tr><th class="l">Domain</th><th class="l">Active</th><th>Mailboxes</th><th>Size</th><th>Messages</th>
          <th>Share</th><th>30 days</th><th>Deleted mailboxes</th></tr></thead>
        <tbody>
<?php
    $totals = ['mailboxes' => 0, 'active' => 0, 'messages' => 0, 'deleted' => 0, 'deleted_bytes' => 0, 'change' => 0];
    $changeKnown = (bool)$snap30;
    foreach ($domains as $d):
        $was = $domains30[$d['domain']] ?? null;
        $chg = ($was !== null && $d['bytes'] !== null) ? (float)$d['bytes'] - (float)$was : null;
        if ($chg === null) {
            $changeKnown = false;
        } else {
            $totals['change'] += $chg;
        }
        $totals['mailboxes'] += (int)$d['mailboxes'];
        $totals['active'] += $d['domain_active'] ? (int)$d['mailboxes_active'] : 0;
        $totals['messages'] += (int)$d['messages'];
        $totals['deleted'] += (int)$d['deleted_mailboxes'];
        $totals['deleted_bytes'] += (float)$d['deleted_bytes'];
        $boxesText = (int)$d['mailboxes'] === 0 ? '—'
            : ($d['domain_active'] === 0 || $d['domain_active'] === false
            ? $d['mailboxes'] . ' (domain off)'
            : $d['mailboxes'] . ' (' . $d['mailboxes_active'] . ' active'
              . ($d['mailboxes_inactive'] ? ', ' . $d['mailboxes_inactive'] . ' off' : '') . ')');
?>
          <tr<?= $d['domain_active'] === null || !$d['domain_active'] ? ' class="off"' : '' ?>>
            <td class="l"><?php if ((int)$d['mailboxes'] > 0): ?><a href="#mailboxes" data-domain="<?= h($d['domain']) ?>"><?= h($d['domain']) ?></a><?php else: ?><?= h($d['domain']) ?><?php endif ?></td>
            <td class="l"><?= $d['domain_active'] === null ? 'removed' : ($d['domain_active'] ? 'yes' : 'no') ?></td>
            <td><?= h($boxesText) ?></td><td><?= bytes($d['bytes']) ?></td><td><?= num($d['messages']) ?></td>
            <td><?= h(pct($d['bytes'] === null ? null : (float)$d['bytes'], $mailTotal) ?? '—') ?></td>
            <td><?= $snap30 ? change($chg) : '—' ?></td>
            <td><?= (int)$d['deleted_mailboxes'] ? (int)$d['deleted_mailboxes'] . ' · ' . bytes($d['deleted_bytes']) : '—' ?></td>
          </tr>
<?php endforeach ?>
          <tr class="total"><td class="l">All domains</td><td class="l"></td>
            <td><?= $totals['mailboxes'] ?> (<?= $totals['active'] ?> active<?= $totals['mailboxes'] - $totals['active'] ? ', ' . ($totals['mailboxes'] - $totals['active']) . ' off' : '' ?>)</td>
            <td><?= bytes($mailTotal) ?></td><td><?= num($totals['messages']) ?></td><td>100%</td>
            <td><?= $changeKnown ? change($totals['change']) : '—' ?></td>
            <td><?= $totals['deleted'] ? $totals['deleted'] . ' · ' . bytes($totals['deleted_bytes']) : '—' ?></td></tr>
        </tbody>
      </table>
    </div>
<?php
    $named = array_values(array_filter($domains, fn($d) => isset($domainHistory[$d['domain']])));
    if (count($named) > 1):
        $series = [];
        foreach (array_slice($named, 0, 5) as $i => $d) {
            $series[] = [$d['domain'], 'c-d' . ($i + 1), $domainHistory[$d['domain']]];
        }
        if (count($named) > 5) {
            $rest = [];
            foreach (array_slice($named, 5) as $d) {
                foreach ($domainHistory[$d['domain']] as $day => $v) {
                    $rest[$day] = ($rest[$day] ?? 0) + (float)$v;
                }
            }
            $series[] = ['Other domains', 'c-d6', $rest];
        }
?>
    <div class="block"><span class="title">Domains, last 12 months</span>
      <?= chart($series, 'Domain sizes over the last 12 months') ?>
    </div>
<?php endif ?>
  </section>

  <section aria-labelledby="mailboxes">
    <div class="tools">
      <h2 id="mailboxes">Mailboxes</h2>
      <div class="controls">
        <label hidden data-js>Domain <select id="domain-filter"><option value="">All domains</option>
<?php foreach ($domains as $d): if ((int)$d['mailboxes'] > 0): ?>
          <option value="<?= h($d['domain']) ?>"><?= h($d['domain']) ?></option>
<?php endif; endforeach ?>
        </select></label>
        <label hidden data-js>Find <input type="search" id="find" placeholder="address or name"></label>
        <a href="?csv=mailboxes">Download CSV</a>
      </div>
    </div>
    <p class="muted"><span class="flag">amber</span> worth a look: over <?= num($limits['unread_max']) ?> unread in the Inbox,
      unread grown by over <?= num($limits['unread_growth']) ?> in 30 days, or over <?= $limits['quota_full'] ?>% of the quota used
      (thresholds: installation guide, Mail storage statistics).
      Grey rows: mailboxes that don't work, turned off themselves or by their domain.</p>
    <div class="scroll tall">
      <table class="sortable" id="mailbox-table">
        <thead><tr>
          <th class="l"><button type="button" data-type="text">Mailbox</button></th>
          <th class="l"><button type="button" data-type="text">Name</button></th>
          <th class="l"><button type="button" data-type="text">Active</button></th>
          <th aria-sort="descending"><button type="button" data-type="num">Size</button></th>
          <th><button type="button" data-type="num">Messages</button></th>
          <th><button type="button" data-type="num">Unread in Inbox</button></th>
          <th><button type="button" data-type="num">Unread, 30 days</button></th>
          <th><button type="button" data-type="num">Trash</button></th>
          <th><button type="button" data-type="num">Junk</button></th>
          <th><button type="button" data-type="num">Sent</button></th>
          <th><button type="button" data-type="num">Quota</button></th>
          <th><button type="button" data-type="num">Used</button></th>
          <th><button type="button" data-type="text">Created</button></th>
        </tr></thead>
        <tbody>
<?php foreach ($boxes as $b):
        $unreadFlag = $b['unread_inbox'] !== null && (int)$b['unread_inbox'] > $limits['unread_max'];
        $growthFlag = $b['unread_change'] !== null && $b['unread_change'] > $limits['unread_growth'];
        $quotaFlag = $b['quota_used'] !== null && $b['quota_used'] > $limits['quota_full'];
        $v = fn($x) => $x === null ? '-1' : (string)$x;
?>
          <tr<?= $b['state'] === 'yes' ? '' : ' class="off"' ?> data-domain="<?= h($b['domain']) ?>" data-text="<?= h(mb_strtolower($b['address'] . ' ' . $b['name'])) ?>">
            <td class="l"><?= h($b['address']) ?></td><td class="l"><?= h($b['name']) ?></td>
            <td class="l"><?= h($b['state']) ?></td>
            <td class="big" data-v="<?= $v($b['bytes']) ?>"><?= bytes($b['bytes']) ?></td>
            <td data-v="<?= $v($b['messages']) ?>"><?= num($b['messages']) ?></td>
            <td data-v="<?= $v($b['unread_inbox']) ?>"><?= $unreadFlag ? '<span class="flag">' . num($b['unread_inbox']) . '</span>' : num($b['unread_inbox']) ?></td>
            <td data-v="<?= $b['unread_change'] === null ? '-999999999' : $b['unread_change'] ?>"><?php
                $u = $b['unread_change'] === null ? '—' : ($b['unread_change'] > 0 ? '+' : '') . number_format($b['unread_change']);
                echo $growthFlag ? '<span class="flag">' . h($u) . '</span>' : h($u) ?></td>
            <td data-v="<?= $v($b['trash_bytes']) ?>"><?= bytes($b['trash_bytes']) ?></td>
            <td data-v="<?= $v($b['junk_bytes']) ?>"><?= bytes($b['junk_bytes']) ?></td>
            <td data-v="<?= $v($b['sent_bytes']) ?>"><?= bytes($b['sent_bytes']) ?></td>
            <td data-v="<?= (int)$b['quota_bytes'] ?: '-1' ?>"><?= (int)$b['quota_bytes'] ? bytes($b['quota_bytes']) : '—' ?></td>
            <td data-v="<?= $b['quota_used'] === null ? '-1' : round($b['quota_used'], 2) ?>"><?php
                $q = $b['quota_used'] === null ? '—' : number_format($b['quota_used'], 0) . '%';
                echo $quotaFlag ? '<span class="flag">' . h($q) . '</span>' : h($q) ?></td>
            <td><?= h(substr((string)$b['created'], 0, 10)) ?></td>
          </tr>
<?php endforeach ?>
        </tbody>
      </table>
    </div>
    <p class="muted" id="shown"><?= count($boxes) ?> mailboxes<?= $snap30 ? '' : ' · "Unread, 30 days" builds up during the first month' ?></p>
  </section>

  <section aria-labelledby="deleted">
    <div class="tools">
      <h2 id="deleted">Deleted mailboxes</h2>
<?php if ($deleted): ?>
      <div class="controls">
        <label hidden data-js>Find <input type="search" id="find-deleted" placeholder="address"></label>
      </div>
<?php endif ?>
    </div>
    <p class="muted">The mail of a mailbox deleted in PostfixAdmin is kept <?= TRASH_DAYS ?> days, then deleted for good.
      Until then it can be restored (installation guide: Restoring a deleted mailbox).</p>
<?php if (!$deleted): ?>
    <p class="muted">None.</p>
<?php else: ?>
    <div class="scroll tall">
      <table class="sortable" id="deleted-table">
        <thead><tr>
          <th class="l" aria-sort="ascending"><button type="button" data-type="text">Mailbox</button></th>
          <th><button type="button" data-type="num">Size</button></th>
          <th><button type="button" data-type="text">Deleted</button></th>
          <th><button type="button" data-type="num">Days left</button></th>
        </tr></thead>
        <tbody>
<?php $trashTotal = 0; $trashKnown = true;
      foreach ($deleted as $x):
        $left = TRASH_DAYS - (int)$x['age'];
        if ($x['bytes'] === null) {
            $trashKnown = false;
        } else {
            $trashTotal += (float)$x['bytes'];
        }
?>
          <tr data-text="<?= h(mb_strtolower($x['address'])) ?>"><td class="l"><?= h($x['address']) ?></td>
            <td data-v="<?= $x['bytes'] === null ? '-1' : $x['bytes'] ?>"><?= $x['bytes'] !== null ? bytes($x['bytes'])
                : ((int)$x['size_attempts'] >= 3 ? 'too large to count' : 'not counted yet') ?></td>
            <td><?= h(substr((string)$x['deleted_at'], 0, 10)) ?></td>
            <td data-v="<?= $left ?>"><?= $left <= 7 ? '<span class="flag">' . ($left <= 0 ? 'today' : $left) . '</span>' : $left ?></td></tr>
<?php endforeach ?>
        </tbody>
        <tfoot>
          <tr class="total"><td class="l" id="deleted-count"><?= count($deleted) ?> mailboxes</td>
            <td><?= bytes($trashTotal) . ($trashKnown ? '' : ' +') ?></td><td></td><td></td></tr>
        </tfoot>
      </table>
    </div>
<?php endif ?>
  </section>
<?php endif ?>

  <footer>
    <a href="/">Administration</a>
    <span>Flashlight {Version}</span>
  </footer>
</div>
<script nonce="<?= h($nonce) ?>">
(function () {
  document.querySelectorAll('[data-js]').forEach(function (el) { el.hidden = false; });

  // sorting by a click on a column title: numbers by their data-v, the rest as text
  document.querySelectorAll('table.sortable').forEach(function (table) {
    var body = table.tBodies[0], heads = table.tHead.rows[0].cells;
    Array.prototype.forEach.call(heads, function (th, col) {
      var button = th.querySelector('button');
      button.addEventListener('click', function () {
        var desc = th.getAttribute('aria-sort') !== 'descending';
        Array.prototype.forEach.call(heads, function (other) { other.removeAttribute('aria-sort'); });
        th.setAttribute('aria-sort', desc ? 'descending' : 'ascending');
        var num = button.dataset.type === 'num', rows = Array.prototype.slice.call(body.rows);
        rows.sort(function (a, b) {
          var x = a.cells[col], y = b.cells[col];
          var r = num ? parseFloat(x.dataset.v) - parseFloat(y.dataset.v) : x.textContent.localeCompare(y.textContent);
          return desc ? -r : r;
        });
        rows.forEach(function (r) { body.appendChild(r); });
      });
    });
  });

  // finding rows: a text field (and for mailboxes, the domain); the note under the table counts what is shown
  function finder(tableId, findId, selectId, countId, noun) {
    var table = document.getElementById(tableId);
    if (!table) return null;
    var rows = Array.prototype.slice.call(table.tBodies[0].rows), find = document.getElementById(findId);
    var select = selectId && document.getElementById(selectId), count = document.getElementById(countId);
    var note = count.textContent;
    function filter() {
      var d = select ? select.value : '', q = find.value.trim().toLowerCase(), n = 0;
      rows.forEach(function (r) {
        var ok = (!d || r.dataset.domain === d) && (!q || r.dataset.text.indexOf(q) !== -1);
        r.hidden = !ok;
        if (ok) n++;
      });
      count.textContent = (n === rows.length) ? note : 'Showing ' + n + ' of ' + rows.length + ' ' + noun;
    }
    find.addEventListener('input', filter);
    if (select) select.addEventListener('change', filter);
    return { select: select, filter: filter };
  }
  var boxes = finder('mailbox-table', 'find', 'domain-filter', 'shown', 'mailboxes');
  finder('deleted-table', 'find-deleted', null, 'deleted-count', 'mailboxes');
  if (boxes) {
    document.querySelectorAll('a[data-domain]').forEach(function (a) {
      a.addEventListener('click', function () { boxes.select.value = a.dataset.domain; boxes.filter(); });
    });
  }
})();
</script>
</body>
</html>
