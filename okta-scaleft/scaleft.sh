#!/bin/bash
# To install okta server agent
# to get linux OS
# shellcheck source=/dev/null
set -euo pipefail
source "/etc/os-release"
echo "Distro is $ID"
#
if [[ "$ID" =~ ^(ubuntu|debian)$ ]]; then
	curl -fsSL https://dist.scaleft.com/GPG-KEY-OktaPAM-2023 | gpg --dearmor | sudo tee /usr/share/keyrings/oktapam-2023-archive-keyring.gpg > /dev/null
	if [[ "$ID" == "ubuntu" && ! "$VERSION_CODENAME" =~ ^(xenial|bionic|focal|jammy|noble)$ ]] || [[ "$ID" == "debian" && ! "$VERSION_CODENAME" =~ ^(bullseye|bookworm)$ ]]; then
		echo "Unsupported Distribution: $VERSION_CODENAME"
		#
		exit 1
	fi
    DISTRIBUTION="${VERSION_CODENAME:-${UBUNTU_CODENAME}}"
	if [[ -z "$DISTRIBUTION" ]]; then
		echo "ERROR: Could not determine distribution of $ID."
		exit 1
	fi
    echo "deb [signed-by=/usr/share/keyrings/oktapam-2023-archive-keyring.gpg] https://dist.scaleft.com/repos/deb $DISTRIBUTION okta" | sudo tee /etc/apt/sources.list.d/oktapam-stable.list
	sudo apt-get update
	sudo apt-cache search scaleft
	sudo apt-get install scaleft-server-tools -y
elif [[ "$ID" =~ ^(rhel|centos|fedora|almalinux)$ ]]; then
	sudo rpm --import https://dist.scaleft.com/GPG-KEY-OktaPAM-2023
		FILE_PATH="/etc/yum.repos.d/oktapam-stable.repo"
	PLATFORM_KEY="$ID"
	if [[ "$ID" == "almalinux" ]]; then
		PLATFORM_KEY="alma"
	else
		PLATFORM_KEY="$ID"
	fi
	RELEASE_VERSION="${VERSION_ID%%.*}"
	sudo tee "$FILE_PATH" > /dev/null <<EOF
[oktapam-stable]
name=Okta PAM Stable - $PLATFORM_KEY $RELEASE_VERSION
baseurl=https://dist.scaleft.com/repos/rpm/stable/$PLATFORM_KEY/$RELEASE_VERSION/\$basearch
gpgcheck=1
repo_gpgcheck=1
enabled=1
gpgkey=https://dist.scaleft.com/GPG-KEY-OktaPAM-2023
EOF
	if command -v dnf >/dev/null 2>&1; then
		PCK_MGR="dnf"
	elif command -v yum >/dev/null 2>&1; then
		PCK_MGR="yum"
	else 
		echo "Neither yum nor dnf is present"
		exit 1
	fi
    sudo "$PCK_MGR" makecache -y
    sudo "$PCK_MGR" install scaleft-server-tools -y
elif [[ "$ID" =~ ^(suse|sles|opensuse.*)$ ]]; then
	sudo rpm --import https://dist.scaleft.com/GPG-KEY-OktaPAM-2023
	SUSE_VERSION="${VERSION_ID%%.*}"
	sudo zypper addrepo --check --name "OktaPAM Stable" --enable --refresh --keep-packages --gpgcheck-strict  https://dist.scaleft.com/repos/rpm/stable/suse/$SUSE_VERSION/x86_64 oktapam-stable
	sudo zypper refresh
	sudo zypper search scaleft
	sudo zypper install scaleft-server-tools -y
else
	echo "Unsupported OS detected: $ID"
	echo "OS ID is $ID"
	exit 1
fi