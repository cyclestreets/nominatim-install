############################################################
# Dockerfile to build nominatim
############################################################

# Set the base image to Ubuntu
FROM ubuntu:14.04

# File Author / Maintainer
MAINTAINER Melvin Zhang

# Set locale
RUN locale-gen en_US.UTF-8
RUN update-locale LANG=en_US.UTF-8

ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update

# Install dependencies
RUN apt-get -y install sudo wget

# Note: libgeos++-dev is included here too (the nominatim install page suggests installing it if there is a problem with the 'pear install DB' below - it seems safe to install it anyway)
RUN apt-get -y install build-essential libxml2-dev libgeos-dev libpq-dev libbz2-dev libtool automake libproj-dev libgeos++-dev
RUN apt-get -y install gcc proj-bin libgeos-c1 git osmosis
RUN apt-get -y install php5 php-pear php5-pgsql php5-json

# Some additional packages that may not already be installed
# bc is needed in configPostgresql.sh
RUN apt-get -y install bc 

# Install Postgres, PostGIS and dependencies
RUN apt-get -y install postgresql postgis postgresql-contrib postgresql-9.3-postgis-2.1 postgresql-server-dev-9.3

# Install Apache
RUN apt-get -y install apache2

# Install gdal - which is apparently used for US data (more steps need to be added to this script to support that US data)
RUN apt-get -y install python-gdal

# Add Protobuf support
RUN apt-get -y install libprotobuf-c0-dev protobuf-c-compiler

# Copy the application folder inside the container
ADD . /nominatim

RUN cd /nominatim; ./docker-install.sh

# Set the default directory where CMD will execute
WORKDIR /nominatim

# Set the default command to execute
CMD /bin/sh docker-start.sh
