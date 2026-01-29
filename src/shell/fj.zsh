# fj - Fuzzy directory jump for Zsh
# Source this file in your ~/.zshrc

emulate -L zsh
setopt no_xtrace no_verbose

# Data directory setup
_fj_data_dir="${FJ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fj}"
[[ -d "$_fj_data_dir" ]] || mkdir -p "$_fj_data_dir"
export FJ_DATA_FILE="$_fj_data_dir/history"

# Record directory visit
_fj_add() {
    # Skip if path is empty or home directory
    [[ -z "$1" || "$1" == "$HOME" ]] && return

    # Append timestamp:path to history file
    print -r -- "$(date +%s):$1" >> "$FJ_DATA_FILE" 2>/dev/null
}

# Hook to record directory changes
_fj_chpwd() {
    _fj_add "$PWD"
}
chpwd_functions+=(_fj_chpwd)

# Wrapper function that changes directory based on fj output
fj() {
    local dir
    dir=$(command fj "$@") || return 1

    # Validate path doesn't contain newlines (security)
    [[ "$dir" == *$'\n'* ]] && { echo "fj: Invalid path" >&2; return 1; }

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
        [[ "$dir" == *$'\n'* ]] && { echo "fj: Invalid path" >&2; return 1; }

        [ -n "$dir" ] && builtin cd -- "$dir"
    }
fi

# Optional: Add keybinding for Ctrl-G to invoke fj
# bindkey -s '^g' 'fj^M'

# Tab completion for fj init subcommand
_fj() {
    if [[ "${words[2]}" == "init" ]]; then
        compadd bash zsh fish
        return
    fi
    # For other cases, use the widget below
}
compdef _fj fj

# Interactive completion widget (TUI-based)
_fj_complete_widget() {
    # Get the current word being typed
    local current_word="${LBUFFER##* }"

    # Only activate if we're completing after 'fj '
    if [[ "$LBUFFER" != fj* ]]; then
        zle expand-or-complete
        return
    fi

    # Run TUI and capture result
    local dir
    dir=$(command fj -q "$current_word" </dev/tty 2>/dev/tty)

    if [[ -n "$dir" ]]; then
        # Replace current word with selected directory
        if [[ "$current_word" == "" ]]; then
            LBUFFER="${LBUFFER}${dir}"
        else
            LBUFFER="${LBUFFER%$current_word}${dir}"
        fi
        zle reset-prompt
    fi
}
zle -N _fj_complete_widget

# Bind Tab for fj command (using a wrapper)
_fj_tab_handler() {
    if [[ "$LBUFFER" == fj\ * || "$LBUFFER" == "fj" ]]; then
        zle _fj_complete_widget
    else
        zle expand-or-complete
    fi
}
zle -N _fj_tab_handler
bindkey '^I' _fj_tab_handler
