#!/bin/sh
# Script to install Nominatim on Ubuntu
# Tested on 14.04 (View Ubuntu version using 'lsb_release -a') using Postgres 9.3
# http://wiki.openstreetmap.org/wiki/Nominatim/Installation#Ubuntu.2FDebian
# Synced with: Latest revision as of 18:41, 22 January 2014

# !! Marker #idempotent indicates limit of testing for idempotency - it has not yet been possible to make it fully idempotent.

echo "#\tNominatim installation $(date)"

# Ensure this script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "#\tThis script must be run as root." 1>&2
    exit 1
fi

# Check if we are running in a Docker container
if grep --quiet docker /proc/1/cgroup; then
    dockerInstall=1
fi

# Bind current directory
nomInstalDir=$(pwd)

# Bomb out if something goes wrong
set -e

### CREDENTIALS ###
# Name of the credentials file
configFile=.config.sh

# Generate your own credentials file by copying from .config.sh.template
if [ ! -e ./${configFile} ]; then
    echo "#\tThe config file, ${configFile}, does not exist - copy your own based on the ${configFile}.template file." 1>&2
    exit 1
fi

# Load the credentials
. ./${configFile}

# Check either planet or extract selected
if [ -z "${planetUrl}" -a -z "${geofabrikUrl}" ]; then
    # Report and fail
    echo "#	Configuration error, please specify either a full planet or a Geofabrik extract"
    exit 1
fi

# Check either planet or extract selected but not both
if [ -n "${planetUrl}" -a -n "${geofabrikUrl}" ]; then
    # Report and fail
    echo "#	Configuration error, please specify either a full planet or a Geofabrik extract, not both"
    echo "#	Planet: ${planetUrl}"
    echo "#	Extract: ${geofabrikUrl}"
    exit 1
fi

# Download
if [ -n "${planetUrl}" ]; then

    # Options for a full planet
    osmdatafilename=planet-latest.osm.pbf
    osmdatafolder=wholePlanet/
    osmdataurl=${planetUrl}${osmdatafilename}

else
    # Options for a Geofabrik Extract
    osmdatafilename=${osmdatacountry}-latest.osm.pbf
    osmdataurl=${geofabrikUrl}${osmdatafolder}${osmdatafilename}
    osmupdates=${geofabrikUrl}${osmdatafolder}${osmdatacountry}-updates
fi

# Where the downloaded data is stored
osmdatapath=data/${osmdatafolder}${osmdatafilename}


### MAIN PROGRAM ###

# Ensure the system locale is UTF-8, to avoid Postgres install failure
echo -e "LANG=${utf8Language}.UTF-8\nLC_ALL=${utf8Language}.UTF-8" > /etc/default/locale
sudo locale-gen ${utf8Language} ${utf8Language}.UTF-8
dpkg-reconfigure locales

# Ensure there is a nominatim user account
if id -u ${username} >/dev/null 2>&1; then
    echo "#	User ${username} exists already and will be used."
else
    echo "#	User ${username} does not exist: creating now."

    # Request a password for the Nominatim user account; see http://stackoverflow.com/questions/3980668/how-to-get-a-password-from-a-shell-script-without-echoing
    if [ ! ${password} ]; then
	stty -echo
	printf "Please enter a password that will be used to create the Nominatim user account:"
	read password
	printf "\n"
	printf "Confirm that password:"
	read passwordconfirm
	printf "\n"
	stty echo
	if [ $password != $passwordconfirm ]; then
	    echo "#\tThe passwords did not match"
	    exit 1
	fi
    fi

    # Create the nominatim user
    useradd -m -p $password $username
    echo "#\tNominatim user ${username} created"
fi

# Prepare the apt index; it may be practically non-existent on a fresh VM
apt-get update

# Install basic software
apt-get -y install sudo
apt-get -y install wget


# Install software
echo "\n#\tInstalling software packages"
apt-get -y install build-essential libxml2-dev libgeos-dev libpq-dev libbz2-dev libtool automake libproj-dev
apt-get -y install libboost-dev libboost-system-dev libboost-filesystem-dev libboost-thread-dev
apt-get -y install gcc proj-bin libgeos-c1 osmosis libgeos++-dev
apt-get -y install php5 php-pear php5-pgsql php5-json php-db
apt-get -y install postgresql postgis postgresql-contrib postgresql-9.3-postgis-2.1 postgresql-server-dev-9.3
apt-get -y install libprotobuf-c0-dev protobuf-c-compiler

# Some additional packages that may not already be installed
# bc is needed in configPostgresql.sh
apt-get -y install bc

# Install Apache
echo "\n#\tInstalling Apache"
apt-get -y install apache2

