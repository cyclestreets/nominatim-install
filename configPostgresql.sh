#!/bin/sh

# configPG.sh:
#
# This script automatically detects system RAM and other resources
# and modifies $PG_DATA_DIR/postgresql.conf to configure the server
# for one of three uses:  web, oltp, or data warehousing.
# 
# Author: rocket357@users.sourceforge.net
# License: BSD
#
# This script uses the conventions found at:
# http://www.slideshare.net/oscon2007/performance-whack-a-mole
#
# The following comment is taken from the slide
# "What Color Is My Application" found at the above url...
#
# web = web application backend
#       1) DB smaller than RAM
#       2) 90% or more simple read queries
# oltp = online transaction processing
#	1) db slightly larger than RAM, up to 1 TB
#	2) 20-40% small data write queries
#	3) some long transactions
# dw = data warehousing
#	1) large to huge databases (100 GB to 100 TB)
#	2) large complex report queries
#	3) large bulk loads of data
#	4) also called "Decision Support" or "Business Intelligence"  

# CHANGELOG
# v0.1 - Initial post to LQ.org 

set -e # bomb out if something goes wrong... 

if [ ! `whoami` = 'root' ]; then
	echo "This script needs to run as root because"
	echo "it alters shm{max,mni,all}"
	exit
fi

# Check if the 'usage' parameter has been supplied
if [ -z "$1" ]; then
	echo "Usage:  ./configPG.sh [template]"
	echo "Where [template] is one of:"
	echo "	'web'  (web backend server)"
	echo "	'oltp' (online transaction processing)"
	echo "	'dw'   (data warehouse)"
	echo "See http://www.slideshare.net/oscon2007/performance-whack-a-mole"
	echo "for further explanation."
	exit
fi

# Check if the 'dedicated' parameter has been supplied
if [ -z "$2" ]; then
    echo -n "Will this machine be dedicated (i.e. PostgreSQL is the only active service)? (y/n) "
    read dedicated
else
    dedicated=$2
fi

echo "#\tConfiguring as usage type: $1, Dedicated PostgreSQL server: ${dedicated}"

###################################
### USER CONFIGURABLE VARIABLES ###
################################### 

# Postgres version
PGver=9.1

# These variables are for Debian...be sure to alter them if your OS is different!
PGHOMEDIR=/var/lib/postgresql
PGDATADIR=$PGHOMEDIR/$PGver/main
CONFIG_FILE=/etc/postgresql/$PGver/main/postgresql.conf
TEMP_FILE=${CONFIG_FILE}.TMP 

# These two are taken from performance-whack-a-mole (see link in header comments)
SHARED_BUFFER_RATIO=0.25
EFFECTIVE_CACHE_RATIO=0.67 

if [ "$1" = "web" ]; then # web backend server 
	NUM_CONN=400
	WORK_MEM=512 # kB
	CHECKPOINT_SEG=8
	MAINT_WORK_MEM=128MB
elif [ "$1" = "oltp" ]; then # online transaction processing
	if [ $dedicated = 'y' ]; then
		NUM_CONN=50
		WORK_MEM=8192 # kB
	else
		NUM_CONN=200
		WORK_MEM=2048 # kB
	fi
	CHECKPOINT_SEG=16
	MAINT_WORK_MEM=128MB
elif [ "$1" = "dw" ]; then # data warehousing
	NUM_CONN=100
	WORK_MEM=131072 # kB
	CHECKPOINT_SEG=64
	MAINT_WORK_MEM=1024MB
fi

#######################################
### END USER CONFIGURABLE VARIABLES ###
####################################### 

# first let's locate the configuration file...
if [ -e $CONFIG_FILE ]; then
	echo "#\tBacking up original config file to $CONFIG_FILE.BACKUP"
	cp $CONFIG_FILE $CONFIG_FILE.BACKUP
	echo "#\tBacking up /etc/sysctl.conf to $PGHOMEDIR/sysctl.conf.BACKUP"
	cp /etc/sysctl.conf $PGHOMEDIR/sysctl.conf.BACKUP
else
	echo "#\tUnable to locate the PostgreSQL config file. Cannot continue, stopping."
	exit 1
fi


OS_TYPE=`uname -s`

### LINUX
if [ "$OS_TYPE" = "Linux" -o "$OS_TYPE" = "GNU/Linux" ]; then

	SYSCTL_KERNEL_NAME="kernel"
	MAX_MEM_KB=`grep MemTotal /proc/meminfo | sed -e 's/^[^0-9]*//' | cut -d' ' -f1`
	OS_PAGE_SIZE=`getconf PAGE_SIZE`

