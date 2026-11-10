#!/bin/bash
set -eu
# `dseditgroup` returns non-zero when the user is already a member.
/usr/sbin/dseditgroup -o edit -a 'daijh' -t user operator || true
/usr/sbin/dseditgroup -o checkmember -m 'daijh' operator
echo "OPERATOR_GROUP_READY"
