"""Builds x-maintenance.yaml from 2-deployment.yaml: same template without the instance (LaunchTemplate,
AutoScalingGroup) and without the Route 53 statement that imports the stage 1 zone list.

Run it after every change of 2-deployment.yaml, so both templates keep the same parameters and resources
(switching a stack between them must not lose parameter values or fail on allowed values):
    python build/make-maintenance.py 2-deployment.yaml x-maintenance.yaml
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
NL = '\r\n'
lines = open(src, newline='').read().split(NL)

# 1. drop the LaunchTemplate and AutoScalingGroup resources (top-level keys under Resources, 2-space indent)
out, skip = [], False
for l in lines:
    if l.startswith('  ') and not l.startswith('   ') and l.rstrip().endswith(':'):
        skip = l.strip() in ('LaunchTemplate:', 'AutoScalingGroup:')
    if not skip:
        out.append(l)
lines = out

# 2. replace the Route 53 statements (from their comment to the TXT condition) with a note
start = next(i for i, l in enumerate(lines) if 'DNS: TXT records only, in this stack' in l)
end = next(i for i, l in enumerate(lines) if i > start and "'route53:ChangeResourceRecordSetsRecordTypes': 'TXT'" in l)
lines[start:end + 1] = [
    "          # No Route 53 rights here: maintenance mode has no instance, and importing the zone list from stage 1",
    "          # would block the stage 1 update this mode exists for (an export can't change while it is imported)",
]

open(dst, 'w', newline='').write(NL.join(lines))
print('written', dst)
