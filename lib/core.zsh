# quickmenu :: core
# Config loading, the `quickmenu` command and the ZLE widget.

typeset -g QUICKMENU_CONFIG_DIR=${QUICKMENU_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/quickmenu}
typeset -g QUICKMENU_LOCAL=${QUICKMENU_LOCAL:-1}
typeset -g QUICKMENU_TITLE=${QUICKMENU_TITLE:-quickmenu}
typeset -g _QM_LOADED_SIG=''

# Create the user config from the bundled template on first run.
_qm_bootstrap_config() {
  emulate -L zsh
  setopt local_options null_glob

  [[ -n ${QUICKMENU_CONFIG:-} ]] && return 0
  local -a existing=( "$QUICKMENU_CONFIG_DIR"/menu.(conf|json|zsh)(N) )
  (( $#existing )) && return 0

  local template=$QUICKMENU_ROOT/menu.default.conf
  [[ -f $template ]] || return 1
  local target=$QUICKMENU_CONFIG_DIR/menu.conf
  command mkdir -p "$QUICKMENU_CONFIG_DIR" 2>/dev/null || return 1
  command cp "$template" "$target" 2>/dev/null || return 1
  print -ru2 -- "quickmenu: created ${target} - edit it with 'qm --edit'"
  return 0
}

# Is this file safe to read? Must be a regular file, owned by us and not
# writable by anyone else.
_qm_check_file() {
  emulate -L zsh
  local f=$1
  [[ -f $f && -r $f ]] || return 1
  [[ -n ${QUICKMENU_UNSAFE_CONFIG:-} ]] && return 0

  if [[ ! -O $f ]]; then
    print -ru2 -- "quickmenu: skipping ${f} (not owned by you)"
    return 1
  fi
  local -A st
  if zmodload -F zsh/stat b:zstat 2>/dev/null && zstat -H st -- "$f" 2>/dev/null; then
    if (( (st[mode] & 8#22) != 0 )); then
      print -ru2 -- "quickmenu: skipping ${f} (group/world writable)"
      return 1
    fi
  fi
  return 0
}

_qm_source_file() {
  source "$1"
  return 0
}

# Project-local menu files: the nearest ancestor directory that has any.
_qm_local_files() {
  emulate -L zsh
  setopt local_options null_glob
  (( QUICKMENU_LOCAL )) || return 1

  local -a names
  if [[ -n ${QUICKMENU_LOCAL_FILE:-} ]]; then
    names=( "$QUICKMENU_LOCAL_FILE" )
  else
    names=( .quickmenu.conf .quickmenu.json .quickmenu.zsh )
  fi

  local dir=$PWD n
  local -a found
  while :; do
    found=()
    for n in "${names[@]}"; do
      [[ -f $dir/$n ]] && found+=( "$dir/$n" )
    done
    if (( $#found )); then
      print -rl -- "${found[@]}"
      return 0
    fi
    [[ $dir == / || -z $dir ]] && break
    dir=${dir:h}
  done
  return 1
}

# Every config file that will be loaded, in order.
_qm_config_files() {
  emulate -L zsh
  setopt local_options null_glob
  local -a files

  if [[ -n ${QUICKMENU_CONFIG:-} ]]; then
    files=( ${~QUICKMENU_CONFIG} )
  else
    files=( "$QUICKMENU_CONFIG_DIR"/menu.conf(N)
            "$QUICKMENU_CONFIG_DIR"/menu.json(N)
            "$QUICKMENU_CONFIG_DIR"/menu.zsh(N) )
  fi

  files+=( "$QUICKMENU_CONFIG_DIR"/menu.d/*.(conf|json|zsh)(N) )
  files+=( ${(f)"$(_qm_local_files)"} )

  print -rl -- ${files:#}
}

# The file `--edit` and `--add` work on.
_qm_primary_config() {
  emulate -L zsh
  setopt local_options null_glob
  if [[ -n ${QUICKMENU_CONFIG:-} ]]; then
    print -r -- "$QUICKMENU_CONFIG"
    return 0
  fi
  local -a existing=( "$QUICKMENU_CONFIG_DIR"/menu.(conf|json|zsh)(N) )
  if (( $#existing )); then
    print -r -- "${existing[1]}"
  else
    print -r -- "$QUICKMENU_CONFIG_DIR/menu.conf"
  fi
}

# Signature of all config inputs, so we only re-read when something changed.
_qm_config_sig() {
  emulate -L zsh
  local sig='' f
  for f in ${(f)"$(_qm_config_files)"}; do
    sig+="${f}:${$(command stat -f '%m' -- "$f" 2>/dev/null || command stat -c '%Y' -- "$f" 2>/dev/null)}|"
  done
  print -r -- "$sig"
}

_qm_load_config() {
  emulate -L zsh
  setopt local_options null_glob
  local -i force=${1:-0}

  _qm_bootstrap_config

  local sig
  sig=$(_qm_config_sig)
  if (( ! force )) && [[ -n $_QM_LOADED_SIG && $sig == $_QM_LOADED_SIG ]]; then
    return 0
  fi

  qm_reset
  local f
  for f in ${(f)"$(_qm_config_files)"}; do
    _qm_load_file "$f"
  done

  _QM_LOADED_SIG=$sig
  return 0
}

_qm_usage() {
  print -r -- "quickmenu - a launcher menu for the commands you keep forgetting

usage: qm [options] [query]

  (no args)        open the menu
  <query>          pre-filter; runs straight away on a single match
  -l, --list       list every item without opening the menu
  -p, --print      resolve the chosen command and print it instead of running
  -n, --index N    choose item N non-interactively
  -a, --add        add an item to your config (prompts, or takes label+command)
  -e, --edit       open the menu config in \$EDITOR
  -r, --reload     force a config reload
  -c, --config     show which config files are in use
  -h, --help       this text

config files, all loaded if present:
  ${QUICKMENU_CONFIG_DIR}/menu.conf      simple text format
  ${QUICKMENU_CONFIG_DIR}/menu.json      JSON
  ${QUICKMENU_CONFIG_DIR}/menu.zsh       zsh script (qm_item ...)
  ${QUICKMENU_CONFIG_DIR}/menu.d/*       extra snippets in any of those formats
  ./.quickmenu.conf|json|zsh             project-local, searched upwards

keys:   up/down or ctrl-n/ctrl-p move, 1-9 and 0 jump, type to filter,
        enter runs, tab puts the command on the prompt, esc cancels"
}

_qm_show_config() {
  emulate -L zsh
  local -a files=( ${(f)"$(_qm_config_files)"} )
  if (( ! $#files )); then
    print -r -- "no config files yet; 'qm --add' or 'qm --edit' will create one"
    print -r -- "primary: $(_qm_primary_config)"
    return 0
  fi
  print -r -- "loaded, in order:"
  local f
  for f in "${files[@]}"; do
    print -r -- "  ${f}"
  done
  print -r -- "primary (used by --edit and --add): $(_qm_primary_config)"
}

_qm_cmd_add() {
  emulate -L zsh
  local label=$1 cmd=$2 group=$3
  local -i interactive=0
  [[ -z $label && -z $cmd ]] && interactive=1

  _qm_bootstrap_config

  local target
  target=$(_qm_primary_config)

  if [[ ${(L)target:e} != (conf|ini|menu|) ]]; then
    print -ru2 -- "quickmenu: --add only writes .conf files; yours is ${target}"
    return 1
  fi

  if (( interactive )); then
    _qm_read_line "Label" '' || return 1
    label=$REPLY
    _qm_read_line "Command" '' || return 1
    cmd=$REPLY
    _qm_read_line "Group (optional)" '' || return 1
    group=$REPLY
  fi

  if [[ -z $label || -z $cmd ]]; then
    print -ru2 -- "quickmenu: usage: qm --add <label> <command> [group]"
    return 1
  fi

  _qm_conf_append "$target" "$label" "$cmd" "$group" || return 1
  print -ru2 -- "quickmenu: added '${label}' to ${target}"
  _qm_load_config 1
  return 0
}

# Filter the visible item list by a query string, in place.
# Items whose label contains the query are ranked above loose fuzzy matches.
_qm_apply_query() {
  emulate -L zsh
  local q=${(L)1}
  [[ -n $q ]] || return 0
  local -a strong weak
  local -i i
  for (( i = 1; i <= $#_qm_vis_label; i++ )); do
    if [[ ${(L)_qm_vis_label[i]} == *$q* ]]; then
      strong+=( $i )
    elif [[ ${(L)_qm_vis_hay[i]} == *$q* ]] || _qm_subseq "$q" "${_qm_vis_hay[i]}"; then
      weak+=( $i )
    fi
  done

  local -a order=( $strong $weak )
  local -a il=() ic=() if_=() ih=() ii=()
  local -i j
  for j in $order; do
    ii+=( ${_qm_vis_idx[j]} ); il+=( "${_qm_vis_label[j]}" ); ic+=( "${_qm_vis_cmd[j]}" )
    if_+=( "${_qm_vis_flags[j]}" ); ih+=( "${_qm_vis_hay[j]}" )
  done
  _qm_vis_idx=( "${ii[@]}" ); _qm_vis_label=( "${il[@]}" ); _qm_vis_cmd=( "${ic[@]}" )
  _qm_vis_flags=( "${if_[@]}" ); _qm_vis_hay=( "${ih[@]}" )
  (( $#_qm_vis_idx ))
}

# Pick + resolve. Sets _qm_result (command) and _qm_result_action (run|edit).
# Returns 1 when the user cancelled or resolution failed.
_qm_choose() {
  emulate -L zsh
  local query=$1 want_index=$2
  typeset -g _qm_result='' _qm_result_action=run _qm_result_flags=''

  _qm_load_config

  if ! _qm_visible; then
    print -ru2 -- "quickmenu: no menu items. Run 'qm --edit' to add some."
    return 1
  fi

  if [[ -n $query ]]; then
    if ! _qm_apply_query "$query"; then
      print -ru2 -- "quickmenu: nothing matches '${query}'"
      return 1
    fi
  fi

  local -i choice
  if [[ -n $want_index ]]; then
    [[ $want_index == <-> ]] && (( want_index >= 1 && want_index <= $#_qm_vis_label )) || {
      print -ru2 -- "quickmenu: index out of range: ${want_index}"
      return 1
    }
    choice=$want_index
    _qm_pick_action=run
  elif (( $#_qm_vis_label == 1 )) && [[ -n $query ]]; then
    choice=1
    _qm_pick_action=run
  else
    _qm_pick "$QUICKMENU_TITLE" _qm_vis_label _qm_vis_cmd || return 1
    choice=$REPLY
  fi

  local flags=${_qm_vis_flags[choice]}
  local raw=${_qm_vis_cmd[choice]}

  if [[ $flags == *y* ]]; then
    _qm_confirm "Run: ${_qm_vis_label[choice]}?" || return 1
  fi

  _qm_resolve "$raw" || return 1

  _qm_result=$REPLY
  _qm_result_flags=$flags
  if [[ $_qm_pick_action == edit || $flags == *e* ]]; then
    _qm_result_action=edit
  else
    _qm_result_action=run
  fi
  return 0
}

quickmenu() {
  emulate -L zsh
  setopt local_options

  local mode=menu query='' want_index=''
  local -a add_args
  while (( $# )); do
    case $1 in
      -l|--list)   mode=list ;;
      -p|--print)  mode=print ;;
      -e|--edit)   mode=edit ;;
      -r|--reload) mode=reload ;;
      -h|--help)   mode=help ;;
      -c|--config) mode=config ;;
      -a|--add)    mode=add; shift; add_args=( "$@" ); break ;;
      -n|--index)  shift; want_index=$1 ;;
      --)          shift; query="${query:+$query }$*"; break ;;
      -*)          print -ru2 -- "quickmenu: unknown option $1"; return 2 ;;
      *)           query="${query:+$query }$1" ;;
    esac
    shift
  done

  case $mode in
    help) _qm_usage; return 0 ;;
    config) _qm_show_config; return 0 ;;
    add) _qm_cmd_add "${add_args[1]}" "${add_args[2]}" "${add_args[3]}"; return $? ;;
    edit)
      _qm_bootstrap_config
      local target
      target=$(_qm_primary_config)
      command mkdir -p "${target:h}" 2>/dev/null
      ${EDITOR:-${VISUAL:-vi}} "$target"
      _qm_load_config 1
      return 0
      ;;
    reload)
      _qm_load_config 1
      _qm_visible
      print -ru2 -- "quickmenu: reloaded ${#_qm_vis_label} item(s)"
      return 0
      ;;
    list)
      _qm_load_config
      _qm_visible || { print -ru2 -- "quickmenu: no menu items"; return 1 }
      [[ -n $query ]] && { _qm_apply_query "$query" || { print -ru2 -- "quickmenu: nothing matches '${query}'"; return 1 } }
      local -i i
      for (( i = 1; i <= $#_qm_vis_label; i++ )); do
        printf '%3d  %-34s %s\n' $i "${_qm_vis_label[i]}" "${_qm_vis_cmd[i]//$'\n'/ ; }"
      done
      return 0
      ;;
  esac

  _qm_choose "$query" "$want_index" || return 1

  if [[ $mode == print ]]; then
    print -r -- "$_qm_result"
    return 0
  fi

  if [[ $_qm_result_action == edit ]]; then
    print -z -- "$_qm_result"
    return 0
  fi

  print -s -- "$_qm_result"
  if [[ -z ${QUICKMENU_QUIET:-} ]]; then
    if [[ -n ${QUICKMENU_NO_COLOR:-} ]]; then
      print -ru2 -- "\$ ${_qm_result}"
    else
      print -ru2 -- $'\e[2m$ '"${_qm_result}"$'\e[0m'
    fi
  fi
  eval "$_qm_result"
}

quickmenu-widget() {
  emulate -L zsh
  zle -I
  if _qm_choose '' ''; then
    BUFFER=$_qm_result
    CURSOR=${#BUFFER}
    if [[ $_qm_result_action == edit ]]; then
      zle redisplay
    else
      zle accept-line
    fi
  else
    zle reset-prompt
  fi
}
