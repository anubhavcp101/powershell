#!/bin/bash
# To install okta server agent
# to get linux OS
# shellcheck source=/dev/null
source "/etc/os-release"
echo "Distro is $ID"
if [[ "$ID" =~ ^(ubuntu|debian)$ ]]; then
    #
    curl -fsSL https://dist.scaleft.com/GPG-KEY-OktaPAM-2023 | gpg --dearmor | sudo tee /usr/share/keyrings/oktapam-2023-archive-keyring.gpg > /dev/null
    DISTRIBUTION="${VERSION_CODENAME:-${UBUNTU_CODENAME:-jammy}}"
    echo "deb [signed-by=/usr/share/keyrings/oktapam-2023-archive-keyring.gpg] https://dist.scaleft.com/repos/deb $DISTRIBUTION okta" | sudo tee /etc/apt/sources.list.d/oktapam-stable.list
    sudo apt-get update
    #
    sudo apt-cache search scaleft
    sudo apt-get install scaleft-server-tools -y
elif [[ "$ID" =~ ^(redhat|rhel|centos|fedora|almalinux)$ ]]; then
    sudo rpm --import https://dist.scaleft.com/GPG-KEY-OktaPAM-2023
    FILE_PATH="/etc/yum.repos.d/oktapam-stable.repo"
    
    if [ ! -f "$FILE_PATH" ]; then
        sudo touch "$FILE_PATH"
        sudo chmod 644 "$FILE_PATH"    
    fi
    PLATFORM_KEY="$ID"
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
    PKG_MGR=$(command -v dnf || command -v yum)
    sudo "$PKG_MGR" makecache -y
    sudo "$PKG_MGR" install scaleft-server-tools -y
elif [[ "$ID" =~ ^(suse|sles|opensuse.*)$ ]]; then
    sudo rpm --import https://dist.scaleft.com/GPG-KEY-OktaPAM-2023
    SUSE_VERSION="${VERSION_ID%%.*}"
    sudo zypper addrepo --check --name "OktaPAM Stable" --enable --refresh --keep-packages --gpgcheck-strict  https://dist.scaleft.com/repos/rpm/stable/suse/$SUSE_VERSION/x86_64 oktapam-stable
    sudo zypper -n update
    sudo zypper search scaleft
    sudo zypper install scaleft-server-tools -y
fi