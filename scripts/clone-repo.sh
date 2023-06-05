#!/bin/sh

SRC="$1"
DST="$2"

DST_GIT_DIR="$2/.git"

if [ ! -d $DST_GIT_DIR ]
then
    git clone $SRC
else
    cd $DST
    git pull $SRC
fi
