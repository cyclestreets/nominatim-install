Bash script to install Nominatim on Ubuntu

Tested on 12.04 using Postgres 9.1

http://wiki.openstreetmap.org/wiki/Nominatim/Installation

After the repository has been cloned from github, proceed by making your own *.config.sh* file based on the *.config.sh.template* file.

Running the installation script *run.sh* (as *root*) will:

 * create a *nominatim* user
 * download all the necessary packages
 * download the planet extract as defined by the *.config.sh* file
 * build the Nominatim index
 * create a virtual host

The *root* user is required to install the packages, but most of the installation is done as the *nominatim* user (using *sudo*).


## Setup

Add this repository to a machine using the following, as your normal username (not root). In the listing the grouped items can usually be cut and pasted together into the command shell, others require responding to a prompt:

    cd ~
    sudo apt-get -y install git

    # Optionally configure git
    # git config --global user.name "Your git username"
    # git config --global user.email "Your git email"

    git clone https://github.com/cyclestreets/nominatim-install.git

    sudo mv nominatim-install /opt
    cd /opt/nominatim-install/
    git config core.sharedRepository group
