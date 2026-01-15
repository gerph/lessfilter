# `.lessfilter` for a variety of formats

## System

This repository holds a snapshot of my local `.lessfilter` and support files.
The filter is usable on macOS and Linux systems, together with the `lesspipe` system.
It provides decoding and colouring of many common files that I deal with - largely network management files and RISC OS files. It will degrade to plain output if you do not have the relevant tools to perform decoding.


## Installation

The `lessfilter` is intended to be used with the `lesspipe` tool. This can be installed
on Debian and Ubuntu systems with:

* `apt-get install less`

On other systems (eg macOS), or if you need a local copy of the `lesspipe` tool, copy `lesspipe.sh` into your library. This was not written by me (I made small changes for macOS) - its authorship is in the file.

Once the `lesspipe` system is intalled, it must be configured to be used by adding the contents of `bashd-less-filter.sh` to your `.bashrc` (or similar) files.

Finally, copy the `lessfilter.sh` as `~/.lessfilter`. This is the workhorse tool that will reformat and colour files.

You may also wish to place the `junitxml.py` tool in your path as `junitxml`. This will summarise JUnix XML files commonly used for test results.

## Usage

Use `less` like normal, and the `.lessfilter` will be run to perform formatting.

We use a number of tools to try to convert the files requested into a form which is
coloured:

* `pygments` - for many file formats
    * `pygments-git` - adds formatting for some Git files.
* `jq` - for JSON
* `csvkit` - for CSV
* `grc` - for dot

A few tools are used to convert binary files to textual format:

* `xmllint` - for XML
* `bastotxt` or `riscos-basicdetokenise` - for tokenised BBC BASIC
* `armdiss` or `riscos-dumpi` - for ARM binaries
* `riscos-dump` - for data files binaries
* `riscos-decaof` - for AOF files
* `riscos-libfile` - for ALF files
* `objdump`, `riscos64-objdump`, `aarch64-unknown-linux-gnu-objdump` - for ELF files
* `ar`, `riscos64-libfile`, `aarch64-unknown-linux-gnu-ar` - for ar archives
* `otool` - for MachO files
* `openssl` - for certificates and keys
* `plutil` - for plist files
* `python` - for decoding Python bytecode
* `unzip` - for decoding archives
* `riscos-unzip` - for decoding archives with RISC OS types in
* `nspark` - for decoding RISC OS archives (Spark, ArcFS and Squash)
* `decdrawf` - for decoding RISC OS Drawfiles.


## Manual usage

To manually invoke the filter (for testing and development, largely), use the command directly:

* `~/.lessfilter <file>` - produces an ANSI/VT formatted output for the file.
* `~/.lessfilter --supports <file>` - returns 0 if supported, 1 if not supported

The `pygments` processing is cached between runs to speed up the recognition of file
formats. This caching may mean that additional pygments packages won't get picked up
by this file. If this is the case, remove the `~/.cache/lessfilter/*` files and the
next run will cache files.