### OPENBSD
elif [ "$OS_TYPE" = "OpenBSD" ]; then

	SYSCTL_KERNEL_NAME="kern.shminfo"
	MAX_MEM_KB=$(echo "scale=0; `dmesg | grep \"real mem\" | cut -d\"=\" -f2 | cut -d\"(\" -f1`/1024" | bc -l ) # convert to kB
	OS_PAGE_SIZE=`sysctl hw.pagesize | cut -d'=' -f2`

### UNKNOWN?
else
	echo "$OS_TYPE isn't supported"
	exit
fi

echo "#\tConfiguring for system type: $OS_TYPE, max memory: $MAX_MEM_KB kB, page size: $OS_PAGE_SIZE bytes."

# make sure work_mem isn't greater than total memory divided by number of connections...
WORK_MEM_KB=$(echo "scale=0; $MAX_MEM_KB/$NUM_CONN" | bc -l)
if [ $WORK_MEM_KB -gt $WORK_MEM ]; then
	while [ $WORK_MEM -lt $WORK_MEM_KB ]; do
		WORK_MEM_TEMP=$(echo "scale=0; $WORK_MEM*2" | bc -l)
		if [ $WORK_MEM_TEMP -lt $WORK_MEM_KB ]; then
			WORK_MEM=$(echo "scale=0; $WORK_MEM*2" | bc -l)
		else
			WORK_MEM_KB=0
		fi
	done	 
	WORK_MEM_KB=$WORK_MEM; 
fi
WORK_MEM=$(echo "scale=0; $WORK_MEM_KB/1024" | bc -l)MB

# OS settings
HOSTNAME=`hostname`

# shm{mni,all,max} are critical to PostgreSQL starting.  
# They must be high enough for these settings:
# 	max_connections
# 	max_prepared_transactions
# 	shared_buffers
# 	wal_buffers
# 	max_fsm_relations
# 	max_fsm_pages 

echo "#\tChecking the current kernel's shared memory settings..."
# The sysctl calls below echo their own output.

# Changes to files will be made below
pgConfigNote="\n#\tPostgresql Config - Nominatim Setup\n"

# SHMMAX
#
# (BLOCK_SIZE + 208) * ((MAX_MEM_KB * 1024) / PAGE_SIZE) * $SHARED_BUFFER_RATIO) 
SHMMAX=`sysctl $SYSCTL_KERNEL_NAME.shmmax | cut -d'=' -f2`
# Removed the appended zero from the following line (relative to the original) which had the unjustified effect of making it ten times too big
OPTIMAL_SHMMAX=`echo "scale=0; (8192 + 208) * (($MAX_MEM_KB * 1024) / $OS_PAGE_SIZE) * $SHARED_BUFFER_RATIO" | bc -l | cut -d'.' -f1`

# Development test
echo "#\tDevelopment test -stopping WIP"
exit
if [ $SHMMAX -lt $OPTIMAL_SHMMAX ]; then

    sysctl $SYSCTL_KERNEL_NAME.shmmax=$OPTIMAL_SHMMAX
    echo "${pgConfigNote}$SYSCTL_KERNEL_NAME.shmmax=$OPTIMAL_SHMMAX" >> /etc/sysctl.conf
    # Nullify to avoid repeating the note
    pgConfigNote=
fi

# SHMMNI
#
# 4096 - 8192

# This parameter seems to be best left alone. The suggested 32768 is way too big.
#SHMMNI=`sysctl $SYSCTL_KERNEL_NAME.shmmni | cut -d'=' -f2`
#OPTIMAL_SHMMNI=32768 # systems with large amounts of RAM, drop if you don't have 128GB or so...
#if [ $SHMMNI -lt $OPTIMAL_SHMMNI ]; then
#    sysctl $SYSCTL_KERNEL_NAME.shmmni=$OPTIMAL_SHMMNI
#    echo "${pgConfigNote}$SYSCTL_KERNEL_NAME.shmmni=$OPTIMAL_SHMMNI" >> /etc/sysctl.conf
#    # Nullify to avoid repeating the note
#    pgConfigNote=
#fi



# SHMALL
#
# SHMMAX / PAGE_SIZE 

SHMALL=`sysctl $SYSCTL_KERNEL_NAME.shmall | cut -d'=' -f2`
OPTIMAL_SHMALL=`echo "scale=0; $OPTIMAL_SHMMAX / $OS_PAGE_SIZE" | bc -l | cut -d'.' -f1`
if [ $SHMALL -lt $OPTIMAL_SHMALL ]; then
    sysctl $SYSCTL_KERNEL_NAME.shmall=$OPTIMAL_SHMALL
    echo "${pgConfigNote}$SYSCTL_KERNEL_NAME.shmall=$OPTIMAL_SHMALL" >> /etc/sysctl.conf
    # Nullify to avoid repeating the note
    pgConfigNote=
