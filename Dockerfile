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

# Update apt
ENV DEBIAN_FRONTEND noninteractive
RUN apt-get update

# Copy the application folder inside the container
ADD . /nominatim

RUN cd /nominatim; ./run.sh

# Set the default directory where CMD will execute
WORKDIR /nominatim

# Set the default command to execute
CMD /bin/sh docker-start.sh
