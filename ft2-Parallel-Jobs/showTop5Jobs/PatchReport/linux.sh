#!/bin/bash
UP_TIME="$(uptime | cut -d' ' -f3-7)" # "$(uptime -p)"
OS_ID="$(source /etc/os-release && echo "$ID")"
HOST_NAME="$(hostname)"

## Ubuntu
PKG_INSTALLED="$(grep "$(date +%Y-%m-)" /var/log/dpkg.log | grep " upgrade " | awk '{print $4 "=" $6}' | paste -sd";" -)"
PKG_INSTALLED="${PKG_INSTALLED:-NothingInstalled}"
#
ARR_HOST=( "$HOST_NAME" "$OS_ID" "$PKG_INSTALLED" "$UP_TIME" )
(IFS='#'; echo "<x>${ARR_HOST[*]}<x>")
## SUSE Linux
#
PKG="$(awk -F'|' -v start="$(date +%Y-%m-)" '$1 ~ start && $2 ~ /install|update/ {print $3 "=" $4}' /var/log/zypp/history | paste -sd';')"
PKG="${PKG:-NothingInstalled}"
## Centos
PKG="$(grep "$(date +%b)" /var/log/yum.log | awk '$4 ~ /Updated|Installed/ {print $5}' | paste -sd ';')"

## RHEL
PKG="$(rpm -qa --last | grep "$(date +'%b %Y')" | awk '{print $1}' | paste -sd ';')"

PKG="${PKG:-NothingInstalled}"
ARR_HOST=( "$HOST_NAME" "$OS_ID" "$PKG" "$UP_TIME" )
(IFS='#'; echo "<x>${ARR_HOST[*]}<x>")