fi

# Development test
echo "#\tDevelopment test -stopping WIP"
exit


# MAX_MEM_KB as MB
MAX_MEM_MB=$(echo "scale=0; $MAX_MEM_KB/1024" | bc -l)
SHARED_BUFFERS=$(echo "scale=0; $MAX_MEM_MB * $SHARED_BUFFER_RATIO" | bc -l | cut -d'.' -f1)
# There has been debate on this value on the postgresql mailing lists.
# You might not get any performance gain over 8 GB.  Please test!
if [ $SHARED_BUFFERS -gt 12000 ]; then
       SHARED_BUFFERS=12000MB;
else
       SHARED_BUFFERS="$SHARED_BUFFERS"MB
fi

if [ "$OS_TYPE" = "Linux" -o "$OS_TYPE" = "GNU/Linux" ]; then
       echo "Setting virtual memory sysctls"
       sysctl vm.swappiness=0
       echo "vm.swappiness=0" >>/etc/sysctl.conf
       sysctl vm.overcommit_memory=2
       echo "vm.overcommit_memory=2" >>/etc/sysctl.conf

       # >8GB RAM?  Don't let dirty data build up...this can cause latency issues!
       # These settings taken from "PostgreSQL 9.0 High Performance" by Gregory Smith
       if [ $MAX_MEM_MB -gt 8192 ]; then 
             echo 2 > /proc/sys/vm/dirty_ratio
             echo 1 > /proc/sys/vm/dirty_background_ratio
       else
             echo 10 > /proc/sys/vm/dirty_ratio
             echo 5 > /proc/sys/vm/dirty_background_ratio              
       fi
fi

WAL_BUFFERS="16MB"
EFFECTIVE_CACHE_SIZE=$(echo "scale=0; $MAX_MEM_MB * $EFFECTIVE_CACHE_RATIO" | bc -l | cut -d'.' -f1)MB


### NOW THE FUN STUFF!!
echo "Applying system configuration settings to the server..."

 
echo "This system appears to have $MAX_MEM_MB MB maximum memory..."

if [ -e $CONFIG_FILE ]; then
	echo "Setting data_directory to:       $PGDATADIR"
	echo "Setting listen_addresses to:     '*'"
	echo "Setting port to:                 5432"
	echo "Setting max_connections to:      $NUM_CONN"
	echo "Setting shared_buffers to:       $SHARED_BUFFERS"
	echo "Setting work_mem to:             $WORK_MEM"
	echo "Setting effective_cache_size to: $EFFECTIVE_CACHE_SIZE"
	echo "Setting checkpoint_segments to:  $CHECKPOINT_SEG"
	echo "Setting maintenance_work_mem to: $MAINT_WORK_MEM"
	echo "Setting wal_buffers to:          $WAL_BUFFERS"
	
	sed \
-e "s@[#]*data_directory = .*@data_directory = \'$PGDATADIR\'@" \
-e "s/[#]*listen_addresses = .*/listen_addresses = \'\*\'/" \
-e "s/[#]*port = .*/port = 5432/" \
-e "s/[#]*max_connections = .*/max_connections = $NUM_CONN/" \
-e "s/[#]*ssl = .*/ssl = false/" \
-e "s/[#]*shared_buffers = .*/shared_buffers = $SHARED_BUFFERS/" \
-e "s/[#]*work_mem = .*/work_mem = $WORK_MEM/" \
-e "s/[#]*effective_cache_size = .*/effective_cache_size = $EFFECTIVE_CACHE_SIZE/" \
-e "s/[#]*checkpoint_segments = .*/checkpoint_segments = $CHECKPOINT_SEG/" \
-e "s/[#]*maintenance_work_mem = .*/maintenance_work_mem = $MAINT_WORK_MEM/" \
-e "s/[#]*wal_buffers = .*/wal_buffers = $WAL_BUFFERS/" \
-e "s/[#]*cpu_tuple_cost = .*/cpu_tuple_cost = 0.002/" \
-e "s/[#]*cpu_index_tuple_cost = .*/cpu_index_tuple_cost = 0.0002/" \
-e "s/[#]*cpu_operator_cost = .*/cpu_operator_cost = 0.0005/" \
$CONFIG_FILE > $TEMP_FILE
	mv $TEMP_FILE $CONFIG_FILE

else
	echo "Unable to locate the PostgreSQL config file!  Can't continue!"
	exit 1
fi 

echo "Done!"