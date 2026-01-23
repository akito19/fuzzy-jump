# zj - Fuzzy directory jump for Zsh
# Source this file in your ~/.zshrc

emulate -L zsh
setopt no_xtrace no_verbose

# Data directory setup
_zj_data_dir="${ZJ_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/zj}"
[[ -d "$_zj_data_dir" ]] || mkdir -p "$_zj_data_dir"
export ZJ_DATA_FILE="$_zj_data_dir/history"

# Record directory visit
_zj_add() {
    # Skip if path is empty or home directory
    [[ -z "$1" || "$1" == "$HOME" ]] && return

    # Append timestamp:path to history file
    print -r -- "$(date +%s):$1" >> "$ZJ_DATA_FILE" 2>/dev/null
}

# Hook to record directory changes
_zj_chpwd() {
    _zj_add "$PWD"
}
chpwd_functions+=(_zj_chpwd)

# Wrapper function that changes directory based on zj output
zj() {
    local dir
    dir=$(command zj "$@") || return 1

    # Validate path doesn't contain newlines (security)
    [[ "$dir" == *$'\n'* ]] && { echo "zj: Invalid path" >&2; return 1; }

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
        [[ "$dir" == *$'\n'* ]] && { echo "zj: Invalid path" >&2; return 1; }

        [ -n "$dir" ] && builtin cd -- "$dir"
    }
fi

# Optional: Add keybinding for Ctrl-G to invoke zj
# bindkey -s '^g' 'zj^M'

# Tab completion for zj init subcommand
_zj() {
    if [[ "${words[2]}" == "init" ]]; then
        compadd bash zsh fish
        return
    fi
    # For other cases, use the widget below
}
compdef _zj zj

# Interactive completion widget (TUI-based)
_zj_complete_widget() {
    # Get the current word being typed
    local current_word="${LBUFFER##* }"

    # Only activate if we're completing after 'zj '
    if [[ "$LBUFFER" != zj* ]]; then
        zle expand-or-complete
        return
    fi

    # Run TUI and capture result
    local dir
    dir=$(command zj -q "$current_word" </dev/tty 2>/dev/tty)

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
zle -N _zj_complete_widget

# Bind Tab for zj command (using a wrapper)
_zj_tab_handler() {
    if [[ "$LBUFFER" == zj\ * || "$LBUFFER" == "zj" ]]; then
        zle _zj_complete_widget
    else
        zle expand-or-complete
    fi
}
zle -N _zj_tab_handler
bindkey '^I' _zj_tab_handler
