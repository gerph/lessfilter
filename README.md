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

Once the `lesspipe` system is installed, it must be configured to be used by adding the contents of `bashd-less-filter.sh` to your `.bashrc` (or similar) files.

Finally, copy the `lessfilter.sh` as `~/.lessfilter`. This is the workhorse tool that will reformat and colour files.

You may also wish to place the `junitxml.py` tool in your path as `junitxml`. This will summarise JUnit XML files commonly used for test results.

The `magic` directory contains optional definitions for the `file` tool. Installing
these definitions in your system's magic database allows tokenised and textual BBC
BASIC programs to be recognised by their contents when they do not have RISC OS
filetype suffixes. The definitions can be tested without installing them with:

```
file -m magic/bbcbasic:magic/bbcbasictext <file>
```

## Usage

Use `less` like normal, and the `.lessfilter` will be run to perform formatting.

We use a number of tools to try to convert the files requested into a form which is
coloured:

* `pygments` - for many file formats
    * `pygments-git` - adds formatting for some Git files.
* `jq` - for JSON
* `csvkit` - for CSV
* `grc` - for dot
* `nano-colour` - for formats supported by installed Nano syntax definitions

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
* `unzip` - for decoding Zip archives
* `riscos-unzip` - for decoding archives with RISC OS types
* `nspark` - for decoding RISC OS archives (Spark, ArcFS and Squash)
* `riscos-tbafs` - for listing TBAFS files
* `riscos-shextract` - for listing StrongHelp files
* `decdrawf` - for decoding RISC OS Drawfiles
* `riscos-dumpsprites` - for decoding RISC OS sprites
* `ccres` or `riscos-ccres` - for decoding RISC OS templates and Toolbox resources

A few standard tools are used to help identify and post-process files:

* `perl`
* `sed`
* `grep`
* `file`, optionally with the BBC BASIC definitions supplied in `magic`

## Manual usage

To manually invoke the filter (for testing and development, largely), use the command directly:

* `~/.lessfilter <file>` - produces an ANSI/VT formatted output for the file.
* `~/.lessfilter --supports <file>` - returns 0 if supported, 1 if not supported

The `pygments` processing is cached between runs to speed up the recognition of file
formats. This caching may mean that additional pygments packages won't get picked up
by this file. If this is the case, remove the `~/.cache/lessfilter/*` files and the
next run will cache files.
