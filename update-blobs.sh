#!/usr/bin/env bash

# When you make changes in the packages (or add new ones), please use
# `./update-blobs.sh` to sync and upload the new blobs. This script reads the `spec` file 
# of every package or looks for a `prepare` script (inside the folder of each package):

# * If there is a `packages/<package>/prepare`, it executes it and goes to the next package.
# * If the spec file of a package in `packages/<package>/spec` has a key `files` with this
# format `- folder/src.tgz   # url`, for example:
# ```
# files:
# - ruby-2.3/ruby-2.3.7.tar.gz      # https://cache.ruby-lang.org/pub/ruby/2.3/ruby-2.3.7.tar.gz
# - ruby-2.3/rubygems-2.7.7.tgz     # https://rubygems.org/rubygems/rubygems-2.7.7.tgz
# ```
# It will take the url, download the file to `blobs/ruby-2.3/ruby-2.3.7.tar.gz` and
# it will run `bosh add-blob` with the new src "ruby-2.3.7.tar.gz". Take into
# account the script does not download a package if there is a file with the same
# name in the destination folder, so it the package was not properly downloaded
# (e.g. script execution interrupted), please delete the destination folder and try
# again.
# 
# The idea is make it easy to update the version of the packages. Making a `packaging`
# script flexible, not linked to version, updating a package is just a matter of 
# updating its `spec` file and run `./update-blobs.sh` and you have a new version
# ready!. Extract of a ruby `packaging` script (just and example):
# ```
# # Grab the latest versions that are in the directory
# RUBY_VERSION=`ls -r ruby-2.3/ruby-* | sed 's/ruby-2.3\/ruby-\(.*\)\.tar\.gz/\1/' | head -1`
# RUBYGEMS_VERSION=`ls -r ruby-2.3/rubygems-* | sed 's/ruby-2.3\/rubygems-\(.*\)\.tgz/\1/' | head -1`
# 
# echo "Extracting ruby-${RUBY_VERSION} ..."
# tar xvf ruby-2.3/ruby-${RUBY_VERSION}.tar.gz
# 
# echo "Building ruby-${RUBY_VERSION} ..."
# pushd ruby-${RUBY_VERSION}
#   LDFLAGS="-Wl,-rpath -Wl,${BOSH_INSTALL_TARGET}" ./configure --prefix=${BOSH_INSTALL_TARGET} --disable-install-doc --with-opt-dir=${BOSH_INSTALL_TARGET}
#   make
#   make install
# popd
# ```
#
# The script does not process any args and it is safe to run as many times as you need
# (take into account if you create `prepare` scrips!).


SHELL=/bin/bash
AWK=awk
BOSH_CLI=${BOSH_CLI:-bosh}
SRC=$(pwd)/blobs
PREPARE_SCRIPT="prepare"


read_spec_2() {
    local spec="${1}"
    $AWK 'BEGIN {
       url_regex="hola"
    }
    /^files:/ {
        while (getline) {
            if ($1 == "-") {
                if ($3 ~ /#/) {
                    comment=$3$4;
                    where=match(comment, /((http|https|ftp):\/)?\/?([^:\/\s]+)((\/\w+)*\/)([\w\-\.]+[^#?\s]+)([#\w\-\?=]+)?/g, url)
                    print comment
                    print where
                    print url[0]
                    print url[1]
                    if (where != 0) {
                      print $2"@"url[0];
                    }
                }
            } else {
                next;
            }
        }
    }' "$spec"
}


read_spec_blobs() {
    local spec="$1"
    $AWK '/^files:/ {
        while (getline) {
            if ($1 == "-") {
                if ($3 ~ /#/) {
                    url=$3$4;
                    sub(/#/, "", url)
                    print $2"@"url;
                }
            } else {
                next;
            }
        }
    }' "$spec"
}


exec_download_blob() {
    local output="${1}"
    local url="${2}"

    local package=$(dirname "${output}")
    local src=$(basename "${output}")
    (
        cd ${SRC}
        if [ ! -s "${output}" ]
        then
            echo "  Downloading ${url} ..."
            mkdir -p "${package}"
            curl -L -s "${url}" -o "${output}"
        fi
    )
}


exec_prepare() {
    local prepare="${1}"
    (
        echo "* Procesing ${prepare} ..."
        cd ${SRC}
        ${SHELL} "${prepare}"
    )
}


exec_download_spec() {
    local spec="${1}"

    local blob
    local downloadfile
    local downloadurl

    echo "* Procesing specs ${spec} ..."
    for blob in $(read_spec_blobs "${spec}")
    do
        downloadfile=$(echo "${blob}" | cut -d'@' -f 1)
        downloadurl=$(echo "${blob}" | cut -d'@' -f 2)
        exec_download_blob "${downloadfile}" "${downloadurl}"
        exec_bosh_add_blob "${downloadfile}"
    done
}


exec_bosh_add_blob() {
    local blob="$1"
    (
        echo "  Adding blob: ${BOSH_CLI} add-blob $SRC/${blob} ${blob}  ..."
        ${BOSH_CLI} add-blob $SRC/${blob} ${blob}
        echo
    )
}


main() {
    for script in $(pwd)/packages/*/spec ; do
        local base=$(dirname "${script}")
        local prepare="${base}/prepare"
        if [ -s "${prepare}" ]; then
            exec_prepare "${prepare}"
        else
            exec_download_spec "${script}"
        fi
    done
}


# Run!
mkdir -p $SRC

echo "* bosh sync-blobs ..."
${BOSH_CLI} sync-blobs
echo
main
echo
echo "* bosh blobs ..."
${BOSH_CLI} blobs
echo
echo "* Uploading blobs to the blobstore ..."
${BOSH_CLI} upload-blobs
