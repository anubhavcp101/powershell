#!/bin/bash
url=''
dest='/opt/azcopy'
if [[ ! -d "$dest" ]]; then
    mkdir -p "$dest"
fi
cd "$dest" || exit
#
curl -L -o "azcopy.tar.gz" "$url"
tar -xvf azcopy.tar.gz --strip-components=1
file azcopy
chmod +x azcopy
#
./azcopy --version
cp azcopy "$dest/azcopy"
chmod +x "$dest/azcopy"
file "$dest/azcopy"
/opt/azcopy/azcopy --version