#!/bin/bash
UP_TIME="$(uptime | cut -d' ' -f3-7)"
HOST_NAME="$(hostname)"
OS_ID="$(source /etc/os-release && echo "$ID")"
# Determine installed/updated packages based on OS
case "$OS_ID" in
  ubuntu|debian)
    #
    PKG_INSTALLED="$(grep "$(date +%Y-%m-)" /var/log/dpkg.log | grep " upgrade " | awk '{print $4 "=" $6}' | paste -sd ';' -)"
    ;;
  suse|opensuse*)
    PKG_INSTALLED="$(awk -F'|' -v start="$(date +%Y-%m-)" '$1 ~ start && $2 ~ /install|update/ {print $3 "=" $4}' /var/log/zypp/history | paste -sd ';')"
    #
    ;;
  centos|rhel|fedora|rocky|alma)
    if [[ -f /var/log/yum.log ]]; then
      PKG_INSTALLED="$(grep "$(date +%b)" /var/log/yum.log | awk '$4 ~ /Updated|Installed/ {print $5}' | paste -sd ';')"
    else
      PKG_INSTALLED="$(rpm -qa --last | grep "$(date +'%b %Y')" | awk '{print $1}' | paste -sd ';')"
    fi
    ;;
  *)
    PKG_INSTALLED="OS detection failed - $OS_ID"
    ;;
esac
PKG_INSTALLED="${PKG_INSTALLED:-NothingInstalled}"
ARR_HOST=( "$HOST_NAME" "$OS_ID" "$PKG_INSTALLED" "$UP_TIME" )
(IFS='#'; echo "<x>${ARR_HOST[*]}<x>")