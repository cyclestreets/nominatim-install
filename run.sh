#!/bin/sh
# Script to install Nominatim on Ubuntu
# Tested on 12.04 (View Ubuntu version using 'lsb_release -a') using Postgres 9.1
# http://wiki.openstreetmap.org/wiki/Nominatim/Installation#Ubuntu.2FDebian
# Synced with: Latest revision as of 08:51, 15 November 2013

# !! Marker #idempotent indicates limit of testing for idempotency - it has not yet been possible to make it fully idempotent.

echo "#\tNominatim installation $(date)"

# Ensure this script is run as root
if [ "$(id -u)" != "0" ]; then
    echo "#\tThis script must be run as root." 1>&2
    exit 1
fi

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

# Logging
# Use an absolute path for the log file to be tolerant of the changing working directory in this script
setupLogFile=$(readlink -e $(dirname $0))/setupLog.txt
touch ${setupLogFile}
chmod a+w ${setupLogFile}
echo "#\tImport and index OSM data in progress, follow log file with:\n#\ttail -f ${setupLogFile}"
echo "#\tNominatim installation $(date)" >> ${setupLogFile}

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
    echo "#\tNominatim user ${username} created" >> ${setupLogFile}
fi

# Prepare the apt index; it may be practically non-existent on a fresh VM
apt-get update > /dev/null

# Install basic software
apt-get -y install wget >> ${setupLogFile}


# Install software
echo "\n#\tInstalling software packages" >> ${setupLogFile}
# Note: libgeos++-dev is included here too (the nominatim install page suggests installing it if there is a problem with the 'pear install DB' below - it seems safe to install it anyway)
apt-get -y install build-essential libxml2-dev libgeos-dev libpq-dev libbz2-dev libtool automake libproj-dev libgeos++-dev >> ${setupLogFile}
apt-get -y install gcc proj-bin libgeos-c1 git osmosis >> ${setupLogFile}
apt-get -y install php5 php-pear php5-pgsql php5-json >> ${setupLogFile}

# Install Postgres, PostGIS and dependencies
echo "\n#\tInstalling postgres and link to postgis" >> ${setupLogFile}
apt-get -y install postgresql postgis postgresql-contrib postgresql-9.1-postgis postgresql-server-dev-9.1 >> ${setupLogFile}

# Install Apache
echo "\n#\tInstalling Apache" >> ${setupLogFile}
apt-get -y install apache2 >> ${setupLogFile}

# Install gdal - which is apparently used for US data (more steps need to be added to this script to support that US data)
echo "\n#\tInstalling gdal" >> ${setupLogFile}
apt-get -y install python-gdal >> ${setupLogFile}

# Add Protobuf support
echo "\n#\tInstalling protobuf" >> ${setupLogFile}
apt-get -y install libprotobuf-c0-dev protobuf-c-compiler >> ${setupLogFile}

# Temporarily allow commands to fail without exiting the script
set +e

# PHP Pear::DB is needed for the runtime website
# There doesn't seem an easy way to avoid this failing if it is already installed.
echo "\n#\tInstalling pear DB" >> ${setupLogFile}
pear install DB >> ${setupLogFile}

# Bomb out if something goes wrong
set -e

# Tuning PostgreSQL
echo "\n#\tTuning PostgreSQL" >> ${setupLogFile}
./configPostgresql.sh ${postgresconfigmode} n ${override_maintenance_work_mem}

# Restart postgres assume the new config
echo "\n#\tRestarting PostgreSQL" >> ${setupLogFile}
service postgresql restart

# We will use the Nominatim user's homedir for the installation, so switch to that
eval cd /home/${username}

# Get Nominatim software
if [ ! -d "/home/${username}/Nominatim/.git" ]; then
    # Install
    echo "\n#\tInstalling Nominatim software" >> ${setupLogFile}
    sudo -u ${username} git clone --recursive git://github.com/twain47/Nominatim.git >> ${setupLogFile}
    cd Nominatim
else
    # Update
    echo "\n#\tUpdating Nominatim software" >> ${setupLogFile}
    cd Nominatim
    sudo -u ${username} git pull >> ${setupLogFile}
    # Some of the schema is created by osm2pgsql which is updated by:
    sudo -u ${username} git submodule update --init >> ${setupLogFile}
fi

# Compile Nominatim software
echo "\n#\tCompiling Nominatim software" >> ${setupLogFile}
sudo -u ${username} ./autogen.sh >> ${setupLogFile}
sudo -u ${username} ./configure >> ${setupLogFile}
sudo -u ${username} make >> ${setupLogFile}


