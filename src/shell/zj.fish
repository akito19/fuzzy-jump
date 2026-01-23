# zj - Fuzzy directory jump for Fish
# Add to ~/.config/fish/config.fish: zj init fish | source

# Data directory setup
set -l _zj_data_dir (test -n "$ZJ_DATA_DIR"; and echo "$ZJ_DATA_DIR"; or echo (test -n "$XDG_DATA_HOME"; and echo "$XDG_DATA_HOME"; or echo "$HOME/.local/share")"/zj")
test -d "$_zj_data_dir"; or mkdir -p "$_zj_data_dir"
set -gx ZJ_DATA_FILE "$_zj_data_dir/history"

# Record directory visit
function _zj_add
    # Skip if path is empty or home directory
    test -z "$argv[1]"; and return
    test "$argv[1]" = "$HOME"; and return

    # Append timestamp:path to history file
    echo (date +%s)":$argv[1]" >> "$ZJ_DATA_FILE" 2>/dev/null
end

# Hook to record directory changes
function _zj_pwd_hook --on-variable PWD
    _zj_add "$PWD"
end

# Wrapper function that changes directory based on zj output
function zj
    set -l dir (command zj $argv)
    or return 1

    # Validate path doesn't contain newlines (security)
    if string match -q '*\n*' -- $dir
        echo "zj: Invalid path" >&2
        return 1
    end

    # Change directory if path is non-empty
    test -n "$dir"; and cd -- $dir
end

# Optional: Override cd with zj fallback
# Set ZJ_CD_OVERRIDE=1 in your shell config to enable
if set -q ZJ_CD_OVERRIDE
    function cd
        # No arguments -> go to $HOME (normal behavior)
        if test (count $argv) -eq 0
            builtin cd
            return
        end

        # cd - -> previous directory (normal behavior)
        if test "$argv[1]" = "-"
            builtin cd -
            return
        end

        # Try normal cd first (handles ~, existing paths)
        if builtin cd $argv 2>/dev/null
            return
        end

        # builtin cd failed -> try zj fuzzy search
        set -l dir (command zj $argv)
        or begin
            # zj also failed -> show original cd error
            builtin cd $argv
            return
        end

        # Security: validate path doesn't contain newlines
        if string match -q '*\n*' -- $dir
            echo "zj: Invalid path" >&2
            return 1
        end

        test -n "$dir"; and builtin cd -- $dir
    end
end

# Tab completion for zj
complete -c zj -n "__fish_use_subcommand" -a "init" -d "Print shell integration"
complete -c zj -n "__fish_seen_subcommand_from init" -a "bash zsh fish"
complete -c zj -n "not __fish_seen_subcommand_from init" -f -a "(command zj -q (commandline -ct) 2>/dev/null)"
