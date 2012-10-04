#!/bin/sh

# Script to install Nominatim on Ubuntu
# Tested on 12.04 (View Ubuntu version using 'lsb_release -a') using Postgres 9.1
# http://wiki.openstreetmap.org/wiki/Nominatim/Installation#Ubuntu.2FDebian


### SETTINGS ###

# Define the username for Nominatim to install/run under, so that it can run independent of any individual personal account on the machine
username=nominatim

# Define the location of the .pdf OSM data file
osmdataurl=http://download.geofabrik.de/openstreetmap/europe/great_britain.osm.pbf
osmdatafilename=great_britain.osm.pbf

# Define the website hostname and e-mail for the VirtualHost
websiteurl=nominatim.cyclestreets.net
emailcontact=webmaster@cyclestreets.net



### MAIN PROGRAM ###

# Ensure this script is run as root
if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root" 1>&2
	exit 1
fi

# Request a password for the Nominatim user account; see http://stackoverflow.com/questions/3980668/how-to-get-a-password-from-a-shell-script-without-echoing
stty -echo
printf "Please enter a password that will be used to create the Nominatim user account:"
read password
printf "\n"
printf "Confirm that password:"
read passwordconfirm
printf "\n"
stty echo
if [ $password != $passwordconfirm ]; then
	echo "The passwords did not match"
	exit 1
fi

# Create the Nominatim user
useradd -m -p $password $username
echo "Nominatim user ${username} created"

# Install basic software
apt-get -y install wget git

# Install Apache, PHP
apt-get -y install apache2 php5

# Install Postgres, PostGIS and dependencies
apt-get -y install php5-pgsql postgis postgresql php5 php-pear gcc proj libgeos-c1 postgresql-contrib git osmosis
apt-get -y install postgresql-9.1-postgis postgresql-server-dev-9.1
apt-get -y install build-essential libxml2-dev libgeos-dev libpq-dev libbz2-dev libtool automake libproj-dev

# Add Protobuf support
apt-get -y install libprotobuf-c0-dev protobuf-c-compiler

# PHP Pear::DB is needed for the runtime website
pear install DB

# We will use the Nominatim user's homedir for the installation, so switch to that
eval cd ~${username}

# Nominatim software
git clone --recursive git://github.com/twain47/Nominatim.git
cd Nominatim
./autogen.sh
./configure --enable-64bit-ids
make

# Get Wikipedia data which helps with name importance hinting
wget --output-document=data/wikipedia_article.sql.bin http://www.nominatim.org/data/wikipedia_article.sql.bin
wget --output-document=data/wikipedia_redirect.sql.bin http://www.nominatim.org/data/wikipedia_redirect.sql.bin

# Creating the importer account in Postgres
sudo -u postgres createuser -s $username

# Create website user in Postgres
sudo -u postgres createuser -SDR www-data

# Nominatim module reading permissions
chmod +x "/home/${username}"
chmod +x "/home/${username}/Nominatim"
chmod +x "/home/${username}/Nominatim/module"

# Download OSM data
wget $osmdataurl

# Import and index main OSM data
cd /home/${username}/Nominatim/
sudo -u ${username} ./utils/setup.php --osm-file /home/${username}/Nominatim/$osmdatafilename --all

# Add special phrases
sudo -u ${username} ./utils/specialphrases.php --countries > specialphrases_countries.sql
sudo -u ${username} psql -d nominatim -f specialphrases_countries.sql
sudo -u ${username} rm specialphrases_countries.sql
sudo -u ${username} ./utils/specialphrases.php --wiki-import > specialphrases.sql
sudo -u ${username} psql -d nominatim -f specialphrases.sql
sudo -u ${username} rm specialphrases.sql

# Set up the website for use with Apache
sudo mkdir -m 755 /var/www/nominatim
sudo chown ${username} /var/www/nominatim
sudo -u ${username} ./utils/setup.php --create-website /var/www/nominatim

# Create a VirtalHost for Apache
cat > /etc/apache2/sites-available/nominatim << EOF
<VirtualHost *:80>
        ServerName ${websiteurl}
        ServerAdmin ${emailcontact}
        DocumentRoot /var/www/nominatim
        CustomLog \${APACHE_LOG_DIR}/access.log combined
        ErrorLog \${APACHE_LOG_DIR}/error.log
        LogLevel warn
        <Directory /var/www/nominatim>
                Options FollowSymLinks MultiViews
                AllowOverride None
                Order allow,deny
                Allow from all
        </Directory>
        AddType text/html .php
</VirtualHost>
EOF

# Add local Nominatim settings
cat > /home/nominatim/Nominatim/settings/local.php << EOF
<?php
   // Paths
   @define('CONST_Postgresql_Version', '9.1');
   // Website settings
   @define('CONST_Website_BaseURL', 'http://${websiteurl}/');
EOF

# Enable the VirtualHost and restart Apache
a2ensite nominatim
service apache2 reload

