#!/bin/bash

set -ue

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root. Try:"
    echo "sudo $0"
    exit 1
fi

echo "Space occupied on system/OS drive at the moment:"
df -h / | awk 'NR > 1'


#Check for all installations of WAVE software. Having multiple unnecessary installations of the WAVE client can occupy multiple GB of space.
echo "===================================="
echo "WAVE Client Versions (User):" && ls /home/wave/.local/share/Hanwha/client/hanwha 2> /dev/null || echo "...Nothing to see here bro..."
echo "===================================="
echo "WAVE Client Versions (Root):" && ls /opt/hanwha/client 2> /dev/null || echo "...Nothing to see here either..." ; echo "==============================="
echo "WAVE Media Server Version:"; cat /opt/hanwha/mediaserver/build_info.json | grep -Po '"'"vmsVersion"'"\s*:\s*"\K([^"]*)'
echo "===================================="

VIDEO_DATA="/opt/hanwha/mediaserver/var/data/"
echo "Video data stored on system drive?"
tracker=0
while IFS= read -r line; do
    SIZE=$(echo "$line" | cut -f1)
    if echo "$SIZE" | grep -q "[MG]" ; then
        echo "$line"
        tracker=1
    fi
done < <(du -sh $VIDEO_DATA*)

if [ "$tracker" -eq 0 ]; then
    echo "not enough to matter"
fi


echo "===================================="

LOGS="/var/log"
echo "Size of syslog files:"
du -sh $LOGS/syslog* 2> /dev/null || echo "No syslog files found"

echo "===================================="

echo "Size of journal:"
if [ -d "$LOGS/journal" ]; then
    du -sh "$LOGS/journal"
else
    echo "No journal present"
fi

echo "===================================="

echo "Snap library size:"
du -sh /var/lib/snapd

echo "===================================="

echo "Size of Downloads and Trash directory:"
du -sh /home/wave/* | grep "Downloads" || echo "No Downloads directory found"
du -sh /home/wave/.local/share/*  | grep "Trash" || echo "No Trash directory found"

echo "===================================="







    