# Install gdal, needed for US Tiger house number data (more steps need to be added to this script to support that US data)
echo "\n#\tInstalling gdal"
apt-get -y install python-gdal

# Temporarily allow commands to fail without exiting the script
set +e

# PHP Pear::DB is needed for the runtime website
# There doesn't seem an easy way to avoid this failing if it is already installed.
echo "\n#\tInstalling pear DB"
pear install DB

# Bomb out if something goes wrong
set -e

# skip if doing a Docker install as kernel parameters cannot be modified
if [ -z "${dockerInstall}" ]; then
    # Tuning PostgreSQL
    echo "\n#\tTuning PostgreSQL"
    ./configPostgresql.sh ${postgresconfigmode} n ${override_maintenance_work_mem}
fi

# Restart postgres assume the new config
echo "\n#\tRestarting PostgreSQL"
service postgresql restart

# We will use the Nominatim user's homedir for the installation, so switch to that
eval cd /home/${username}

# Get Nominatim software
apt-get -y install git autoconf-archive
if [ ! -d "/home/${username}/Nominatim/.git" ]; then
    # Install
    echo "\n#\tInstalling Nominatim software"
    sudo -u ${username} git clone --recursive https://github.com/twain47/Nominatim.git
    cd Nominatim
else
    # Update
    echo "\n#\tUpdating Nominatim software"
    cd Nominatim
    sudo -u ${username} git pull
    # Some of the schema is created by osm2pgsql which is updated by:
    sudo -u ${username} git submodule update --init
fi

# Compile Nominatim software
echo "\n#\tCompiling Nominatim software"
sudo -u ${username} ./autogen.sh
sudo -u ${username} ./configure
sudo -u ${username} make


# Get Wikipedia data which helps with name importance hinting
echo "\n#\tWikipedia data"
# These large files are optional, and if present take a long time to process by ./utils/setup.php later in the script.
# Download them if they are not already present - the available ones date from early 2012.
if test ! -r data/wikipedia_article.sql.bin; then
    sudo -u ${username} wget --output-document=data/wikipedia_article.sql.bin http://www.nominatim.org/data/wikipedia_article.sql.bin
fi
if test ! -r data/wikipedia_redirect.sql.bin; then
    sudo -u ${username} wget --output-document=data/wikipedia_redirect.sql.bin http://www.nominatim.org/data/wikipedia_redirect.sql.bin
fi

# Add UK postcode support (centroids only, not house number level)
if test ! -r data/gb_postcode_data.sql.gz; then
    sudo -u ${username} wget --output-document=data/gb_postcode_data.sql.gz http://www.nominatim.org/data/gb_postcode_data.sql.gz
fi

# http://stackoverflow.com/questions/8546759/how-to-check-if-a-postgres-user-exists
# Creating the importer account in Postgres
echo "\n#\tCreating the importer account"
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${username}'" | grep -q 1 || sudo -u postgres createuser -s $username

# Create website user in Postgres
echo "\n#\tCreating website user"
websiteUser=www-data
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${websiteUser}'" | grep -q 1 || sudo -u postgres createuser -SDR ${websiteUser}

# Nominatim module reading permissions
echo "\n#\tNominatim module reading permissions"
chmod +x "/home/${username}"
chmod +x "/home/${username}/Nominatim"
chmod +x "/home/${username}/Nominatim/module"

# Ensure download folder exists
sudo -u ${username} mkdir -p data/${osmdatafolder}

# Download OSM data if not already present
if test ! -r ${osmdatapath}; then
	echo "\n#\tDownload OSM data"
	sudo -u ${username} wget --output-document=${osmdatapath} ${osmdataurl}
	
	# Verify with an MD5 match
	sudo -u ${username} wget --output-document=${osmdatapath}.md5 ${osmdataurl}.md5
	if [ "$(md5sum ${osmdatapath} | awk '{print $1;}')" != "$(cat ${osmdatapath}.md5 | awk '{print $1;}')" ]; then
		echo "#\tThe md5 checksum for osmdatapath: ${osmdatapath} does not match, stopping."
		exit 1
		echo "\n#\tDownloaded OSM data integrity verified by md5 check."
	fi
fi


#idempotent
# Cannot make idempotent safely from here because that would require editing nominatim's setup scripts.
# Remove any pre-existing nominatim database
echo "\n#\tRemove any pre-existing nominatim database"
sudo -u postgres psql postgres -c "DROP DATABASE IF EXISTS nominatim"

# Add local Nominatim settings
localNominatimSettings=/home/${username}/Nominatim/settings/local.php

cat > ${localNominatimSettings} << EOF
<?php
   // Paths
   @define('CONST_Postgresql_Version', '9.3');
   @define('CONST_Postgis_Version', '2.1');
   // Website settings
   @define('CONST_Website_BaseURL', 'http://${websiteurl}/');
