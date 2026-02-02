#!/bin/bash

docker run --rm -v ./out:/mnt -t $(docker build -q .)
