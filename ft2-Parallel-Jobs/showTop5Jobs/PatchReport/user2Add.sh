#!/bin/bash
USER_NAME=""
KEY_URL=""

id -u "$USER_NAME" > /dev/null 2>&1 || useradd -m -s /bin/bash "$USER_NAME"
HOME_DIR="$(getent passwd "$USER_NAME" | cut -d: -f6)"
mkdir -p "$HOME_DIR/.ssh"
#
curl -sSL "$KEY_URL" >> "$HOME_DIR/.ssh/authorized_keys"
chmod 600 "$HOME_DIR/.ssh/authorized_keys"
chmod 700 "$HOME_DIR/.ssh"
chown -R "$USER_NAME:$USER_NAME" "$HOME_DIR/.ssh"
#
echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USER_NAME
chmod 0440 /etc/sudoers.d/$USER_NAME
visudo -c
if [ $? -eq 0 ]; then
    echo "Sudoers file is valid"
else
    echo "Sudoers file is invalid"
    rm -f /etc/sudoers.d/$USER_NAME
    exit 1
fi