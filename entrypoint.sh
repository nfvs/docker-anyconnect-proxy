#!/bin/sh

# Fill in hostname in csd-wrapper file
sed -i "s/^CSD_HOSTNAME=.*$/CSD_HOSTNAME=${ANYCONNECT_HOST}/" /csd-wrapper.sh

( echo yes; echo $ANYCONNECT_PASSWORD ) | openconnect $ANYCONNECT_SERVER --user=$ANYCONNECT_USER --authgroup=$ANYCONNECT_GROUP --timestamp