# zj - Fuzzy directory jump for Bash
# Source this file in your ~/.bashrc

# Data directory setup
_zj_data_dir="${ZJ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zj}"
[[ -d "$_zj_data_dir" ]] || mkdir -p "$_zj_data_dir"
export ZJ_DATA_FILE="$_zj_data_dir/history"

# Track previous directory to detect changes
_zj_prev_pwd=""

# Record directory visit
_zj_add() {
    # Skip if path is empty or home directory
    [[ -z "$1" || "$1" == "$HOME" ]] && return

    # Append timestamp:path to history file
    echo "$(date +%s):$1" >> "$ZJ_DATA_FILE" 2>/dev/null
}

# Hook to record directory changes (called via PROMPT_COMMAND)
_zj_prompt_hook() {
    if [[ "$PWD" != "$_zj_prev_pwd" ]]; then
        _zj_add "$PWD"
        _zj_prev_pwd="$PWD"
    fi
}

# Append to PROMPT_COMMAND
if [[ -z "$PROMPT_COMMAND" ]]; then
    PROMPT_COMMAND="_zj_prompt_hook"
elif [[ "$PROMPT_COMMAND" != *"_zj_prompt_hook"* ]]; then
    PROMPT_COMMAND="_zj_prompt_hook;$PROMPT_COMMAND"
fi

# Wrapper function that changes directory based on zj output
zj() {
    local dir
    dir=$(command zj "$@") || return 1

    # Validate path doesn't contain newlines (security)
    if [[ "$dir" == *$'\n'* ]]; then
        echo "zj: Invalid path" >&2
        return 1
    fi

    # Change directory if path is non-empty
    [ -n "$dir" ] && cd -- "$dir"
}

# Optional: Override cd with zj fallback
# Set ZJ_CD_OVERRIDE=1 in your shell config to enable
if [[ -n "$ZJ_CD_OVERRIDE" ]]; then
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

        # builtin cd failed → try zj fuzzy search
        local dir
        dir=$(command zj "$@") || {
            # zj also failed → show original cd error
            builtin cd "$@"
            return
        }

        # Security: validate path doesn't contain newlines
        if [[ "$dir" == *$'\n'* ]]; then
            echo "zj: Invalid path" >&2
            return 1
        fi

        [ -n "$dir" ] && builtin cd -- "$dir"
    }
fi

# Optional: Add keybinding for Ctrl-G to invoke zj
# bind '"\C-g": "zj\n"'

# Tab completion for zj
_zj_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"

    # init subcommand completion
    if [[ "$prev" == "init" ]]; then
        COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
        return
    fi

    # Get completion candidates (basename fuzzy matching)
    # No prefix filtering needed - zj -q handles the matching
    local IFS=$'\n'
    COMPREPLY=($(command zj -q "$cur" 2>/dev/null))
}
complete -o nosort -o nospace -F _zj_completions zj
