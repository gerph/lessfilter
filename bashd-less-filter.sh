# make less more friendly for non-text input files, see lesspipe(1)
if type -p lesspipe > /dev/null ; then
    eval "$(SHELL=/bin/sh lesspipe)"
fi

# Less should handle colouring within the terminal
#  F => exit if less than a screenful.
#  R => Raw control codes for ANSI colouring.
#  X => No init/deinit sequences.
#  M => long prompt.
export LESS=-FRXM
