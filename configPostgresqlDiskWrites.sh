#!/bin/sh
# This file is part of the nominatim installation.
# It changes the postgresql configuration to write changes to disk.

# Need to sync these with configPostgresql.sh
PGver=9.3
CONFIG_FILE=/etc/postgresql/$PGver/main/postgresql.conf
TEMP_FILE=${CONFIG_FILE}.TMP 

# After the initial nominatim import these two variables need to be turned back on to avoid database corruption.
FSYNC=on
FULL_PAGE_WRITES=on


echo "#\tAdjusting postgres configuration settings"

if [ -e $CONFIG_FILE ]; then
	echo "#\tApplying the following changes:"
	echo "#\tfsync                         $FSYNC"
	echo "#\tfull_page_writes              $FULL_PAGE_WRITES"
	
	sed \
-e "s/[#]*fsync = .*/fsync = $FSYNC/" \
-e "s/[#]*full_page_writes = .*/full_page_writes = $FULL_PAGE_WRITES/" \
$CONFIG_FILE > $TEMP_FILE

	# Make the change
	mv $TEMP_FILE $CONFIG_FILE
fi 

echo "#\tReload postgres for the changes to come into effect"

# Ends