EOF

# By default, Nominatim is configured to update using the global minutely diffs
if [ -z "${planetUrl}" ]; then

    # When using GeoFabrik extracts append these lines to set up the update process
    cat >> ${localNominatimSettings} << EOF
   // Setting up the update process
   @define('CONST_Replication_Url', '${osmupdates}');
   @define('CONST_Replication_MaxInterval', '86400');     // Process each update separately, osmosis cannot merge multiple updates
   @define('CONST_Replication_Update_Interval', '86400');  // How often upstream publishes diffs
   @define('CONST_Replication_Recheck_Interval', '900');   // How long to sleep if no update found yet
EOF
fi

# Change settings file to Nominatim ownership
chown ${username}:${username} ${localNominatimSettings}

# Import and index main OSM data
eval cd /home/${username}/Nominatim/
echo "#\tStarting import and index OSM data $(date)"
# Experimentally trying with two threads here
sudo -u ${username} ./utils/setup.php ${osm2pgsqlcache} --osm-file /home/${username}/Nominatim/${osmdatapath} --all --threads 2
# Note: if that step gets interrupted for some reason it can be resumed using:
# (Threads argument is optional, it'll default to one less than number of available cpus.)
# If the reported rank is 26 or higher, you can also safely add --index-noanalyse.
# sudo -u ${username} ./utils/setup.php --index --index-noanalyse --create-search-indices --threads 2
echo "#\tDone Import and index OSM data $(date)"

# Add special phrases
echo "#\tStarting special phrases $(date)"
sudo -u ${username} ./utils/specialphrases.php --countries > specialphrases_countries.sql
sudo -u ${username} psql -d nominatim -f specialphrases_countries.sql
sudo -u ${username} rm -f specialphrases_countries.sql
sudo -u ${username} ./utils/specialphrases.php --wiki-import > specialphrases.sql
sudo -u ${username} psql -d nominatim -f specialphrases.sql
sudo -u ${username} rm -f specialphrases.sql
echo "#\tDone special phrases $(date)"

# Set up the website for use with Apache
wwwNominatim=/var/www/nominatim
sudo mkdir -pm 755 ${wwwNominatim}
sudo chown ${username} ${wwwNominatim}
sudo -u ${username} ./utils/setup.php --create-website ${wwwNominatim}

# Write out a robots file to keep search engines out
sudo -u ${username} cat > ${wwwNominatim}/robots.txt <<EOF
User-agent: *
Disallow: /
EOF

# Create a VirtualHost for Apache
echo "\n#\tCreate a VirtualHost for Apache"
cat > /etc/apache2/sites-available/${nominatimVHfile} << EOF
<VirtualHost *:80>
        ServerName ${websiteurl}
        ServerAdmin ${emailcontact}
        DocumentRoot ${wwwNominatim}
        CustomLog \${APACHE_LOG_DIR}/access.log combined
        ErrorLog \${APACHE_LOG_DIR}/error.log
        LogLevel warn
        <Directory ${wwwNominatim}>
                Options FollowSymLinks MultiViews
                AllowOverride None
                Require all granted
        </Directory>
        AddType text/html .php
</VirtualHost>
EOF

# Enable the VirtualHost and restart Apache
a2ensite ${nominatimVHfile}
# skip if doing a Docker install
if [ -z "${dockerInstall}" ]; then
    service apache2 reload
fi

echo "#\tNominatim website created $(date)"

# Setting up the update process
rm -f /home/${username}/Nominatim/settings/configuration.txt
sudo -u ${username} ./utils/setup.php --osmosis-init
echo "#\tDone setup $(date)"

# Enabling hierarchical updates
sudo -u ${username} ./utils/setup.php --create-functions --enable-diff-updates
echo "#\tDone enable hierarchical updates $(date)"

# Adust PostgreSQL to do disk writes
echo "\n#\tRetuning PostgreSQL for disk writes"
${nomInstalDir}/configPostgresqlDiskWrites.sh

# Reload postgres assume the new config
echo "\n#\tReloading PostgreSQL"
# skip if doing a Docker install
if [ -z "${dockerInstall}" ]; then
    service postgresql reload
fi

# Updating Nominatim
# Using two threads for the upadate will help performance, by adding this option: --index-instances 2
# Going much beyond two threads is not really worth it because the threads interfere with each other quite a bit.
#  If your system is live and serving queries, keep an eye on response times at busy times, because too many update threads might interfere there, too.
# skip if doing a Docker install
if [ -z "${dockerInstall}" ]; then
    sudo -u ${username} ./utils/update.php --import-osmosis-all --no-npi
fi

# Done
echo "#\tNominatim installation completed $(date)"

# End of file
