# Bash completion for pdfpc.
#
# The completion is static (defined for every option).
# Written by Emanuele Petriglia (ema-pe) <inbox@emanuelepetriglia.com>.

_pdfpc_complete() {
    local cur prev opts nofile_opts

    # Read by Bash at the end, contains the completions.
    COMPREPLY=()

    # Current and previous word in the prompt.
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # All available options supported by pdfpc (v4.7.0).
    opts="
        -h --help
        -B --list-bindings
        -c --cfg-statement
        -C --time-of-day
        -d --duration
        -e --end-time
        -f --note-format
        -g --disable-auto-grouping
        -l --last-minutes
        -L --list-actions
        -M --list-monitors
        -n --notes
        -N --no-install
        -p --rest-port
        -P --page
        -r --page-transition
        -R --pdfpc-location
        -s --switch-screens
        -S --single-screen
        -t --start-time
        -T --enable-auto-srt-load
        -v --version
        -V --enable-rest-server
        -w --windowed
        -W --wayland-workaround
        -X --external-script
        -Z --size
        -1 --presenter-screen
        -2 --presentation-screen
    "

    # Handle completion for (short and long) options that take a value.
    if [[ "${prev}" == "-f" || "${prev}" == "--note-format" ]]; then
        # shellcheck disable=SC2207
        # See: https://www.shellcheck.net/wiki/SC2207
        COMPREPLY=( $(compgen -W "plain markdown" -- "${cur}") )
        return 0
    fi
    if [[ "${prev}" == "-n" || "${prev}" == "--notes" ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "left right top bottom none" -- "${cur}") )
        return 0
    fi
    if [[ "${prev}" == "-w" || "${prev}" == "--windowed" ]]; then
        # shellcheck disable=SC2207
        COMPREPLY=( $(compgen -W "presenter presentation both none" -- "${cur}") )
        return 0
    fi
    if [[ "${prev}" == "-R" || "${prev}" == "--pdfpc-location" || \
          "${prev}" == "-X" || "${prev}" == "--external-script" ]]; then
        mapfile -t COMPREPLY < <(compgen -f -- "${cur}")
        return 0
    fi

    # Complete with options (do not suggest '=' at end for long options).
    if [[ "${cur}" == -* && "${cur}" != *=* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "${opts}" -- "${cur}")
        return 0
    fi

    # Array of options after which PDF completion shouldn't happen.
    nofile_opts=(
        "-c" "--cfg-statement"
        "-d" "--duration"
        "-e" "--end-time"
        "-l" "--last-minutes"
        "-r" "--page-transition"
        "-t" "--start-time"
        "-w" "--windowed"
        "-1" "--presenter-screen"
        "-2" "--presentation-screen"
    )

    # Do not suggest PDF files if previous word is an option that expects a value.
    for opt in "${nofile_opts[@]}"; do
        if [[ "${prev}" == "${opt}" ]]; then
            return 0
        fi
    done

    # Otherwise, suggest PDF files for first non-option argument.
    mapfile -t COMPREPLY < <(compgen -G "*.pdf" -- "${cur}")
}

complete -F _pdfpc_complete pdfpc
