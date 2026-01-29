# fj - Fuzzy directory jump for Bash
# Source this file in your ~/.bashrc

# Data directory setup
_fj_data_dir="${FJ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fj}"
[[ -d "$_fj_data_dir" ]] || mkdir -p "$_fj_data_dir"
export FJ_DATA_FILE="$_fj_data_dir/history"

# Track previous directory to detect changes
_fj_prev_pwd=""

# Record directory visit
_fj_add() {
    # Skip if path is empty or home directory
    [[ -z "$1" || "$1" == "$HOME" ]] && return

    # Append timestamp:path to history file
    echo "$(date +%s):$1" >> "$FJ_DATA_FILE" 2>/dev/null
}

# Hook to record directory changes (called via PROMPT_COMMAND)
_fj_prompt_hook() {
    if [[ "$PWD" != "$_fj_prev_pwd" ]]; then
        _fj_add "$PWD"
        _fj_prev_pwd="$PWD"
    fi
}

# Append to PROMPT_COMMAND
if [[ -z "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="_fj_prompt_hook"
elif [[ "$PROMPT_COMMAND" != *"_fj_prompt_hook"* ]]; then
    PROMPT_COMMAND="_fj_prompt_hook;$PROMPT_COMMAND"
fi

# Wrapper function that changes directory based on fj output
fj() {
    local dir
    dir=$(command fj "$@") || return 1

    # Validate path doesn't contain newlines (security)
    if [[ "$dir" == *$'\n'* ]]; then
        echo "fj: Invalid path" >&2
        return 1
    fi

    # Change directory if path is non-empty
    [ -n "$dir" ] && cd -- "$dir"
}

# Optional: Override cd with fj fallback
# Set FJ_CD_OVERRIDE=1 in your shell config to enable
if [[ -n "$FJ_CD_OVERRIDE" ]]; then
    cd() {
        # No arguments → go to $HOME (normal behavior)
        if [[ $# -eq 0 ]]; then
            builtin cd
            return
        fi

        # cd - → previous directory (normal behavior)
        if [[ "$1" == "-" ]]; then
            builtin cd -
            return
        fi

        # Try normal cd first (handles ~, ~user, CDPATH, existing paths)
        if builtin cd "$@" 2>/dev/null; then
            return
        fi

        # builtin cd failed → try fj fuzzy search
        local dir
        dir=$(command fj "$@") || {
            # fj also failed → show original cd error
            builtin cd "$@"
            return
        }

        # Security: validate path doesn't contain newlines
        if [[ "$dir" == *$'\n'* ]]; then
            echo "fj: Invalid path" >&2
            return 1
        fi

        [ -n "$dir" ] && builtin cd -- "$dir"
    }
fi

# Optional: Add keybinding for Ctrl-G to invoke fj
# bind '"\C-g": "fj\n"'

# Tab completion for fj
_fj_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    # init subcommand completion
    if [[ "$prev" == "init" ]]; then
        COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
        return
    fi

    # Get completion candidates (basename fuzzy matching)
    # No prefix filtering needed - fj -q handles the matching
    local IFS=$'\n'
    COMPREPLY=($(command fj -q "$cur" 2>/dev/null))
}
complete -o nosort -o nospace -F _fj_completions fj
