FROM redis:6.2.3-buster

# change context to root
USER root

WORKDIR /src

# Install JQ module - to parse config.json
RUN apt update && apt-get install -y jq

# Copy the content of source folder to docker
COPY ./src .

#Leave it open and issue the run command in stateful set
