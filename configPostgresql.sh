#!/bin/sh

# configPG.sh:
#
# This script automatically detects system RAM and other resources
# and modifies $PG_DATA_DIR/postgresql.conf to configure the server
# for one of three uses:  web, oltp, or data warehousing.
# 
# Author: rocket357_AT_users.sourceforge.net
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
# This version heavily customized to support a Nominatim installation for CycleStreets

echo "#\tPostgresql configuring based on system memory and recommended formulae"


set -e # bomb out if something goes wrong... 

if [ ! `whoami` = 'root' ]; then
	echo "This script needs to run as root because"
	echo "it alters shm{max,mni,all}"
	exit
fi

# Check if the 'usage' parameter has been supplied
if [ -z "$1" ]; then
	echo "#	Usage:  ./configPostgresql.sh [template] [dedicated] [override_maintenance_work_mem]"
	echo "#	Where [template] is one of:"
	echo "#		'web'  (web backend server)"
	echo "#		'oltp' (online transaction processing)"
	echo "#		'dw'   (data warehouse)"
	echo "#		See http://www.slideshare.net/oscon2007/performance-whack-a-mole for further explanation."
	echo "#	and [dedicated] is y/n depending on whether PostgreSQL is the only active service (defaults to n)"
	echo "#	and [override_maintenance_work_mem] is eg 16GB overrides the maint_work_mem (leave blank to assume a default)"
	exit
fi

# Check if the 'dedicated' parameter has been supplied
if [ -z "$2" ]; then
    echo -n "Will this machine be dedicated (i.e. PostgreSQL is the only active service)? (y/n) "
    read dedicated
else
    dedicated=$2
fi


# Bind the 'override_maintenance_work_mem' parameter
override_maintenance_work_mem=$3

echo "#\tConfiguring as usage type: $1, Dedicated PostgreSQL server: ${dedicated}, override_maintenance_work_mem: ${override_maintenance_work_mem}"

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

echo "#\tConfiguring for system type: $OS_TYPE, max memory: $MAX_MEM_KB kB, page size: $OS_PAGE_SIZE bytes, working memory ${WORK_MEM}."

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
       echo "#\tSetting virtual memory sysctls"
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

# Hard values based on: http://wiki.openstreetmap.org/wiki/Nominatim/Installation#Tuning_PostgreSQL
if [ -n "${override_maintenance_work_mem}" ]; then
    MAINT_WORK_MEM=${override_maintenance_work_mem}
fi
SYNCHRONOUS_COMMIT=off
CHECKPOINT_SEG=100
CHECKPOINT_TIMEOUT=10min
CHECKPOINT_COMPLETION_TARGET=0.9
# For the initial import - switch them on again afterwards or you risk database corruption
FSYNC=off
FULL_PAGE_WRITES=off

### NOW THE FUN STUFF!!
echo "#\tApplying system configuration settings to the server"
echo "#\tThis system appears to have $MAX_MEM_MB MB maximum memory."

if [ -e $CONFIG_FILE ]; then
	echo "#\tApplying the following changes:"
	echo "#\tshared_buffers                $SHARED_BUFFERS"
	echo "#\tmaintenance_work_mem          $MAINT_WORK_MEM"
	echo "#\twork_mem                      $WORK_MEM"
	echo "#\teffective_cache_size          $EFFECTIVE_CACHE_SIZE"
	echo "#\tsynchronous_commit            $SYNCHRONOUS_COMMIT"
	echo "#\tcheckpoint_segments           $CHECKPOINT_SEG"
	echo "#\tcheckpoint_timeout            $CHECKPOINT_TIMEOUT"
	echo "#\tcheckpoint_completion_target  $CHECKPOINT_COMPLETION_TARGET"
	echo "#\tfsync                         $FSYNC"
	echo "#\tfull_page_writes              $FULL_PAGE_WRITES"
	
	echo "#\tApplying the edits to ${TEMP_FILE}";
	sed \
-e "s/[#]*shared_buffers = .*/shared_buffers = $SHARED_BUFFERS/" \
-e "s/[#]*work_mem = .*/work_mem = $WORK_MEM/" \
-e "s/[#]*maintenance_work_mem = .*/maintenance_work_mem = $MAINT_WORK_MEM/" \
-e "s/[#]*effective_cache_size = .*/effective_cache_size = $EFFECTIVE_CACHE_SIZE/" \
-e "s/[#]*synchronous_commit = .*/synchronous_commit = $SYNCHRONOUS_COMMIT/" \
-e "s/[#]*checkpoint_segments = .*/checkpoint_segments = $CHECKPOINT_SEG/" \
-e "s/[#]*checkpoint_timeout = .*/checkpoint_timeout = $CHECKPOINT_TIMEOUT/" \
-e "s/[#]*checkpoint_completion_target = .*/checkpoint_completion_target = $CHECKPOINT_COMPLETION_TARGET/" \
-e "s/[#]*fsync = .*/fsync = $FSYNC/" \
-e "s/[#]*full_page_writes = .*/full_page_writes = $FULL_PAGE_WRITES/" \
$CONFIG_FILE > $TEMP_FILE

	# Make the change
	mv $TEMP_FILE $CONFIG_FILE
fi 

echo "#\tCompleted Postgresql autoConfiguration based on formulae that analyze available memory"
echo "#\tRestart postgres for the changes to come into effect"

# Ends
