# fj - Fuzzy directory jump for Fish
# Add to ~/.config/fish/config.fish: fj init fish | source

# Data directory setup
set -l _fj_data_dir (test -n "$FJ_DATA_DIR"; and echo "$FJ_DATA_DIR"; or echo (test -n "$XDG_DATA_HOME"; and echo "$XDG_DATA_HOME"; or echo "$HOME/.local/share")"/fj")
test -d "$_fj_data_dir"; or mkdir -p "$_fj_data_dir"
set -gx FJ_DATA_FILE "$_fj_data_dir/history"

# Record directory visit
function _fj_add
    # Skip if path is empty or home directory
    test -z "$argv[1]"; and return
    test "$argv[1]" = "$HOME"; and return

    # Append timestamp:path to history file
    echo (date +%s)":$argv[1]" >> "$FJ_DATA_FILE" 2>/dev/null
end

# Hook to record directory changes
function _fj_pwd_hook --on-variable PWD
    _fj_add "$PWD"
end

# Wrapper function that changes directory based on fj output
function fj
    set -l dir (command fj $argv)
    or return 1

    # Validate path doesn't contain newlines (security)
    if string match -q '*\n*' -- $dir
        echo "fj: Invalid path" >&2
        return 1
    end

    # Change directory if path is non-empty
    test -n "$dir"; and cd -- $dir
end

# Optional: Override cd with fj fallback
# Set FJ_CD_OVERRIDE=1 in your shell config to enable
if set -q FJ_CD_OVERRIDE
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

        # builtin cd failed -> try fj fuzzy search
        set -l dir (command fj $argv)
        or begin
            # fj also failed -> show original cd error
            builtin cd $argv
            return
        end

        # Security: validate path doesn't contain newlines
        if string match -q '*\n*' -- $dir
            echo "fj: Invalid path" >&2
            return 1
        end

        test -n "$dir"; and builtin cd -- $dir
    end
end

# Tab completion for fj
complete -c fj -n "__fish_use_subcommand" -a "init" -d "Print shell integration"
complete -c fj -n "__fish_seen_subcommand_from init" -a "bash zsh fish"
complete -c fj -n "not __fish_seen_subcommand_from init" -f -a "(command fj -q (commandline -ct) 2>/dev/null)"
