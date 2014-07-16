Bash script to install Nominatim on Ubuntu

Tested on 14.04 using Postgres 9.3

http://wiki.openstreetmap.org/wiki/Nominatim/Installation

After the repository has been cloned from github, proceed by making your own *.config.sh* file based on the *.config.sh.template* file.

Running the installation script *run.sh* (as *root*) will:

 * create a *nominatim* user
 * download all the necessary packages
 * download the planet extract as defined by the *.config.sh* file
 * build the Nominatim index
 * create a virtual host

The *root* user is required to install the packages, but most of the installation is done as the *nominatim* user (using *sudo*).
