#!/bin/bash
##
# Filter for 'less' to convert input which is understood to be able to output coloured content.
#
# We use a number of tools to try to convert the files requested into a form which is
# coloured:
#   * pygments - for many file formats
#       * pygments-git - adds formatting for some Git files.
#   * jq - for JSON
#   * csvkit - for CSV
#   * grc - for dot
#
# A few tools are used to convert binary files to textual format:
#
#   * xmllint - for XML
#   * bastotxt or riscos-basicdetokenise - for tokenised BBC BASIC
#   * armdiss or riscos-dumpi - for ARM binaries
#   * riscos-dump - for data files binaries
#   * riscos-decaof - for AOF files
#   * riscos-libfile - for ALF files
#   * objdump, riscos64-objdump, aarch64-unknown-linux-gnu-objdump - for ELF files
#   * ar, riscos64-libfile, aarch64-unknown-linux-gnu-ar - for ar archives
#   * otool - for MachO files
#   * openssl - for certificates and keys
#   * plutil - for plist files
#   * python - for decoding python bytecode
#
# Usage:
#   .lessfilter <file>
#       - produces an ANSI/VT formatted output for the file.
#   .lessfilter --supports <file>
#       - returns 0 if supported, 1 if not supported
#
# The pygments processing is cached between runs to speed up the recognition of file
# formats. This caching may mean that additional pygments packages won't get picked up
# by this file. If this is the case, remove the ~/.cache/lessfilter/* files and the
# next run will cache files.
#
# This file is licensed under MIT license.
#

check_supported=false
if [[ "$1" == '--supports' ]] ; then
    check_supported=true
    shift
fi

# The file we're going to process
file="$1"

if [[ "$file" == '' ]] ; then
    echo "No filename supplied"
    echo "Syntax: $0 [--supports] <filename>"
    exit 0
fi

# Configuration
pygmentize_style='rrt'

# Format for output; 'terminal' is the default, but we might change for some formats
pygmentize_format='terminal'
if [[ "$TERM" =~ 256 ]] ; then
    # Should handle xterm-256color and screen's 256 colour terminal settings
    pygmentize_format='terminal256'
fi

# Whether we have reformatted yet
reformatted=false

# The system, so that we can vary bahaviour for non-Linux systems
sysname=$(uname -s)

# Our temporary directory
tmpdir="$(mktemp -d -t lessfilter.XXXXXXXX 2> /dev/null)"
if [[ "${tmpdir}" == '' ]] ; then
    echo "Cannot create temporary directory. That would be bad." >&2
    exit 1
fi
function cleanup() {
    if [[ "$sysname" == 'Darwin' ]] ; then
        # On OSX, '--one-file-system' does not exist.
        rm -rf "${tmpdir}"
    else
        rm -rf --one-file-system "${tmpdir}"
    fi
}
trap cleanup EXIT

# Where we cache things
cachedir="${XDG_CACHE_HOME:-$HOME/.cache}/lessfilter"


##
# Accept this file for processing
function accept_file() {
    if $check_supported ; then
        exit 0
    fi
}


##
# Accept this file for processing
function accept_format() {
    if $check_supported ; then
        exit 0
    fi
    reformatted=true
}