# Get Wikipedia data which helps with name importance hinting
echo "\n#\tWikipedia data" >> ${setupLogFile}
# These large files are optional, and if present take a long time to process by ./utils/setup.php later in the script.
# Download them if they are not already present - the available ones date from early 2012.
if test ! -r data/wikipedia_article.sql.bin; then
    sudo -u ${username} wget --output-document=data/wikipedia_article.sql.bin http://www.nominatim.org/data/wikipedia_article.sql.bin
fi
if test ! -r data/wikipedia_redirect.sql.bin; then
    sudo -u ${username} wget --output-document=data/wikipedia_redirect.sql.bin http://www.nominatim.org/data/wikipedia_redirect.sql.bin
fi

# http://stackoverflow.com/questions/8546759/how-to-check-if-a-postgres-user-exists
# Creating the importer account in Postgres
echo "\n#\tCreating the importer account" >> ${setupLogFile}
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${username}'" | grep -q 1 || sudo -u postgres createuser -s $username

# Create website user in Postgres
echo "\n#\tCreating website user" >> ${setupLogFile}
websiteUser=www-data
sudo -u postgres psql postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='${websiteUser}'" | grep -q 1 || sudo -u postgres createuser -SDR ${websiteUser}

# Nominatim module reading permissions
echo "\n#\tNominatim module reading permissions" >> ${setupLogFile}
chmod +x "/home/${username}"
chmod +x "/home/${username}/Nominatim"
chmod +x "/home/${username}/Nominatim/module"

# Ensure download folder exists
sudo -u ${username} mkdir -p data/${osmdatafolder}

# Download OSM data (if more than a day old)
if test ! -r ${osmdatapath} || ! test `find ${osmdatapath} -mtime -1`; then
    echo "\n#\tDownload OSM data" >> ${setupLogFile}
    sudo -u ${username} wget --output-document=${osmdatapath}.md5 ${osmdataurl}.md5
    sudo -u ${username} wget --output-document=${osmdatapath} ${osmdataurl}
fi

#idempotent
# Cannot make idempotent safely from here because that would require editing nominatim's setup scripts.
# Remove any pre-existing nominatim database
echo "\n#\tRemove any pre-existing nominatim database" >> ${setupLogFile}
sudo -u postgres psql postgres -c "DROP DATABASE IF EXISTS nominatim"

# Add local Nominatim settings
localNominatimSettings=/home/${username}/Nominatim/settings/local.php

cat > ${localNominatimSettings} << EOF
<?php
   // Paths
   @define('CONST_Postgresql_Version', '9.1');
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
echo "#\tStarting import and index OSM data $(date)" >> ${setupLogFile}
sudo -u ${username} ./utils/setup.php ${osm2pgsqlcache} --osm-file /home/${username}/Nominatim/${osmdatapath} --all >> ${setupLogFile}
# Note: if that step gets interrupted for some reason it can be resumed using:
# (Threads argument is optional, it'll default to one less than number of available cpus.)
# If the reported rank is 26 or higher, you can also safely add --index-noanalyse.
# sudo -u ${username} ./utils/setup.php --index --index-noanalyse --create-search-indices --threads 2
echo "#\tDone Import and index OSM data $(date)" >> ${setupLogFile}

# Add special phrases
echo "#\tStarting special phrases $(date)" >> ${setupLogFile}
sudo -u ${username} ./utils/specialphrases.php --countries > specialphrases_countries.sql >> ${setupLogFile}
sudo -u ${username} psql -d nominatim -f specialphrases_countries.sql >> ${setupLogFile}
sudo -u ${username} rm -f specialphrases_countries.sql
sudo -u ${username} ./utils/specialphrases.php --wiki-import > specialphrases.sql >> ${setupLogFile}
sudo -u ${username} psql -d nominatim -f specialphrases.sql >> ${setupLogFile}
sudo -u ${username} rm -f specialphrases.sql
echo "#\tDone special phrases $(date)" >> ${setupLogFile}

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
echo "\n#\tCreate a VirtualHost for Apache" >> ${setupLogFile}
cat > /etc/apache2/sites-available/${nominatimVHfile}.conf << EOF
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
                Order allow,deny
                Allow from all
        </Directory>
        AddType text/html .php
</VirtualHost>
EOF

# Enable the VirtualHost and restart Apache
a2ensite ${nominatimVHfile}
service apache2 reload

echo "#\tNominatim website created $(date)" >> ${setupLogFile}

# Setting up the update process
sudo -u ${username} ./utils/setup.php --osmosis-init
echo "#\tDone setup $(date)" >> ${setupLogFile}

# Enabling hierarchical updates
sudo -u ${username} ./utils/setup.php --create-functions --enable-diff-updates
echo "#\tDone enable hierarchical updates $(date)" >> ${setupLogFile}

# Updating Nominatim
sudo -u ${username} ./utils/update.php --import-osmosis-all --no-npi

# Done
echo "#\tNominatim installation completed $(date)" >> ${setupLogFile}

# End of file