function sed_inplace() {
    if [[ "$sysname" == 'Darwin' ]] ; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

realpath_counter=0
##
# Normalise the path, removing any symbolic links, etc.
#
# Implemented here as a long-winded manual process to evaluate the paths
# so that we avoid any limitations of the system that we are installed
# on.
function realpath() {
    local path="$1"
    local OLDIFS
    local pathaccumulator
    local leadingpath
    local link

    realpath_counter=$((realpath_counter+1))
    if [[ "${realpath_counter}" -gt 20 ]] ; then
        echo "Too many iterations in realpath (${realpath_counter}) processing '$path'" >&2
        realpath_counter=$((realpath_counter-1))
        return 1
    fi

    if [[ "${path:0:1}" != '/' ]] ; then
        path="$(pwd -P)/${path}"
    fi

    OLDIFS="$IFS"
    IFS='/'
    for segment in $path ; do
        if [[ "$segment" == '.' ]] ; then
            continue
        elif [[ "$segment" == '..' ]] ; then
            pathaccumulator="${pathaccumulator%/*/*}"
        elif [[ "$segment" != '' ]] ; then
            leadingpath="${pathaccumulator}${segment}"
            link="$(readlink "$leadingpath")"
            if [[ "$link" != "" ]] ; then
                if [[ "${link:0:1}" == '/' ]] ; then
                    pathaccumulator="$(realpath "${link}")"
                else
                    pathaccumulator="$(realpath "${pathaccumulator}${link}")/"
                fi
            else
                pathaccumulator="${leadingpath}"
            fi
        else
            if [[ "$pathaccumulator" == '' ]] ; then
                pathaccumulator="/"
            fi
        fi

        # If the trailing '/' is absent, add one.
        if [[ "${pathaccumulator: -1}" != '/' ]] ; then
            pathaccumulator="${pathaccumulator}/"
        fi
    done
    if [[ "${path: -1}" != '/' && "${pathaccumulator: -1}" == '/' ]] ; then
        pathaccumulator="${pathaccumulator:0: ${#pathaccumulator} - 1}"
    fi
    echo -n "$pathaccumulator"
    realpath_counter=$((realpath_counter-1))
}


##
# Determine the current version of the Pygments tool.
#
# Reads the current version from the cache.
#
# Outputs the verison number on stdout, or empty if we didn't know.
function pygments_version() {
    local cachestat="${cachedir}/pygmentize-stat"
    local cacheversion="${cachedir}/pygmentize-version"
    local pygmentize_stat
    local version
    local cstat

    # Invoking pygmentize even for the version is expensive; so we'll actually
    # check if the script itself has been changed, which should give us a good hint.
    if [[ "$sysname" == 'Darwin' ]] ; then
        pygmentize_stat=$(stat -f '%m' "$(which pygmentize)")
    else
        pygmentize_stat=$(stat --format '%y' "$(which pygmentize)")
    fi
    cstat=$(cat "${cachestat}" 2> /dev/null)
    if [[ "$pygmentize_stat" == "$cstat" && -f "$cacheversion" ]] ; then
        version="$(cat "$cacheversion")"
    else
        version="$(pygmentize -V 2> /dev/null | grep -E -o '[0-9][0-9]*(\.[0-9]*){1,}')"
        mkdir -p "$cachedir"
        echo -n "$version" > "${cacheversion}"
        echo -n "$pygmentize_stat" > "${cachestat}"
    fi
    echo -n "$version"
}


##
# Determine the lexer to use with pygments.
#
# Keeps a cache of the results so that we do not have to
# process the output many times.
#
# Outputs the name of the lexer, or empty if none can be determined.
function pygments_lexer() {
    local filename="$1"

    local cachefile="${cachedir}/pygmentize-lexer"
    local epoch=2
    local version
    mkdir -p "$cachedir"

    version=$(pygments_version)
    if [[ "$version" == '' ]] ; then
        # No version was determinable
        return
    fi

    cachefile="${cachefile}-$epoch-$version"

    if [[ ! -f "$cachefile" ]] ; then
        (
            echo '#!/bin/bash'
            echo 'pygmentize_lexer=""'
            echo 'case "$1" in'
            pygmentize -L lexers \
                | perl -n <(cat <<'EOM'
BEGIN {
    %ignore = map { $_ => 1 } (
            '*.txt',
        );
    %special = (
            'git-ignore' => ['.gitignore', '*/.gitignore'],
            'git-attributes' => ['.gitattributes', '*/.gitattributes'],
            'git-commit-edit-msg' => ['COMMIT_EDITMSG', '*/COMMIT_EDITMSG'],
            'git-blame-ignore-revs' => ['.git-blame-ignore-revs', '*/.git-blame-ignore-revs'],
        );
}

chomp;

$name = $1 if /^\* ([a-z0-9+-]+)(, [a-z0-9+-]+)*:$/;


my @patterns = ();
my $comment = $name;
if (/^ *(.*) \(filenames ([^\)]+)\)/) {
    # A type with explicit filenames
    $comment = $1;
    @patterns = split(/, /, $2);
    if ($name =~ /^(.*?)\+[A-Za-z]/) {
        my $basedon = $1;
        @patterns = grep { ! /^\*\.$basedon$/ } @patterns;
    }
    @patterns = grep { ! defined $ignore{$_} } @patterns;
}
elsif (/^ +([^\(\*]*?) *$/ && defined $name) {
    $comment = $1;
    if (defined $special{$name}) {
        @patterns = @{ $special{$name} };
    }
}
if (scalar(@patterns)) {
    print "  " . join("|", @patterns) . ")\n";
    print "    # $comment\n";
    print "    pygmentize_lexer='$name'\n";
    print "    ;;\n"
}
EOM
                )
            echo 'esac'
            echo 'echo -n $pygmentize_lexer'
        ) > "$cachefile"
        chmod +x "$cachefile"
    fi

    "$cachefile" "$filename"
}


##
# Use pygments to colour the output
function colour_pygments() {
    local lexer=''
    local f

    if ! type -p pygmentize > /dev/null ; then
        return
    fi

    # enable pattern list
    shopt -s extglob

    # Determine how to process the file
    for f in "$file" "$infered_extension" ; do
        case "$f" in

            .bashrc|.bash_aliases|.bash_environment)
                lexer='sh'
                ;;

            *.svg)
                lexer='xml'
                ;;

            *.gitconfig)
                lexer='ini'
                ;;

            *.tfvars)
                lexer='ini'
                ;;

            Jenkinsfile|*/Jenkinsfile|*.jenkinsfile)
                lexer='groovy'
                ;;

            Dockerfile|*/Dockerfile|*.dockerfile|*.Dockerfile)
                lexer='docker'
                ;;

            *.pl) # Otherwise .pl is recognised as 'cplint'
                lexer='perl'
                ;;

            *.kts)
                # *.kt is already recognised by pygmentize.
                lexer='kotlin'
                ;;

            c/*|*/c/*|h/*|*/h/*)
                lexer='c'
                ;;

            s/*|*/s/*|hdr/*|*/hdr/*)
                lexer='arm'
                ;;

            p/*|*/p/*|pas/*|*/pas/*|imp/*|*/imp/*)
                lexer='pascal'
                ;;

            f/*|*/f/*|for/*|*/for/*|f77/*|*/f77/*)
                lexer='fortranfixed'
                ;;

            f90/*|*/f90/*)
                lexer='fortran'
                ;;

            *,fe1)
                lexer='make'
                ;;

            *,fd1)
                lexer='bbcbasic'
                ;;
        esac

        if [[ "$lexer" != '' ]] ; then
            break
        fi
    done

    # Not one of our special cases, so let's check the regular pygments
    if [[ "$lexer" == '' ]] ; then
        # If the file ends with a version number, then it'll be assumed to be a groff file,
        # eg `wrapper-2.1.7` would be recognised as groff, when it's probably a shell
        # script (or might be something else). We should just turn off the automatic lexer
        # recognition from the filename to avoid this.
        if [[ ! "$file" =~ [0-9]\.[0-9]$ ]] ; then
            lexer=$(pygments_lexer "$file")
        fi
        if [[ "$lexer" == '' ]] ; then
            # Still don't know it, so let's try the infered extension
            lexer=$(pygments_lexer "$infered_extension")
        fi
    fi

    if [[ "$lexer" != '' ]] ; then
        # Specialise the formatting for certain file types
        case "$lexer" in
            python|sh|ini|c|bbcbasic)
                # The terminal format has next to no colouring at all.
                pygmentize_format=terminal256
                ;;

            markdown|md)
                # For markdown, this looks better
                if [[ "$(pygments_version)" == '2.5.2' ]] ; then
                    # Last Python 2.7 version of Pygments
                    if [[ -f /usr/local/lib/python2.7/dist-packages/pygments/styles/material.py ]] ; then
                        # This material style has been backported
                        pygmentize_style=material
                    else
                        pygmentize_style=monokai
                    fi
                else
                    pygmentize_style=material
                fi
                ;;
        esac

        # Custom options to pass pygmentize (can be empty)
        pygmentize_opts=('-f' "$pygmentize_format" '-O' "style=$pygmentize_style")

        accept_file
        pygmentize "${pygmentize_opts[@]}" -l "$lexer" "$file"
        exit 0
    fi
    return 0
}


##
# Use jq to colour file
function colour_jq() {
    if ! type -p jq > /dev/null ; then
        return
    fi

    case "$file" in

        *.json|*.jsonl)
            accept_file
            jq --color-output . "$file"
            exit 0
            ;;

    esac
}


##
# Use csvkit to colour file
function colour_csvkit() {
    if ! type -p csvformat > /dev/null ; then
        return
    fi

    case "$file" in

        *.csv)
            if ! csvformat -D£ < /dev/null 2> /dev/null >&2 ; then
                # We have CSV format, but we cannot handle UTF-8
                return
            fi

            accept_file
            csvformat -D£ -U 2 "$file" \
                | sed -e $'s/£"\([0-9][0-9.]*\)"/£\\1/g' \
                      -e $'s/"£/\e[0;1;34m"£/g' \
                      -e $'s/£"/\e[0m,\e[1;34m"\e[0;36m/g' \
                      -e $'s/£/\e[0m,\e[33m/g' \
                      -e $'s/"$/\e[1;34m"/' \
                      -e $'s/$/\e[0m/' \
                      -e $'s/^"/\e[1;34m"\e[0;36m/'
            exit 0
            ;;

    esac
}


##
# Use grc to colour file
function colour_grc() {
    if ! type -p grcat > /dev/null ; then
        return
    fi

    case "$file" in

        *.dot|*.gv|*.gv-dot)
            if [[ -f ~/.grc/conf.graphviz ]] ; then
                accept_file
                grcat ~/.grc/conf.graphviz < "$file"
                exit 0
            fi
            ;;

    esac
}



##
# Reformat the file, if we can, using xmllint
function format_junitxml() {
    local format_to_suffix=''
    local format_to=''
    local f

    if ! type -p junitxml > /dev/null ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in


            *.xml)
                if [[ "$(head "$file" | grep '<testsuite') 2> /dev/null" != '' ]] ; then
                    format_to_suffix=".junitxml"
                fi
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        junitxml --show --summarise "$file" > "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using xmllint
function format_xmllint() {
    local format_to_suffix=''
    local format_to=''
    local f

    if ! type -p xmllint > /dev/null ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.svg)
                if xmllint --nonet "$file" > /dev/null 2>&1 ; then
                    format_to_suffix=".svg"
                fi
                ;;

            *.xml)
                if xmllint --nonet "$file" > /dev/null 2>&1 ; then
                    format_to_suffix=".xml"
                fi
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        xmllint --nonet --format "$file" > "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using bastotxt
function format_bastotxt() {
    local format_to_suffix=''
    local format_to=''
    local f
    local tool=''

    if type -p riscos-basicdetokenise > /dev/null ; then
        tool=riscos-basicdetokenise
    elif type -p bastotxt > /dev/null ; then
        tool=bastotxt
    fi

    if [[ "$tool" = '' ]] ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *,ffb)
                format_to_suffix="bbc"
                # If we do not have my BBC Basic lexer, we'll fall back to any 'basic' colouring.
                infered_extension=".bas"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        "$tool" -i "$file" -o "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using riscos-decaof
function format_decaof() {
    local format_to_suffix=''
    local format_to=''
    local f

    if ! type -p riscos-decaof > /dev/null ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.aof)
                format_to_suffix="data"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        # Explicit colouring here:
        #   Title headings  : Green
        #   Hex             : Magenta
        #   Symbols         : Cyan
        #   Area names      : Yellow
        #   Registers       : Red
        riscos-decaof -drmsc "$file" \
            | sed -E -e 's!\r!!' \
                     -e '/^\*\* Symbol Table/,/^\*\*/ s/^([_!A-Za-z][^ ]*)/\x1b[36m\1\x1b[0m/' \
                     -e 's!^\*\* (.*)$!\x1b[32m** \1\x1b[0m!' \
                     -e '/Attributes: Code/,/^\s*$/ s! : (BL|BX|B)(  |[A-Z][A-Z])(  *)([_a-zA-Z][_a-zA-Z0-9\$]*)$! : \1\2\3\x1b[36m\4\x1b[0m!g' \
                     -e '/Attributes: Code/,/^\s*$/ s!^  0x([0-9a-f]{6}):  ([0-9a-f]{8})  (....) : (B|[A-Z]{2,})( {1,})!    \x1b[35m\1\x1b[0m:  \x1b[37m\2\x1b[0m  \3 : \x1b[33m\4\x1b[0m\5!' \
                     -e '/Attributes: Code/,/^\s*$/ s!^  0x([0-9a-f]{6}):  ([0-9a-f]{8})  (....) : (Undefined instruction)!    \x1b[35m\1\x1b[0m:  \x1b[37m\2\x1b[0m  \3 : \x1b[31m\4\x1b[0m!' \
                     -e '/Attributes: Code/,/^\s*$/ s!( ; .*)!\x1b[32m\1\x1b[0m!' \
                     -e '/Attributes: Code/,/^\s*$/ s!([ ,\[{])(r1[0-5]|r[0-9]|lr|pc|sp|[cs]psr_[a-z]*)!\1\x1b[31m\2\x1b[0m!g' \
                     -e '/Attributes: Code/,/^\s*$/ s!(,)(LSL|LSR|ASR|ROR)!\1\x1b[33m\2\x1b[0m!g' \
                     -e 's!(0x[A-Fa-f0-9]{2,8})([^\)a-f0-9]|$)!\x1b[35m\1\x1b[0m\2!g' \
                     -e 's!(^At |\[)([A-Fa-f0-9]{6,8})(:|\])!\1\x1b[35m\2\x1b[0m\3!g' \
                     -e 's!(symbol )([_!A-Za-z][^ ]*)!\1\x1b[36m\2\x1b[0m!g' \
                     -e 's!(area ")([_!A-Za-z][^ ]*)(")!\1\x1b[33m\2\x1b[0m\3!g' \
            > "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using armdiss
function format_armdiss() {
    local format_to_suffix=''
    local format_to=''
    local f

    if ! type -p armdiss > /dev/null ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *,ffa|*,ff8|*,ffc|*,f95|*.arm)
                format_to_suffix="arm"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        armdiss "$file" > "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using riscos-dumpi
function format_armdumpi() {
    local format_to_suffix=''
    local format_to=''
    local f
    local args

    if ! type -p riscos-dumpi > /dev/null ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *,ffa|*,ff8|*,ffc|*,f95|*.arm)
                format_to_suffix="arm"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        if [[ "$TERM" =~ 256 ]] ; then
            args=(--colour-8bit)
        else
            args=(--colour)
        fi
        # We don't need to do any post-processing for instruction colouring.
        # We can just output this file directly.
        riscos-dumpi "${args[@]}" "$file"
        exit 0
    fi
}


##
# Reformat the markdown file to the current width, realigning characters
function format_markdown() {
    local format_to_suffix=''
    local format_to=''
    local f
    local args

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.md)
                format_to_suffix="md"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        # The first perl filter will wrap the text to the number of columns, and attempts
        # to line up general text properly.
        # The first could be 'fold -s -w COLUMNS' except that this doesn't re-wrap short
        # lines.
        # The second perl filter fixes up some of the output which is untidy with indentations
        # in the wrong places.
        perl -ne 'BEGIN { @acc = (); $len = 0; $max='"$(tput cols 2> /dev/null || echo 77)"';
                         sub flush {
                            if (@acc) { print join(" ", @acc) . "\n"; }
                            @acc=(); $len = 0;
                         }
                         $inbackticks = 0;
                         $intable = 0;
                         $infrontmatter = 0;
                         $maybefrontmatter = 1;
                  }
                  chomp;
                  if ($inbackticks)
                  {
                    if (/^\`\`\`$/)
                    { $inbackticks = 0; goto regular_line; }
                    print "$_\n";
                  }
                  elsif (/^\`\`\`/)
                  {
                    $inbackticks = 1;
                    flush();
                    print "$_\n";
                  }
                  elsif ($intable)
                  {
                    if (/^[^\|]/)
                    { $intable = 0; goto regular_line; }
                    print "$_\n";
                  }
                  elsif (/^\| .*\|\s*$/)
                  {
                    $intable = 1;
                    flush();
                    print "$_\n";
                  }
                  elsif ($maybefrontmatter && /^-?[a-z_0-9\.\-]+:/)
                  {
                    $infrontmatter = 1;
                    $maybefrontmatter = 0;
                    flush();
                    goto frontmatter;
                  }
                  elsif (/^---+$/)
                  {
                    $maybefrontmatter = 1;
                    $infrontmatter = 0;
                    flush();
                    print "$_\n";
                  }
                  elsif ($infrontmatter && (/^ *-?[a-z_0-9\.\-]+:/ || /^ +-/))
                  {
                    # Frontmatter is usually key-value pairs using : separation, but can be
                    # full YAML content.
                  frontmatter:
                    if (/^(#|\*|!|\-\-\-)/ || /^\s*$/)
                    {
                        $infrontmatter = 0;
                        goto regular_line;
                    }
                    print "$_\n";
                  }
                  else
                  {
                  regular_line:

                    my $indent = "";
                    if (/^ +|^[\*-]|^#|^\[\^|^ *\d\. / || $_ eq "")
                    {
                      flush();
                      if ($_ eq "") { print "\n"; }
                      if (/^\[\^/)
                      {
                        $indent = "  ";
                      }
                    }

                    @words=split / /;
                    for my $word (@words)
                    {
                      if ($len + 1 + length($word) >= $max)
                          { flush(); $word = "$indent$word"; }
                      $len += 1 + length($word);
                      push @acc, $word;
                    }
                    $maybefrontmatter = 0;
                  }
                  END { flush(); }' "$file" | \
            perl -ne 'BEGIN { $star = undef; $starch = undef; $starindented = 0;
                              $code = undef; $inbackticks = 0; $intable = 0;
                              $infrontmatter = 0; $maybefrontmatter = 1;
                            }
                      if ($inbackticks)
                      { if (/^\`\`\`/)
                        { $inbackticks = 0; }
                        else
                        {
                            s/\e\[[0-9;]*m//g;
                            $_ = "\e[33m$_\e[0m";
                        }
                      }
                      elsif ($intable)
                      {
                        if (/^[^\|]/)
                        { $intable = 0; }
                        s/\|/\e[1;30m|\e[0m/g;
                      }
                      elsif (/^\| .*\|\s*$/)
                      {
                        s/(\| *)([^|]+)/$1\e[36m$2\e[0m/g;
                        s/\|/\e[1;30m|\e[0m/g;
                        $intable = 1;
                      }
                      elsif (/^(#|---+)/)
                      {
                        $starindented = 0;
                        $star = undef;
                        $infrontmatter = 0;
                        if (/^---/)
                        {
                            $maybefrontmatter = 1;
                        }
                      }
                      elsif ($maybefrontmatter && /^-?[a-z_0-9\.\-]+:/)
                      {
                        $infrontmatter = 1;
                        $maybefrontmatter = 0;
                        goto frontmatter;
                      }
                      elsif ($infrontmatter && (/^ *-?[a-z_0-9\.\-]+:/ || /^ +-/))
                      {
                        # Frontmatter is usually key-value pairs using : separation, but can be
                        # full YAML content.
                      frontmatter:
                        if (/^(#|\*|!|\-\-\-)/ || /^\s*$/)
                        {
                            $infrontmatter = 0;
                        }
                        else
                        {
                            s/^( *)(-?[a-z_0-9\.\-]+):(?:( +)(.*))?/$1\e[33m$2\e[0m:$3\e[36m$4\e[0m/;
                        }
                      }
                      elsif (defined $star && /^$star[^$starch]/ && $_ ne "\n")
                        { $_ = "$star  $_"; $starindented = 1; }
                      elsif (defined $star && /^$star[$starch]/ && $starindented)
                        { $_ = "\n$star$_"; $starindented = 0; }
                      elsif ($code && !/^    / && $_ ne "\n")
                        { s/([^ ]+)/\e[33m$1\e[0m/g;
                          $_ = "        $_"; }
                      elsif (/^( *)([\*\-]) /)
                        { $star = $1; $starch=$2; $starindented = 0; }
                      elsif (/^( *)\d\. /)
                        { $star = $1; $starch="1-9"; $starindented = 0; }
                      elsif (/^\`\`\`/)
                        { $inbackticks = 1; }
                      elsif (/^    [^ ]/)
                        { $code = 1; s/^    //;
                          s/([^ ]+)/\e[33m$1\e[0m/g;
                          $_ = "    $_";
                        }
                      else
                        { $star = undef; $code = 0; }
                      # This hyperlink does not work because the pygmentize we apply breaks it.
                      #s!(https?://[a-z0-9-.]+(/[a-z0-9-.%?#]+)*)!\e]8;;$1\e\\$1\e]8;;\e\\!g;

                      # Footnotes
                      s!(\[\^[^\]]+\])!\e[0;35m$1\e[m!g;

                      # Checklist
                      # Also broken by pygmentize
                      #s! (\[[ X]\]) ! \e[0;35m$1\e[m !g;

                      # Simple comments
                      # Cannot use this one either, as pygmentize breaks it
                      #s/(<!--[^>]*-->)/\e[0;32m$1\e[m/g;

                      print' \
            > "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the Python cache files with a disassembly
function format_pyc() {
    local format_to_suffix=''
    local format_to=''
    local realfile
    local f
    local args
    local python=

    if type -p python > /dev/null ; then
        python=python
    elif type -p python3 > /dev/null ; then
        python=python3
    fi
    if [[ "$python" == '' ]] ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.pyc)
                format_to_suffix="pyc"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        # We want to feed the file to Python to decode it.
        realfile=$(realpath "$file")
        python -c '
# Source - https://stackoverflow.com/questions/11141387/given-a-python-pyc-file-is-there-a-tool-that-let-me-view-the-bytecode
# Posted by ВелоКастръ, modified by community. See post "Timeline" for change history
# Retrieved 2025-12-03, License - CC BY-SA 4.0

import platform
import time
import sys
import binascii
import marshal
import dis
import struct


def view_pyc_file(path):
    """Read and display a content of the Python bytecode in a pyc-file."""

    file = open(path, "rb")

    magic = file.read(4)
    timestamp = file.read(4)
    size = None

    if sys.version_info.major == 3 and sys.version_info.minor >= 3:
        size = file.read(4)
        size = struct.unpack("I", size)[0]

    code = marshal.load(file)

    magic = binascii.hexlify(magic).decode("utf-8")
    timestamp = time.asctime(time.localtime(struct.unpack("I", timestamp)[0]))

    print(
        "Python version: {}\nMagic code: {}\nTimestamp: {}\nSize: {}"
        .format(platform.python_version(), magic, timestamp, size or "not known")
    )
    print("-" * 80)

    dis.disassemble(code)

    file.close()


if __name__ == "__main__":
    view_pyc_file(sys.argv[1])' "$realfile" | sed -e "s@${realfile%.pyc}.py@<pysource>@g" \
            > "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using riscos-dump
function format_dump() {
    local format_to_suffix=''
    local format_to=''
    local f
    local args=()

    if ! type -p riscos-dump > /dev/null ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *,ffd)
                format_to_suffix="data"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        riscos-dump "${args[@]}" "$file" > "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using plutil
function format_plist() {
    local format_to_suffix=''
    local format_to=''
    local f
    local args=()

    if ! type -p plutil > /dev/null ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.plist)
                format_to_suffix="plist"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        plutil -p "${args[@]}" "$file" | sed -e 's/\x1b/<ESC>/g' > "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using openssl
function format_openssl() {
    local format_to_suffix=''
    local format_to=''
    local f
    local args=()

    if ! type -p openssl > /dev/null ; then
        return
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.csr)
                format_to_suffix="asc"
                ;;

            *.crt)
                format_to_suffix="crt"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        # Pygmentize doesn't really give us a very nice output for the text form;
        # it recolours all the words individually.
        # So instead of piping to the pygmentize colouring, we'll do it ourselves.
        function transform() {
            if [[ "$format_to_suffix" = 'crt' ]] ; then
                openssl x509 -in "$file" -text
            else
                openssl req -in "$file" -text
            fi
        }
        transform | \
            sed -E -e 's/^( *)(Validity)$/\1\2:/' \
                   -e 's/^( *)([A-Z][A-Z0-9a-z -]*)(: )([0-9A-Za-z\(])/\1\x1b[35m\2\x1b[0m\3\x1b[36m\4/' \
                   -e 's/^( *)([A-Z][A-Z0-9a-z -]*)(: ?)$/\1\x1b[35m\2\x1b[0m\3/' \
                   -e 's/^( *)(\(none\))$/\1\x1b[36m\2/' \
                   -e '/^---*BEGIN.*/,/^---*END.*/ s/^([^-]*)$/\x1b[36m\1/' \
                   -e '/^---*BEGIN.*/,/^---*END.*/ s/^(---*.*)$/\x1b[33m\1/'
        exit 0
    fi
}


##
# Reformat the file, if we can, using objdump
function format_objdump() {
    local format_to_suffix=''
    local format_to=''
    local f
    local args=()
    local tool=
    local native_objdump=
    local aarch64_objdump=

    if type -p objdump > /dev/null ; then
        native_objdump=objdump
    fi
    if type -p riscos64-objdump > /dev/null ; then
        aarch64_objdump=riscos64-objdump
    fi
    if type -p aarch64-unknown-linux-gnu-objdump  > /dev/null ; then
        aarch64_objdump=aarch64-unknown-linux-gnu-objdump
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.elf-arm64)
                if [[ "$aarch64_objdump" != '' ]] ; then
                    tool=$aarch64_objdump
                else
                    if [[ "$sysname" == 'Darwin' ]] ; then
                        # The objdump tool can handle Aarch64 in macOS
                        tool=$native_objdump
                    fi
                fi
                format_to_suffix="objdump"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$tool" == '' ]] ; then
        # We don't know what tool to use, so we give up.
        return
    fi

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        # The Pygments formatting doesn't colour the headings, so we use sed to tidy up
        #   Title headings  : Green
        #   Hex             : Magenta
        #   Symbols         : Cyan
        #   Area names      : Yellow
        #   Registers       : Red
        # MacOS objdump has slightly different syntax from the Linux objdump:
        # * `;` indicates a comment; linux uses `//`
        # * MacOS disassembly looks like:
        #           937c: 62 fc ff 97 bl      0x8504 <count_pad_digits>
        #   Linux looks like:
        #           937c:       97fffc62        bl      8504 <count_pad_digits>
        # * MacOS data sections are the same as code.
        #   Linux data sections look like:
        #           b760:       00000001 00000000 0000000a 00000000     ................

        # Some of these colourings interfere with the Pygments colouring, so actually
        # we'll not bother with pygments at all.
        "${tool}" -r -d -x "${args[@]}" "$file" \
            | expand \
            | sed -E -e 's!\r!!' \
                     -e '/^SYMBOL TABLE:/,/^$/ s!(  F \.[a-zA-Z][a-zA-Z0-9_\.\-]*  *[0-9a-f]{16} )([A-Za-z_][A-Za-z_0-9]*)!\1\x1b[36m\2\x1b[0m!g' \
                     -e '/^SYMBOL TABLE:/,/^$/ s!( \.[a-zA-Z][a-zA-Z0-9_\.\-]*)!\x1b[33m\1\x1b[0m!g' \
                     -e '/^Disassembly of section/,/^[A-Z]/ s!^([0-9a-f]{8,}) <([^>]*)>:!\x1b[35m\1\x1b[0m <\x1b[36m\2\x1b[0m>:!' \
                     -e '/^Disassembly of section/,/^[A-Z]/ s!^( *)([0-9a-f]{1,}):(  *)([0-9a-f]{2} [0-9a-f ]{2} [0-9a-f ]{2} [0-9a-f ]{2}|[0-9a-f ]{8})  ([^a-z.]{1,})([a-z.]{1,})!\1\x1b[35m\2\x1b[0m:\3\x1b[37m\4\x1b[0m\5\x1b[33m\6\x1b[0m!' \
                     -e '/^Disassembly of section/,/^[A-Z]/ s!^( *)([0-9a-f]{1,}):(  *)([0-9a-f]{8} [0-9a-f ]{8} [0-9a-f ]{8} [0-9a-f ]{8})!\1\x1b[35m\2\x1b[0m:\3\x1b[37m\4\x1b[0m!' \
                     -e '/^Disassembly of section/,/^[A-Z]/ s!([ ,\[{])([xw][1-3][0-9]|[xw][0-9]|[wx]?lr|pc|w?sp|[wx]zr)!\1\x1b[31m\2\x1b[0m!g' \
                     -e '/^Disassembly of section/,/^[A-Z]/ s!<([_a-zA-Z][_a-zA-Z0-9.]*)([+>])!<\x1b[36m\1\x1b[0m\2!g' \
                     -e '/^Disassembly of section/,/^[A-Z]/ s!<unknown>!\x1b[31m<unknown>\x1b[0m!g' \
                     -e '/^Disassembly of section/,/^[A-Z]/ s! (;|//) (.*)! \x1b[32m\1 \2\x1b[0m!g' \
                     -e 's!(0x[A-Fa-f0-9]{2,16})([^\)a-f0-9]|$)!\x1b[35m\1\x1b[0m\2!g' \
                     -e 's!#(0x[A-Fa-f0-9]{1,16})!#\x1b[35m\1\x1b[0m!g' \
                     -e 's!^([A-Z][A-Za-z \.]*:)$!\x1b[32m\1\x1b[0m!'
        exit 0
    fi
}


##
# Reformat the file, if we can, using otool
function format_macho() {
    local format_to_suffix=''
    local format_to=''
    local f
    local args=()
    local tool=

    if type -p otool > /dev/null ; then
        tool=otool
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.macho)
                format_to_suffix="otool"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$tool" == '' ]] ; then
        # We don't know what tool to use, so we give up.
        return
    fi

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        "${tool}" -htV "${args[@]}" "$file" \
            | sed -E -e 's!\r!!' \
                     -e '/^\(__TEXT.* section/,/^$/ s!^([0-9a-f]{8,})(\t)([a-z][a-z0-9]*)!\x1b[36m\1        \x1b[33m\3\x1b[0m!g' \
                     -e '/^\(__TEXT.* section/,/^$/ s!(%[rec][a-z0-9]*)!\x1b[31m\1\x1b[0m!g' \
                     -e '/^\(__TEXT.* section/,/^$/ s!(\$(0x[0-9a-f]*|[0-9][0-9]*))!\x1b[35m\1\x1b[0m!g' \
                     -e '/^\(__TEXT.* section/,/^$/ s!(## .*)!\x1b[32m\1\x1b[0m!g' \
                     -e 's!^([_A-Z][_A-Za-z \.]*:)$!\x1b[32m\1\x1b[0m!' \
            > "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using ar or riscos64-libfile
function format_ar() {
    local format_to_suffix=''
    local format_to=''
    local f
    local args=()
    local tool=

    if type -p riscos64-libfile > /dev/null ; then
        tool="riscos64-libfile"
    elif type -p ar > /dev/null ; then
        tool="ar"
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.a)
                format_to_suffix="a-text"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$tool" == '' ]] ; then
        # We don't know what tool to use, so we give up.
        return
    fi

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        if [[ "$tool" == 'ar' ]] ; then
            if [[ "$sysname" == 'Darwin' ]] ; then
                accept_format
                printf "'ar' archive\n------------\n\nArchived files:\n" > "${tmpdir}/${format_to}"
                ar -tLv "$file" >> "${tmpdir}/${format_to}"
                printf "\n\Symbols:\n" >> "${tmpdir}/${format_to}"
                nm -gU  "$file" >> "${tmpdir}/${format_to}"
            elif [[ "$sysname" == 'Linux' ]] ; then
                accept_format
                printf "'ar' archive\n------------\n\nArchived files:\n" > "${tmpdir}/${format_to}"
                ar tOv "$file" > "${tmpdir}/${format_to}"
                printf "\n\Symbols:\n" >> "${tmpdir}/${format_to}"
                nm -g  "$file" | grep -v '  U ' >> "${tmpdir}/${format_to}"
            else
                return
            fi
        elif [[ "$tool" == 'riscos64-libfile' ]] ; then
            accept_format
            printf "'ar' archive\n------------\n\nArchived files:\n" > "${tmpdir}/${format_to}"
            riscos64-libfile -l "$file" >> "${tmpdir}/${format_to}"
            printf "\n\nSymbols:\n" >> "${tmpdir}/${format_to}"
            riscos64-libfile -s "$file" >> "${tmpdir}/${format_to}"
        else
            return
        fi
        sed_inplace -E -e 's!^([A-Z][A-Za-z ]*:)!\x1b[35m\1\x1b[0m!g' \
                       -e 's!(^| )([^\. ]*\.o)/?(:| |$)!\1\x1b[33m\2\x1b[0m\3!g' "${tmpdir}/${format_to}"
        file="${tmpdir}/${format_to}"
    fi
}


##
# Reformat the file, if we can, using riscos-libfile
function format_libfile() {
    local format_to_suffix=''
    local format_to=''
    local f
    local args=()
    local tool=

    if type -p riscos-libfile > /dev/null ; then
        tool="riscos-libfile"
    fi

    for f in "$file" "$infered_extension" ; do
        case "$f" in

            *.alf)
                format_to_suffix="alf"
                ;;
        esac

        if [[ "$format_to_suffix" != '' ]] ; then
            break
        fi
    done

    if [[ "$tool" == '' ]] ; then
        # We don't know what tool to use, so we give up.
        return
    fi

    if [[ "$format_to_suffix" != '' ]] ;then
        format_to="$(basename "$file"):formatted:.${format_to_suffix}"
        accept_format
        printf "RISC OS library archive\n----------------\n\nArchived files:\n" > "${tmpdir}/${format_to}"
        riscos-libfile -l "$file" >> "${tmpdir}/${format_to}"
        printf "\n\nSymbols:\n" >> "${tmpdir}/${format_to}"
        riscos-libfile -s "$file" >> "${tmpdir}/${format_to}"
        sed_inplace -E -e 's!^([A-Z][A-Za-z ]*:)!\x1b[35m\1\x1b[0m!g'
        file="${tmpdir}/${format_to}"
    fi
}



##
# Identify the filetype using the 'file' tool.
#
# Sets infered_extension to the extension that has been determined
# from the content.
function identify_file() {
    # Only allow the first 20K to decode files; otherwise huge files will take an age
    # to be processed.
    file_type=$(head -c 20000 "$file" | file - 2>/dev/null)
    infered_extension=''
    if [[ "$file_type" =~ shell\ script ]] ; then
        infered_extension='.sh'
    elif [[ "$file_type" =~ [Pp]erl\ script ]] ; then
        infered_extension='.pl'
    elif [[ "$file_type" =~ Python\ script ]] ; then
        infered_extension='.py'
    elif [[ "$file_type" =~ XML\ document ]] ; then
        infered_extension='.xml'
    elif [[ "$file_type" =~ ELF.*ARM\ aarch64 ]] ; then
        infered_extension='.elf-arm64'
    elif [[ "$file_type" =~ RISC\ OS.*AOF ]] ; then
        infered_extension='.aof'
    elif [[ "$file_type" =~ RISC\ OS\ AIF ]] ; then
        infered_extension='.arm'
    elif [[ "$file_type" =~ RISC\ OS.*ALF ]] ; then
        infered_extension='.alf'
    elif [[ "$file_type" =~ Mach-O ]] ; then
        infered_extension='.macho'
    elif [[ "$file_type" =~ Apple\ binary\ property\ list ]] ; then
        infered_extension='.plist'
    elif [[ "$file_type" =~ OpenSSH\ private\ key ]] ; then
        infered_extension='.pem'
    elif [[ "$file_type" =~ PEM\ certificate\ request ]] ; then
        infered_extension='.csr'
    elif [[ "$file_type" =~ PEM\ certificate ]] ; then
        infered_extension='.crt'
    elif [[ "$file_type" =~ ar\ archive ]] ; then
        infered_extension='.a'
    elif [[ "$file_type" =~ python.*byte-compiled ]] ; then
        infered_extension='.pyc'
    elif [[ "$file_type" =~ ASCII\ text ]] ; then
        # YAML files are not recognised as such by the `file` tool, so we'll look at the first
        # line and see what we think.
        local firstline=$(head -1 "$file")
        if [[ "$firstline" =~ ^%YAML || \
              "$firstline" == '---' ]] ; then
            infered_extension='.yaml'
        fi
    fi
}


##
# Identify the file using the extension
#
# Sets the infered extension (or full filename) to any base type that is used.
function identify_extension() {

    case "$file" in

        # Currently we don't need to generate inferred extensions for other extensions - pygmentize spots most
        *.txt)
            ;;

        # Any .key file is almost certainly a SSH/OpenSSL key file
        *.key)
            infered_extension='.pem'
            ;;

        */VersionNum|VersionNum)
            infered_extension='.h'
            ;;

        *,18c|*,18d)
            infered_extension='.lua'
            ;;

    esac
}


# Identifiers
identify_file
identify_extension

# First try the reformatters
format_junitxml
format_xmllint
format_bastotxt
format_armdumpi
format_armdiss
format_decaof
format_libfile
format_ar
format_dump
format_objdump
format_macho
format_markdown
format_plist
format_openssl
format_pyc

# Now the colourers
colour_csvkit
colour_grc
colour_jq
colour_pygments


if $reformatted ; then
    # Already reformatted, so can be listed as is
    cat "$file"
    exit 0
fi


# Could not find a colourer / filter, so give up.
exit 1
